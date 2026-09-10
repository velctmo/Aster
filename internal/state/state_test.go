package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCorruptSettingsStopsOpenWithoutDiscardingConfiguration(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ASTER_DATA_DIR", dir)
	if _, err := Open(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte(`{"broken":`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(); err == nil || !strings.Contains(err.Error(), "settings.json") {
		t.Fatalf("Open error=%v, want settings.json corruption", err)
	}
}

func TestMergeDefaultsKeepsExistingMixedPort(t *testing.T) {
	f := mergeDefaults(File{Settings: Settings{MixedPort: 7890, ClashPort: 9090}})
	if f.Settings.MixedPort != 7890 || f.Settings.ClashPort != 9090 {
		t.Fatalf("existing ports rewritten: %+v", f.Settings)
	}
}

func TestMergeDefaultsAPITokenAndPorts(t *testing.T) {
	f := mergeDefaults(File{
		Settings: Settings{ClashPort: 9090},
	})
	if f.Settings.MixedPort != DefaultMixedPort || f.Settings.ClashPort != 9090 {
		t.Fatalf("ports not filled: %+v", f.Settings)
	}
	if f.APIToken == "" {
		t.Fatal("expected api token")
	}
	if f.Settings.StrictRoute {
		t.Fatal("expected strictRoute to stay false on upgrade")
	}
	if f.Settings.DelayTimeoutMs != 2500 || f.Settings.DelayConcurrency != 8 {
		t.Fatalf("delay defaults: %d %d", f.Settings.DelayTimeoutMs, f.Settings.DelayConcurrency)
	}
}

func TestDefaultFileDoesNotHijackSystemProxy(t *testing.T) {
	f := DefaultFile()
	if f.Capture.SystemProxy || f.Capture.Tun {
		t.Fatalf("fresh capture must be off: %+v", f.Capture)
	}
	if f.Settings.MixedPort != DefaultMixedPort || f.Settings.ClashPort != DefaultClashPort {
		t.Fatalf("default ports: mixed=%d clash=%d", f.Settings.MixedPort, f.Settings.ClashPort)
	}
	if f.Settings.AllowLan || f.Settings.Autostart || f.Settings.StrictRoute {
		t.Fatalf("unsafe defaults enabled: %+v", f.Settings)
	}
}

func TestMergeDefaultsKeepsExistingMixedAndClashPorts(t *testing.T) {
	f := mergeDefaults(File{Settings: Settings{MixedPort: 2080, ClashPort: 2090}})
	if f.Settings.MixedPort != 2080 || f.Settings.ClashPort != 2090 {
		t.Fatalf("existing ports rewritten: %+v", f.Settings)
	}
}

func TestTouchProfileAdvancesRevisionWithoutChangingTimestampContract(t *testing.T) {
	p := ConfigProfile{Revision: 7}
	TouchProfile(&p)
	if p.Revision != 8 {
		t.Fatalf("revision=%d, want 8", p.Revision)
	}
	if p.UpdatedAt <= 0 || p.UpdatedAt > time.Now().Add(time.Second).Unix() {
		t.Fatalf("updatedAt=%d is not a seconds timestamp", p.UpdatedAt)
	}
}

func TestDualCapturePersistsAcrossReopen(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ASTER_DATA_DIR", dir)
	first, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := first.Update(func(f *File) error {
		f.Capture = Capture{SystemProxy: true, Tun: true}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	second, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	if got := second.Get().Capture; !got.SystemProxy || !got.Tun {
		t.Fatalf("dual capture was not persisted: %+v", got)
	}
}

func TestStructuredStorageIsPersistedAcrossReopen(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ASTER_DATA_DIR", dir)
	first, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := first.Update(func(f *File) error {
		f.Settings.Theme = "dark"
		f.Profiles[0].Name = "持久化配置"
		f.Scripts = []ScriptItem{{ID: "script-1", Name: "持久化脚本", Kind: ProfileKindNodes, Content: "return true"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{
		"settings.json", "machine.json", "rules.json",
		"profiles/" + first.Get().Profiles[0].ID + ".json", "scripts/script-1.json",
	} {
		if info, err := os.Stat(filepath.Join(dir, path)); err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("persisted file %s info=%v err=%v", path, info, err)
		}
	}
	settingsData, err := os.ReadFile(filepath.Join(dir, "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, machineOnly := range []string{"apiToken", "clashSecret", "corePath", "mixedPort", "capture", "runtime", "wanted"} {
		if strings.Contains(string(settingsData), `"`+machineOnly+`"`) {
			t.Fatalf("settings.json unexpectedly contains machine-only field %q: %s", machineOnly, settingsData)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "state.json")); !os.IsNotExist(err) {
		t.Fatalf("legacy state.json should not be written, err=%v", err)
	}
	second, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	got := second.Get()
	if got.Settings.Theme != "dark" || got.Profiles[0].Name != "持久化配置" || len(got.Scripts) != 1 || got.Scripts[0].ID != "script-1" {
		t.Fatalf("structured state was not persisted: %+v", got)
	}
}

func TestGetReturnsIndependentStructuredSnapshot(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	s, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Update(func(f *File) error {
		f.Profiles[0].ManualNodes = []Node{{ID: "n", Name: "original", Outbound: json.RawMessage(`{"type":"direct"}`)}}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	copy := s.Get()
	copy.Profiles[0].ManualNodes[0].Name = "changed"
	copy.Profiles[0].ManualNodes[0].Outbound[0] = '['
	if got := s.Get().Profiles[0].ManualNodes[0].Name; got != "original" {
		t.Fatalf("store changed through snapshot: %s", got)
	}
}

func TestActiveSnapshotExcludesInactiveProfiles(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	s, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Update(func(f *File) error {
		f.Profiles = append(f.Profiles, ConfigProfile{ID: "inactive", Name: "inactive", Kind: ProfileKindSubscription, Config: json.RawMessage(`{"outbounds":[]}`)})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	active := s.Active()
	if len(active.Profiles) != 1 || active.Profiles[0].ID != active.ActiveConfigID {
		t.Fatalf("unexpected active snapshot: %+v", active.Profiles)
	}
}

func TestActiveSnapshotOmitsCompleteImportedConfigButKeepsCapabilities(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	s, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	raw := json.RawMessage(`{"outbounds":[{"type":"direct"}],"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":7890},{"type":"tun"}]}`)
	_, err = s.Update(func(f *File) error {
		f.Profiles = []ConfigProfile{{ID: "full", Kind: ProfileKindSubscription, Config: raw}}
		f.ActiveConfigID = "full"
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// Simulate a reopen so state migration hydrates pre-existing imports too.
	s, err = Open()
	if err != nil {
		t.Fatal(err)
	}
	active := s.Active().Profiles[0]
	if len(active.Config) != 0 {
		t.Fatalf("high-frequency snapshot retained raw config: %s", active.Config)
	}
	if active.ImportedMixedListen != "127.0.0.1" || active.ImportedMixedPort != 7890 || !active.ImportedTun {
		t.Fatalf("imported capabilities missing from active snapshot: %+v", active)
	}
}

func BenchmarkActiveSnapshotDoesNotCopyLargeImportedConfig(b *testing.B) {
	dir := b.TempDir()
	b.Setenv("ASTER_DATA_DIR", dir)
	s, err := Open()
	if err != nil {
		b.Fatal(err)
	}
	raw := json.RawMessage(`{"outbounds":[{"type":"direct"}],"padding":"` + strings.Repeat("x", 2<<20) + `"}`)
	_, err = s.Update(func(f *File) error {
		f.Profiles = []ConfigProfile{{
			ID: "full", Kind: ProfileKindSubscription, Config: raw,
			ImportedMixedListen: "127.0.0.1", ImportedMixedPort: 7890,
		}}
		f.ActiveConfigID = "full"
		return nil
	})
	if err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		active := s.Active()
		if len(active.Profiles) != 1 || len(active.Profiles[0].Config) != 0 {
			b.Fatal("active snapshot copied full imported configuration")
		}
	}
}

func BenchmarkActiveSnapshotDoesNotCopy500Nodes(b *testing.B) {
	b.Setenv("ASTER_DATA_DIR", b.TempDir())
	s, err := Open()
	if err != nil {
		b.Fatal(err)
	}
	nodes := make([]Node, 0, 500)
	for i := 0; i < 500; i++ {
		nodes = append(nodes, Node{ID: string(rune(i)), Outbound: json.RawMessage(`{"type":"vless","server":"example.test","uuid":"00000000-0000-0000-0000-000000000000"}`)})
	}
	_, err = s.Update(func(f *File) error {
		f.Profiles[0].ManualNodes = nodes
		return nil
	})
	if err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		active := s.Active()
		if len(active.Profiles) != 1 || len(active.Profiles[0].ManualNodes) != 500 {
			b.Fatal("active node snapshot lost nodes")
		}
	}
}

func TestCloneFileDoesNotShareCandidateProfileStorage(t *testing.T) {
	original := DefaultFile()
	original.Profiles[0].Sources = []ConfigSource{{ID: "source", Nodes: []Node{{ID: "node", Name: "old", Outbound: json.RawMessage(`{"type":"direct"}`)}}}}
	candidate := CloneFile(original)
	candidate.Profiles[0].Sources[0].Nodes[0].Name = "new"
	candidate.Profiles[0].UpdatedAt = 42
	if original.Profiles[0].Sources[0].Nodes[0].Name != "old" || original.Profiles[0].UpdatedAt == 42 {
		t.Fatalf("candidate mutation leaked into original: %+v", original.Profiles[0])
	}
}
