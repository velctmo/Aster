package app

import (
	"strings"
	"testing"

	"aster/internal/state"
)

func TestImportedProxyEndpointPreservesIPv6Loopback(t *testing.T) {
	f := state.DefaultFile()
	f.Profiles = []state.ConfigProfile{{
		ID: "full", Kind: state.ProfileKindSubscription,
		ImportedMixedListen: "::1", ImportedMixedPort: 7890,
	}}
	f.ActiveConfigID = "full"
	if got := proxyHost(f); got != "::1" {
		t.Fatalf("proxy host=%q", got)
	}
	if got := proxyPort(f); got != 7890 {
		t.Fatalf("proxy port=%d", got)
	}
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(current *state.File) error {
		*current = f
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if env := a.ProxyEnv(); !strings.Contains(env, "http://[::1]:7890") || !strings.Contains(env, "socks5://[::1]:7890") {
		t.Fatalf("proxy environment lost IPv6 endpoint: %q", env)
	}
}
