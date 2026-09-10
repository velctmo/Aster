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
