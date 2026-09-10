package app

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"aster/internal/state"
)

func TestDiagnosticProfilesRedactOverrideSource(t *testing.T) {
	profiles := diagnosticProfiles([]ProfileJSON{{
		ID: "profile-1", Name: "Private profile", Kind: "nodes", SourceCount: 1,
		HasScript: true, Script: "const credential = 'do-not-export'", LastError: "refresh failed",
	}})
	encoded, err := json.Marshal(profiles)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "do-not-export") || strings.Contains(string(encoded), "credential") {
		t.Fatalf("diagnostic profile leaked script: %s", encoded)
	}
	if !profiles[0].HasScript || profiles[0].Name != "Private profile" {
		t.Fatalf("metadata was not retained: %+v", profiles[0])
	}
}

func TestDiagnosticTextRedactsURLsEverywhere(t *testing.T) {
	text := "download https://user:secret@example.test/path?token=private failed"
	if got := redactDiagnosticText(text); strings.Contains(got, "secret") || strings.Contains(got, "private") || !strings.Contains(got, "[URL]") {
		t.Fatalf("not redacted: %q", got)
	}
	runtime := state.RuntimeState{LastFailure: text, History: []state.RunEvent{{Reason: text}}}
	runtime.LastFailure = redactDiagnosticText(runtime.LastFailure)
	for i := range runtime.History {
		runtime.History[i].Reason = redactDiagnosticText(runtime.History[i].Reason)
	}
	encoded, err := json.Marshal(runtime)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "example.test") {
		t.Fatalf("runtime leaked URL: %s", encoded)
	}
}

func TestDiagnosticProfilesRedactURLsInErrors(t *testing.T) {
	profiles := diagnosticProfiles([]ProfileJSON{{
		LastError: "Get https://user:secret@example.test/sub?token=private: timeout",
		Sources:   []SourceJSON{{Name: "example.test", LastError: "HTTP request https://example.test/sub?token=private failed"}},
	}})
	encoded, err := json.Marshal(profiles)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "example.test/sub") || strings.Contains(string(encoded), "private") || strings.Contains(string(encoded), "secret") {
		t.Fatalf("diagnostic profile leaked URL through error: %s", encoded)
	}
	if !strings.Contains(string(encoded), "[URL]") {
		t.Fatalf("URL was not redacted: %s", encoded)
	}
}

func TestStatusRedactsRuntimeErrorURL(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	a.mu.Lock()
	a.lastErr = "refresh failed: https://user:secret@example.test/path?token=private"
	a.mu.Unlock()
	status := a.Status()
	if strings.Contains(status.Error, "secret") || strings.Contains(status.Error, "private") || !strings.Contains(status.Error, "[URL]") {
		t.Fatalf("status error leaked URL: %q", status.Error)
	}
}

func TestConfigurationIntegrityExportsOnlyDigests(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	raw := []byte(`{"outbounds":[{"type":"direct","tag":"direct","password":"do-not-export"}]}`)
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Profiles = []state.ConfigProfile{{ID: "full", Kind: state.ProfileKindSubscription, Config: raw}}
		f.ActiveConfigID = "full"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(a.Store().ConfigPath(), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	integrity := a.configurationIntegrity(a.Store().Get())
	if integrity.RenderStatus != "passed" || !integrity.AppliedConfigExists || !integrity.MatchesApplied || len(integrity.RenderedSHA256) != 64 {
		t.Fatalf("unexpected integrity result: %+v", integrity)
	}
	encoded, err := json.Marshal(integrity)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "do-not-export") || strings.Contains(string(encoded), "password") {
		t.Fatalf("configuration integrity leaked configuration content: %s", encoded)
	}
}
