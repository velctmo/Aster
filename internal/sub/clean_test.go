package sub

import (
	"strings"
	"testing"

	"aster/internal/state"
)

func TestCleanAndFilterNodes(t *testing.T) {
	nodes := []state.Node{
		{Name: "HK-01"},
		{Name: "剩余流量：100G"},
		{Name: "官网 https://example.com"},
		{Name: "US-Node"},
	}
	out := CleanAndFilterNodes(nodes, `官网`)
	if len(out) != 2 {
		t.Fatalf("expected 2 nodes, got %d: %+v", len(out), out)
	}
	for _, n := range out {
		if strings.Contains(n.Name, "剩余流量") || strings.Contains(n.Name, "官网") {
			t.Fatalf("should have cleaned %q", n.Name)
		}
	}
}
