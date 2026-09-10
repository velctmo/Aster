package app

import "testing"

func TestNetworkDiagnosticsCacheIsScopedToApp(t *testing.T) {
	first := &App{cachedDiagnostics: NetworkDiagnostics{ConfigName: "first", FetchedAt: 1}}
	second := &App{}
	if first.cachedDiagnostics.ConfigName != "first" {
		t.Fatal("first cache setup failed")
	}
	if second.cachedDiagnostics.ConfigName != "" || second.cachedDiagnostics.FetchedAt != 0 {
		t.Fatalf("second app inherited diagnostics cache: %+v", second.cachedDiagnostics)
	}
}
