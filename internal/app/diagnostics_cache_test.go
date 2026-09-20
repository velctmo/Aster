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

func TestGetNetworkDiagnostics_NoFakeFallbacks(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	diag := a.GetNetworkDiagnostics(true)
	if diag.ProxyDelayMs == 45 {
		t.Fatalf("found hardcoded 45ms fake proxy delay: %+v", diag)
	}
	if diag.InternetDelayMs < 0 {
		t.Fatalf("invalid negative internet delay: %+v", diag)
	}
}

