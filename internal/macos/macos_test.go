package macos

import "testing"

func TestProxyOutputMatchesOnlyAsterEndpoint(t *testing.T) {
	matching := []byte("Enabled: Yes\nServer: 127.0.0.1\nPort: 2080\nAuthenticated Proxy Enabled: 0\n")
	if !proxyOutputMatches(matching, "127.0.0.1", 2080) {
		t.Fatal("expected matching Aster endpoint")
	}
	for _, tc := range []struct {
		name string
		data []byte
		host string
		port int
	}{
		{"disabled", []byte("Enabled: No\nServer: 127.0.0.1\nPort: 2080\n"), "127.0.0.1", 2080},
		{"other host", []byte("Enabled: Yes\nServer: proxy.example\nPort: 2080\n"), "127.0.0.1", 2080},
		{"other port", []byte("Enabled: Yes\nServer: 127.0.0.1\nPort: 8080\n"), "127.0.0.1", 2080},
		{"missing port", []byte("Enabled: Yes\nServer: 127.0.0.1\n"), "127.0.0.1", 2080},
	} {
		if proxyOutputMatches(tc.data, tc.host, tc.port) {
			t.Fatalf("%s unexpectedly matched", tc.name)
		}
	}
	if !proxyOutputMatches([]byte("Enabled: Yes\nServer: ::1\nPort: 7890\n"), "[::1]", 7890) {
		t.Fatal("expected bracketed IPv6 endpoint to match")
	}
}

func TestInspectServiceRejectsMixedForeignProxy(t *testing.T) {
	owned := []byte("Enabled: Yes\nServer: 127.0.0.1\nPort: 6780\n")
	foreign := []byte("Enabled: Yes\nServer: proxy.corp\nPort: 8080\n")
	disabled := []byte("Enabled: No\nServer: 127.0.0.1\nPort: 6780\n")
	ins := inspectServiceFromOutputs("127.0.0.1", 6780, [][]byte{owned, disabled, foreign})
	if !ins.Owned || !ins.Foreign {
		t.Fatalf("mixed service must be owned+foreign: %+v", ins)
	}
	exclusive := inspectServiceFromOutputs("127.0.0.1", 6780, [][]byte{owned, disabled, disabled})
	if !exclusive.Owned || exclusive.Foreign {
		t.Fatalf("exclusive Aster service: %+v", exclusive)
	}
}

func TestScutilPointsToAsterMixedPort(t *testing.T) {
	raw := []byte(`<dictionary> {
  HTTPEnable : 1
  HTTPPort : 6780
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 6780
  HTTPSProxy : 127.0.0.1
  SOCKSEnable : 0
}`)
	if !scutilPointsTo(raw, "127.0.0.1", 6780) {
		t.Fatal("expected scutil to match Aster mixed endpoint")
	}
	if scutilPointsTo(raw, "127.0.0.1", 2080) {
		t.Fatal("old mixed port must not match current endpoint")
	}
	corporate := []byte("HTTPEnable : 1\nHTTPPort : 8080\nHTTPProxy : proxy.corp\n")
	if scutilPointsTo(corporate, "127.0.0.1", 6780) {
		t.Fatal("corporate proxy must not be treated as Aster")
	}
}

func TestOwnershipRoundTrip(t *testing.T) {
	dir := t.TempDir()
	if err := WriteOwnership(dir, "127.0.0.1", 6780, 42); err != nil {
		t.Fatal(err)
	}
	got, ok := ReadOwnership(dir)
	if !ok || got.Host != "127.0.0.1" || got.Port != 6780 || got.PID != 42 {
		t.Fatalf("ownership=%+v ok=%v", got, ok)
	}
	ClearOwnership(dir)
	if _, ok := ReadOwnership(dir); ok {
		t.Fatal("ownership file should be removed")
	}
}
