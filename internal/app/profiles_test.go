package app

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"aster/internal/helper"
	"aster/internal/state"
)

func TestCreateSubscriptionProfileStoresCompleteConfig(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	raw := `{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`
	if err := a.CreateSubscriptionProfile("完整", "", raw); err != nil {
		t.Fatal(err)
	}
	profiles := a.Profiles()
	if len(profiles) != 2 || profiles[1].Kind != state.ProfileKindSubscription {
		t.Fatalf("profiles=%+v", profiles)
	}
}

func TestCreateSubscriptionProfileRejectsMixedLocalAndURLSources(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := a.CreateSubscriptionProfile("完整", "https://example.test/sub", `{"outbounds":[]}`); err == nil {
		t.Fatal("mixed subscription sources should be rejected before fetching")
	}
	if got := len(a.Store().Get().Profiles); got != 1 {
		t.Fatalf("mixed source request created profile count=%d", got)
	}
}

func TestCreateSubscriptionProfileRejectsNonArrayOutbounds(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := a.CreateSubscriptionProfile("完整", "", `{"outbounds":{"type":"direct"}}`); err == nil {
		t.Fatal("non-array outbounds should be rejected")
	}
	if got := len(a.Store().Get().Profiles); got != 1 {
		t.Fatalf("invalid subscription created profile count=%d", got)
	}
}

func TestNodeTunCapabilityRequiresHelper(t *testing.T) {
	f := state.DefaultFile()
	caps := capabilitiesFor(f)
	installed := helper.NewClient().Installed()
	if caps.Tun.Available != installed {
		t.Fatalf("tun available=%v helper installed=%v reason=%q", caps.Tun.Available, installed, caps.Tun.Reason)
	}
	if !installed && caps.Tun.Reason == "" {
		t.Fatal("missing helper must explain why TUN is unavailable")
	}
}

func TestImportedProfileCapabilitiesKeepTunReadOnly(t *testing.T) {
	f := state.DefaultFile()
	f.Profiles = []state.ConfigProfile{{
		ID: "full", Kind: state.ProfileKindSubscription,
		Config: []byte(`{"outbounds":[{"type":"direct","tag":"direct"}],"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":7890},{"type":"tun"}]}`),
	}}
	f.ActiveConfigID = "full"
	caps := capabilitiesFor(f)
	if !caps.SystemProxy.Available {
		t.Fatalf("loopback mixed inbound should enable system proxy: %+v", caps.SystemProxy)
	}
	if caps.Tun.Available || caps.Tun.Reason == "" {
		t.Fatalf("imported TUN must be visible but not controllable: %+v", caps.Tun)
	}
}

func TestImportedProfileReportsOnlyEffectiveCapture(t *testing.T) {
	f := state.DefaultFile()
	f.Capture = state.Capture{SystemProxy: true, Tun: true}
	f.Profiles = []state.ConfigProfile{{
		ID: "full", Kind: state.ProfileKindSubscription,
		Config: []byte(`{"outbounds":[{"type":"direct","tag":"direct"}],"inbounds":[{"type":"tun"}]}`),
	}}
	f.ActiveConfigID = "full"
	if got := effectiveCapture(f, true); got.SystemProxy || !got.Tun {
		t.Fatalf("unexpected effective capture: %+v", got)
	}
	if got := effectiveCapture(f, false); got.Tun {
		t.Fatalf("stopped imported core must not report active TUN: %+v", got)
	}
}

func TestImportedProfileStatusDoesNotClaimAppSelectedNode(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Profiles = []state.ConfigProfile{{ID: "full", Kind: state.ProfileKindSubscription, Config: []byte(`{"outbounds":[{"type":"direct","tag":"direct"}]}`)}}
		f.ActiveConfigID = "full"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if got := a.Status().SelectedLabel; got != "由完整配置管理" {
		t.Fatalf("full profile selected label=%q", got)
	}
}

func TestSetProfileScriptRejectsInvalidTransformWithoutPersistingIt(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error { f.Wanted = false; return nil }); err != nil {
		t.Fatal(err)
	}
	id := a.Store().Get().ActiveConfigID
	if err := a.SetProfileScript(id, "function transform() { return 'not nodes' }"); err == nil {
		t.Fatal("invalid script should be rejected")
	}
	if got := a.Store().Get().ActiveProfile().Script; got != "" {
		t.Fatalf("invalid script persisted: %q", got)
	}
	valid := "function transform(nodes) { return nodes; }"
	if err := a.SetProfileScript(id, valid); err != nil {
		t.Fatal(err)
	}
	if got := a.Store().Get().ActiveProfile().Script; got != valid {
		t.Fatalf("valid script not persisted: %q", got)
	}
}

func TestSetProfileScriptKeepsSelectedNodeIdentity(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Wanted = false
		f.Selected = "原始节点"
		f.Profiles[0].ManualNodes = []state.Node{{
			ID: "node", Name: "原始节点", Protocol: "direct", Outbound: json.RawMessage(`{"type":"direct"}`),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	id := a.Store().Get().ActiveConfigID
	source := `function transform(nodes) { return nodes.map(n => ({...n, name: "优选 " + n.name})); }`
	if err := a.SetProfileScript(id, source); err != nil {
		t.Fatal(err)
	}
	if got := a.Store().Get().Selected; got != "优选 原始节点" {
		t.Fatalf("selected tag=%q", got)
	}
	nodes := a.Nodes()
	if len(nodes) != 1 || nodes[0].Name != "优选 原始节点" {
		t.Fatalf("effective app nodes=%+v", nodes)
	}
}

func TestNodesIncludesAutoWhenScriptAddsIt(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Wanted = false
		f.Profiles[0].ManualNodes = []state.Node{{
			ID: "n", Name: "n1", Protocol: "vless", Outbound: json.RawMessage(`{"type":"vless","server":"x.com","server_port":443,"uuid":"u"}`),
		}}
		f.Profiles[0].Script = `function main(config) {
  config.outbounds.push({type:'urltest', tag:'auto', outbounds:['n1'], url:'https://www.gstatic.com/generate_204'});
  const proxy = config.outbounds.find(o => o.tag === 'proxy');
  if (proxy) proxy.outbounds = ['auto', 'n1'];
  return config;
}`
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	nodes := a.Nodes()
	if len(nodes) < 1 || nodes[0].Tag != "auto" {
		t.Fatalf("auto outbound should appear in nodes: %+v", nodes)
	}
}

func TestSetProfileScriptValidatesInactiveProfile(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Wanted = false
		f.Profiles = append(f.Profiles, state.ConfigProfile{ID: "inactive", Name: "inactive", Kind: state.ProfileKindNodes})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := a.SetProfileScript("inactive", "function transform() { return 'not nodes' }"); err == nil {
		t.Fatal("invalid inactive script should be rejected")
	}
	for _, p := range a.Store().Get().Profiles {
		if p.ID == "inactive" && p.Script != "" {
			t.Fatalf("invalid inactive script persisted: %q", p.Script)
		}
	}
}

func TestActivateProfileValidationFailureKeepsActiveProfile(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	fakeCore := filepath.Join(t.TempDir(), "sing-box")
	if err := os.WriteFile(fakeCore, []byte("#!/bin/sh\nif [ \"$1\" = check ]; then exit 1; fi\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := a.CreateSubscriptionProfile("完整", "", `{"outbounds":[{"type":"direct","tag":"direct"}]}`); err != nil {
		t.Fatal(err)
	}
	f := a.Store().Get()
	target := f.Profiles[len(f.Profiles)-1].ID
	previous := f.ActiveConfigID
	if _, err := a.Store().Update(func(cur *state.File) error { cur.Settings.CorePath = fakeCore; cur.Wanted = true; return nil }); err != nil {
		t.Fatal(err)
	}
	if err := a.ActivateProfile(target); err == nil {
		t.Fatal("expected candidate validation failure")
	}
	if got := a.Store().Get().ActiveConfigID; got != previous {
		t.Fatalf("active profile changed after failed validation: %s", got)
	}
}

func TestCreateNodeProfileRefreshKeepsLastGoodSource(t *testing.T) {
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls#node"))
	}))
	defer good.Close()
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := a.CreateNodeProfile("节点池", []string{good.URL}); err != nil {
		t.Fatal(err)
	}
	profiles := a.Profiles()
	p := profiles[len(profiles)-1]
	if p.NodeCount != 1 {
		t.Fatalf("node count=%d", p.NodeCount)
	}
	if _, err := a.RefreshProfile(p.ID); err != nil {
		t.Fatal(err)
	}
	if got := a.Profiles()[len(profiles)-1].NodeCount; got != 1 {
		t.Fatalf("refresh lost nodes: %d", got)
	}
}

func TestRefreshAllProfilesUsesBoundedConcurrentProfileWorkers(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(150 * time.Millisecond)
		_, _ = w.Write([]byte("vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls#node"))
	}))
	defer server.Close()
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Wanted = false
		f.Profiles = nil
		for i := 0; i < 4; i++ {
			id := fmt.Sprintf("profile-%d", i)
			f.Profiles = append(f.Profiles, state.ConfigProfile{
				ID: id, Name: id, Kind: state.ProfileKindNodes,
				Sources: []state.ConfigSource{{ID: "source-" + id, URL: server.URL}},
			})
		}
		f.ActiveConfigID = "profile-0"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	updated, err := a.RefreshAllProfiles()
	if err != nil {
		t.Fatal(err)
	}
	if updated != 4 {
		t.Fatalf("updated=%d, want 4", updated)
	}
	if elapsed := time.Since(started); elapsed >= 450*time.Millisecond {
		t.Fatalf("profile refresh ran serially: elapsed=%s", elapsed)
	}
}

func TestRefreshNodeProfileRecordsPerSourceOutcomes(t *testing.T) {
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls#node"))
	}))
	defer good.Close()
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer bad.Close()
	p := state.ConfigProfile{Kind: state.ProfileKindNodes, Sources: []state.ConfigSource{
		{ID: "good", URL: good.URL},
		{ID: "bad", URL: bad.URL, Nodes: []state.Node{{ID: "last-good", Name: "last-good"}}},
	}}
	a := &App{}
	updated, err := a.refreshNodeProfile(context.Background(), &p)
	if err != nil || updated != 1 {
		t.Fatalf("updated=%d err=%v", updated, err)
	}
	if len(p.RefreshHistory) != 2 {
		t.Fatalf("refresh history=%+v", p.RefreshHistory)
	}
	results := map[string]string{}
	for _, event := range p.RefreshHistory {
		results[event.SourceID] = event.Outcome
	}
	if results["good"] != "succeeded" || results["bad"] != "failed" {
		t.Fatalf("source outcomes=%+v", results)
	}
	if len(p.Sources[1].Nodes) != 1 || p.Sources[1].Nodes[0].ID != "last-good" {
		t.Fatalf("failed source lost last good nodes: %+v", p.Sources[1].Nodes)
	}
}

func TestRecentRefreshesRedactsReasonsAndLimitsPresentation(t *testing.T) {
	history := make([]state.RefreshEvent, 0, refreshHistoryPresentationLimit+1)
	for i := range refreshHistoryPresentationLimit + 1 {
		history = append(history, state.RefreshEvent{
			At:       int64(i),
			SourceID: fmt.Sprintf("source-%d", i),
			Outcome:  "failed",
			Reason:   "fetch https://user:secret@example.com/subscription failed",
		})
	}

	refreshes := recentRefreshes(history)
	if len(refreshes) != refreshHistoryPresentationLimit {
		t.Fatalf("presented refreshes=%d, want %d", len(refreshes), refreshHistoryPresentationLimit)
	}
	if refreshes[0].SourceID != "source-1" {
		t.Fatalf("oldest refresh was not discarded: %+v", refreshes)
	}
	for _, refresh := range refreshes {
		if strings.Contains(refresh.Reason, "secret") || strings.Contains(refresh.Reason, "example.com") {
			t.Fatalf("refresh reason was not redacted: %q", refresh.Reason)
		}
	}
}

func TestSubscriptionRefreshFailureKeepsLastGoodConfig(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"inbounds":[]}`))
	}))
	defer server.Close()
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	oldConfig := []byte(`{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`)
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Wanted = false
		f.Profiles = []state.ConfigProfile{{
			ID: "full", Kind: state.ProfileKindSubscription, Source: server.URL, Config: oldConfig,
		}}
		f.ActiveConfigID = "full"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := a.RefreshProfile("full"); err == nil {
		t.Fatal("expected invalid subscription refresh to fail")
	}
	profile := a.Store().Get().ActiveProfile()
	if string(profile.Config) != string(oldConfig) {
		t.Fatalf("refresh failure replaced full config: %s", profile.Config)
	}
	if profile.LastError == "" {
		t.Fatal("refresh failure was not recorded")
	}
}

func TestActiveRefreshValidationFailureKeepsPersistedNodes(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("vless://00000000-0000-0000-0000-000000000000@new.example:443?security=tls#new"))
	}))
	defer server.Close()
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	fakeCore := filepath.Join(t.TempDir(), "sing-box")
	if err := os.WriteFile(fakeCore, []byte("#!/bin/sh\nexit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	active := a.Store().Get().ActiveConfigID
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Wanted = true
		f.Settings.CorePath = fakeCore
		f.Profiles[0].Sources = []state.ConfigSource{{
			ID: "source", URL: server.URL,
			Nodes: []state.Node{{ID: "old", Name: "old", Outbound: []byte(`{"type":"direct"}`)}},
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := a.RefreshProfile(active); err == nil {
		t.Fatal("expected candidate validation failure")
	}
	f := a.Store().Get()
	if got := f.ActiveProfile().Sources[0].Nodes[0].Name; got != "old" {
		t.Fatalf("refresh failure persisted candidate nodes: %q", got)
	}
	if f.ActiveProfile().LastError == "" {
		t.Fatal("refresh candidate failure was not recorded")
	}
}

func TestProfileSourceSummaryRedactsURLCredentials(t *testing.T) {
	summaries := sourceSummaries([]state.ConfigSource{{ID: "s", URL: "https://user:secret@example.test/sub?token=private", Nodes: []state.Node{{ID: "n"}}}})
	if len(summaries) != 1 || summaries[0].Name != "example.test" || summaries[0].NodeCount != 1 {
		t.Fatalf("unexpected summaries: %+v", summaries)
	}
}

func TestProfilesRedactURLsInSourceErrors(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Profiles[0].LastError = "Get https://user:secret@example.test/path?token=private failed"
		f.Profiles[0].Sources = []state.ConfigSource{{ID: "s", URL: "https://example.test/sub", LastError: "request https://example.test/sub?token=private failed"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	profiles := a.Profiles()
	encoded, err := json.Marshal(profiles)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "secret") || strings.Contains(string(encoded), "private") || strings.Contains(string(encoded), "example.test/sub") {
		t.Fatalf("profile response leaked URL: %s", encoded)
	}
}

func TestImportedProfileIncludesInboundSummaryWithoutConfig(t *testing.T) {
	f := state.DefaultFile()
	f.Profiles = []state.ConfigProfile{{ID: "full", Kind: state.ProfileKindSubscription, Config: []byte(`{"outbounds":[{"type":"direct","tag":"direct"}],"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":7890},{"type":"tun"}]}`)}}
	f.ActiveConfigID = "full"
	summary := inboundSummary(f)
	if summary == nil || summary.MixedLoopback != "127.0.0.1:7890" || !summary.HasTun {
		t.Fatalf("unexpected summary: %+v", summary)
	}
}

func TestImportedProfileInboundSummaryPreservesLoopbackAddress(t *testing.T) {
	f := state.DefaultFile()
	f.Profiles = []state.ConfigProfile{{ID: "full", Kind: state.ProfileKindSubscription, Config: []byte(`{"outbounds":[{"type":"direct","tag":"direct"}],"inbounds":[{"type":"mixed","listen":"::1","listen_port":7890}]}`)}}
	f.ActiveConfigID = "full"
	summary := inboundSummary(f)
	if summary == nil || summary.MixedLoopback != "::1:7890" {
		t.Fatalf("unexpected summary: %+v", summary)
	}
}

func TestSetCaptureSystemProxyPersistsWithoutRestartingCore(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	fakeCore := filepath.Join(t.TempDir(), "sing-box")
	if err := os.WriteFile(fakeCore, []byte("#!/bin/sh\nif [ \"$1\" = check ]; then exit 0; fi\nexit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Settings.CorePath = fakeCore
		f.Wanted = true
		f.Capture = state.Capture{SystemProxy: true, Tun: false}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := a.SetCapture(state.Capture{SystemProxy: false, Tun: false}); err != nil {
		t.Fatalf("turning system proxy off should not restart the core: %v", err)
	}
	if got := a.Store().Get().Capture; got != (state.Capture{SystemProxy: false}) {
		t.Fatalf("capture was not persisted: %+v", got)
	}
}

func TestFullProfileSystemProxyOffPersistsWhenCoreStopped(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	fakeCore := filepath.Join(t.TempDir(), "sing-box")
	if err := os.WriteFile(fakeCore, []byte("#!/bin/sh\nif [ \"$1\" = check ]; then exit 0; fi\nexit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Settings.CorePath = fakeCore
		f.Wanted = true
		f.Capture = state.Capture{SystemProxy: true}
		f.Profiles = []state.ConfigProfile{{
			ID: "full", Kind: state.ProfileKindSubscription,
			Config: []byte(`{"outbounds":[{"type":"direct","tag":"direct"}],"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":7890}]}`),
		}}
		f.ActiveConfigID = "full"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := a.SetCapture(state.Capture{SystemProxy: false}); err != nil {
		t.Fatalf("full-profile system proxy off should persist without a live core: %v", err)
	}
	if got := a.Store().Get().Capture; got.SystemProxy {
		t.Fatalf("full-profile capture was not persisted: %+v", got)
	}
}

func TestTunValidationFailureDoesNotDisableExistingCapture(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	t.Setenv("ASTER_HELPER_SOCKET", filepath.Join(t.TempDir(), "missing-helper.sock"))
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	fakeCore := filepath.Join(t.TempDir(), "sing-box")
	if err := os.WriteFile(fakeCore, []byte("#!/bin/sh\nexit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Settings.CorePath = fakeCore
		f.Wanted = true
		f.Capture = state.Capture{SystemProxy: true}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	err = a.SetCapture(state.Capture{SystemProxy: true, Tun: true})
	if err == nil {
		t.Fatal("expected TUN enable to fail without helper")
	}
	if got := a.Store().Get().Capture; got != (state.Capture{SystemProxy: true}) {
		t.Fatalf("TUN failure changed persisted capture: %+v", got)
	}
}

func TestSelectUnknownNodeDoesNotChangeState(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error { f.Wanted = false; return nil }); err != nil {
		t.Fatal(err)
	}
	before := a.Store().Get().Selected
	if err := a.SelectNode("unknown"); err == nil {
		t.Fatal("unknown node should be rejected")
	}
	if got := a.Store().Get().Selected; got != before {
		t.Fatalf("unknown selection changed state: %q", got)
	}
}

func TestSettingsValidationFailureDoesNotPersistSettings(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	fakeCore := filepath.Join(t.TempDir(), "sing-box")
	if err := os.WriteFile(fakeCore, []byte("#!/bin/sh\nexit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	before := a.Store().Get().Settings
	if _, err := a.Store().Update(func(f *state.File) error { f.Settings.CorePath = fakeCore; return nil }); err != nil {
		t.Fatal(err)
	}
	updated := a.Store().Get().Settings
	updated.MixedPort = 29999
	if err := a.PutSettings(updated); err == nil {
		t.Fatal("expected settings candidate validation failure")
	}
	if got := a.Store().Get().Settings.MixedPort; got != before.MixedPort {
		t.Fatalf("settings failure persisted port: %d", got)
	}
}

func TestValidateSettingsRejectsUnsafeValues(t *testing.T) {
	valid := state.DefaultFile().Settings
	if err := validateSettings(valid); err != nil {
		t.Fatalf("default settings should be valid: %v", err)
	}
	for _, mutate := range []func(*state.Settings){
		func(s *state.Settings) { s.MixedPort = 0 },
		func(s *state.Settings) { s.ClashPort = 65536 },
		func(s *state.Settings) { s.ClashPort = s.MixedPort },
		func(s *state.Settings) { s.DelayURL = "file:///tmp/probe" },
		func(s *state.Settings) { s.DelayTimeoutMs = 0 },
		func(s *state.Settings) { s.DelayConcurrency = 65 },
		func(s *state.Settings) { s.DNSMode = "unknown" },
		func(s *state.Settings) { s.LogLevel = "verbose" },
		func(s *state.Settings) { s.LogRetention = "forever" },
	} {
		s := valid
		mutate(&s)
		if err := validateSettings(s); err == nil {
			t.Fatalf("invalid settings were accepted: %+v", s)
		}
	}
}

func TestValidateSettingsAcceptsDefaultPorts(t *testing.T) {
	s := state.DefaultFile().Settings
	if err := validateSettings(s); err != nil {
		t.Fatal(err)
	}
}

func TestFullProfileRejectsNodeRenderSettings(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Profiles = []state.ConfigProfile{{ID: "full", Kind: state.ProfileKindSubscription, Config: []byte(`{"outbounds":[{"type":"direct","tag":"direct"}]}`)}}
		f.ActiveConfigID = "full"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	before := a.Store().Get().Settings
	updated := before
	updated.AllowLan = !updated.AllowLan
	if err := a.PutSettings(updated); err == nil {
		t.Fatal("expected full profile node-render setting to be rejected")
	}
	if got := a.Store().Get().Settings.AllowLan; got != before.AllowLan {
		t.Fatalf("allowLan changed from %v to %v", before.AllowLan, got)
	}
}

func TestPortableBackupContainsOnlyConfigurationAndPreservesMachineState(t *testing.T) {
	originDir := t.TempDir()
	t.Setenv("ASTER_DATA_DIR", originDir)
	origin, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := origin.Store().Update(func(f *state.File) error {
		f.Settings.CorePath = "/origin/sing-box"
		f.Settings.MixedPort = 12080
		f.Settings.ClashPort = 12090
		f.Settings.AllowLan = true
		f.Settings.Autostart = true
		f.Settings.DirectCN = false
		f.Settings.DelayURL = "https://example.test/generate_204"
		f.Capture = state.Capture{SystemProxy: false, Tun: true}
		f.Wanted = false
		f.ClashSecret = "origin-clash-secret"
		f.APIToken = "origin-api-token"
		f.Runtime = state.RuntimeState{LastFailure: "origin runtime failure"}
		f.RecentNodes = []string{"origin-node"}
		f.Profiles[0].Name = "可迁移节点池"
		f.Rules = []state.Rule{{ID: "rule-1", Match: "domain", Value: "example.test", Action: "proxy"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	archive, err := origin.ExportZip()
	if err != nil {
		t.Fatal(err)
	}
	reader, err := zip.NewReader(bytes.NewReader(archive), int64(len(archive)))
	if err != nil {
		t.Fatal(err)
	}
	profileName, err := portableDocumentName(backupProfilesDir, origin.Store().Get().Profiles[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	expectedEntries := map[string]bool{
		backupManifestName: true, backupSettingsName: true, backupRulesName: true, profileName: true,
	}
	if len(reader.File) != len(expectedEntries) {
		t.Fatalf("backup file count=%d, want %d", len(reader.File), len(expectedEntries))
	}
	archiveData := make([][]byte, 0, len(reader.File))
	for _, entry := range reader.File {
		if !expectedEntries[entry.Name] {
			t.Fatalf("unexpected backup entry: %s", entry.Name)
		}
		file, err := entry.Open()
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(file)
		if closeErr := file.Close(); closeErr != nil && err == nil {
			err = closeErr
		}
		if err != nil {
			t.Fatal(err)
		}
		archiveData = append(archiveData, data)
	}
	for _, forbidden := range []string{"apiToken", "clashSecret", "corePath", "mixedPort", "controlPort", "capture", "runtime", "wanted"} {
		for _, data := range archiveData {
			if bytes.Contains(data, []byte(`"`+forbidden+`"`)) {
				t.Fatalf("portable archive unexpectedly contains %q: %s", forbidden, data)
			}
		}
	}

	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	target, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := target.Store().Update(func(f *state.File) error {
		f.Settings.CorePath = "/target/sing-box"
		f.Settings.MixedPort = 22080
		f.Settings.ClashPort = 22090
		f.Settings.AllowLan = false
		f.Settings.Autostart = false
		f.Capture = state.Capture{SystemProxy: true, Tun: false}
		f.Wanted = true
		f.ClashSecret = "target-clash-secret"
		f.APIToken = "target-api-token"
		f.Runtime = state.RuntimeState{LastFailure: "target runtime failure"}
		f.RecentNodes = []string{"target-node"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	if err := target.ImportZip(bytes.NewReader(archive)); err != nil {
		t.Fatal(err)
	}
	after := target.Store().Get()
	if after.APIToken != "target-api-token" || after.ClashSecret != "target-clash-secret" {
		t.Fatalf("restore replaced local credentials: token=%q secret=%q", after.APIToken, after.ClashSecret)
	}
	if after.Settings.CorePath != "/target/sing-box" || after.Settings.MixedPort != 22080 || after.Settings.ClashPort != 22090 {
		t.Fatalf("restore replaced local runtime settings: %+v", after.Settings)
	}
	if after.Settings.AllowLan || after.Settings.Autostart || after.Capture != (state.Capture{SystemProxy: true}) || !after.Wanted {
		t.Fatalf("restore replaced local activation state: %+v", after)
	}
	if after.Settings.DirectCN || after.Settings.DelayURL != "https://example.test/generate_204" || after.Profiles[0].Name != "可迁移节点池" || len(after.Rules) != 1 {
		t.Fatalf("restore missed portable configuration: %+v", after)
	}
	if len(after.RecentNodes) != 0 || after.Runtime.LastSuccessfulConfigID != "" || after.Runtime.LastSuccessfulAt != 0 || after.Runtime.LastFailure != "" || len(after.Runtime.History) != 0 {
		t.Fatalf("restore retained non-portable operational state: %+v", after)
	}
}

func TestBackupImportRejectsOversizedArchiveWithoutChangingState(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	before := a.Store().Get().ActiveConfigID
	if err := a.ImportZip(bytes.NewReader(make([]byte, maxBackupBytes+1))); err == nil {
		t.Fatal("oversized archive should be rejected")
	}
	if got := a.Store().Get().ActiveConfigID; got != before {
		t.Fatalf("oversized import changed state: %q", got)
	}
}

func TestBackupImportRejectsInvalidInactiveProfileWithoutChangingState(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	before := a.Store().Get()
	archive := portableArchive(t, before, func(backup *portableBackup) {
		backup.Profiles = append(backup.Profiles, portableBackupProfile{
			ID: "broken", Name: "损坏配置", Kind: state.ProfileKindSubscription, Config: json.RawMessage(`{"outbounds":"not-an-array"}`),
		})
	})
	if err := a.ImportZip(bytes.NewReader(archive)); err == nil {
		t.Fatal("invalid inactive profile should be rejected")
	}
	after := a.Store().Get()
	if after.ActiveConfigID != before.ActiveConfigID || len(after.Profiles) != len(before.Profiles) {
		t.Fatalf("failed import changed state: before=%+v after=%+v", before, after)
	}
}

func TestBackupImportRejectsDuplicateNodeIDsWithoutChangingState(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	before := a.Store().Get()
	archive := portableArchive(t, before, func(backup *portableBackup) {
		backup.Profiles[0].ManualNodes = []state.Node{
			{ID: "duplicate", Name: "节点一", Protocol: "direct", Outbound: json.RawMessage(`{"type":"direct"}`)},
			{ID: "duplicate", Name: "节点二", Protocol: "direct", Outbound: json.RawMessage(`{"type":"direct"}`)},
		}
	})
	if err := a.ImportZip(bytes.NewReader(archive)); err == nil {
		t.Fatal("duplicate node IDs should be rejected")
	}
	after := a.Store().Get()
	if after.ActiveConfigID != before.ActiveConfigID || len(after.Profiles[0].ManualNodes) != len(before.Profiles[0].ManualNodes) {
		t.Fatalf("failed import changed state: before=%+v after=%+v", before, after)
	}
}

func TestWritePrivateAtomicUsesPrivatePermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "backup.json")
	if err := writePrivateAtomic(path, []byte(`{"ok":true}`)); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("backup permissions=%#o, want 0600", got)
	}
	if data, err := os.ReadFile(path); err != nil || string(data) != `{"ok":true}` {
		t.Fatalf("backup data=%q err=%v", data, err)
	}
}

func TestICloudBackupRoundTripUsesPrivateAtomicFile(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	cloudRoot := filepath.Join(home, "Library", "Mobile Documents", "com~apple~CloudDocs")
	if err := os.MkdirAll(cloudRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Wanted = false
		f.Profiles[0].Name = "备份前"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := a.ExportToICloud(); err != nil {
		t.Fatal(err)
	}
	backup := filepath.Join(cloudRoot, "Aster", iCloudBackupName)
	info, err := os.Stat(backup)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("iCloud backup permissions=%#o, want 0600", got)
	}
	if !a.ICloudStatus()["hasBackup"].(bool) {
		t.Fatal("iCloud status did not find backup")
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Profiles[0].Name = "已修改"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := a.ImportFromICloud(); err != nil {
		t.Fatal(err)
	}
	if got := a.Store().Get().Profiles[0].Name; got != "备份前" {
		t.Fatalf("iCloud restore profile name=%q", got)
	}
}

func portableArchive(t *testing.T, file state.File, mutate func(*portableBackup)) []byte {
	t.Helper()
	backup := portableBackupFromState(file)
	mutate(&backup)
	archive, err := encodePortableBackup(backup)
	if err != nil {
		t.Fatal(err)
	}
	return archive
}

func TestCreateSubscriptionProfile_AutoAdaptNonJSON(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}

	// 1. Clash YAML
	clash := `
proxies:
  - name: clash-ss
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-128-gcm
    password: pwd
`
	if err := a.CreateSubscriptionProfile("Clash 订阅测试", "", clash); err != nil {
		t.Fatalf("CreateSubscriptionProfile with Clash YAML failed: %v", err)
	}
	profiles := a.Store().Get().Profiles
	foundClash := false
	for _, p := range profiles {
		if p.Name == "Clash 订阅测试" {
			foundClash = true
			if p.Kind != state.ProfileKindNodes {
				t.Fatalf("expected ProfileKindNodes, got %s", p.Kind)
			}
			if len(p.ManualNodes) != 1 || p.ManualNodes[0].Name != "clash-ss" {
				t.Fatalf("unexpected nodes: %+v", p.ManualNodes)
			}
		}
	}
	if !foundClash {
		t.Fatal("Clash profile not found")
	}

	// 2. Base64 URI list
	b64 := base64.StdEncoding.EncodeToString([]byte("trojan://password123@example.com:443#trojan-b64\n"))
	if err := a.CreateSubscriptionProfile("Base64 订阅测试", "", b64); err != nil {
		t.Fatalf("CreateSubscriptionProfile with Base64 failed: %v", err)
	}
	profiles = a.Store().Get().Profiles
	foundB64 := false
	for _, p := range profiles {
		if p.Name == "Base64 订阅测试" {
			foundB64 = true
			if p.Kind != state.ProfileKindNodes {
				t.Fatalf("expected ProfileKindNodes, got %s", p.Kind)
			}
			if len(p.ManualNodes) != 1 || p.ManualNodes[0].Name != "trojan-b64" {
				t.Fatalf("unexpected nodes: %+v", p.ManualNodes)
			}
		}
	}
	if !foundB64 {
		t.Fatal("Base64 profile not found")
	}

	// 3. sing-box JSON
	sbJSON := `{"outbounds":[{"type":"direct","tag":"direct"}]}`
	if err := a.CreateSubscriptionProfile("sing-box JSON测试", "", sbJSON); err != nil {
		t.Fatalf("CreateSubscriptionProfile with sing-box JSON failed: %v", err)
	}
	profiles = a.Store().Get().Profiles
	foundSB := false
	for _, p := range profiles {
		if p.Name == "sing-box JSON测试" {
			foundSB = true
			if p.Kind != state.ProfileKindSubscription {
				t.Fatalf("expected ProfileKindSubscription, got %s", p.Kind)
			}
		}
	}
	if !foundSB {
		t.Fatal("sing-box profile not found")
	}
}

func TestProfileContent(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	raw := `{"outbounds":[{"type":"shadowsocks","tag":"ss-node","server":"1.2.3.4","server_port":8388,"method":"aes-128-gcm","password":"pwd"},{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`
	if err := a.CreateSubscriptionProfile("完整配置内容测试", "", raw); err != nil {
		t.Fatal(err)
	}
	profiles := a.Store().Get().Profiles
	var subID string
	for _, p := range profiles {
		if p.Name == "完整配置内容测试" {
			subID = p.ID
			break
		}
	}
	if subID == "" {
		t.Fatal("profile not found")
	}

	content, err := a.ProfileContent(subID)
	if err != nil {
		t.Fatalf("ProfileContent error: %v", err)
	}
	if content.ID != subID || content.Format != "json" {
		t.Fatalf("unexpected content meta: %+v", content)
	}
	if !strings.Contains(content.Content, `"tag": "ss-node"`) {
		t.Fatalf("content missing ss-node: %s", content.Content)
	}
	if content.NodeCount != 1 {
		t.Fatalf("expected nodeCount=1, got %d", content.NodeCount)
	}

	// Set active profile in store and check Nodes()
	if _, err := a.Store().Update(func(cur *state.File) error {
		cur.ActiveConfigID = subID
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	nodes := a.Nodes()
	foundSS := false
	for _, n := range nodes {
		if n.Tag == "ss-node" {
			foundSS = true
			if n.Protocol != "shadowsocks" {
				t.Fatalf("expected protocol shadowsocks, got %s", n.Protocol)
			}
		}
	}
	if !foundSS {
		t.Fatalf("expected ss-node in Nodes(), got: %+v", nodes)
	}
}
