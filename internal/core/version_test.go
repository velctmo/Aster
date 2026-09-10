package core

import "testing"

func TestManagerVersionIsCachedState(t *testing.T) {
	m := &Manager{version: "sing-box 1.14.0"}
	if got := m.Version(); got != "sing-box 1.14.0" {
		t.Fatalf("version=%q", got)
	}
}
