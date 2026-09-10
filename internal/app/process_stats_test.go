package app

import (
	"testing"

	"aster/internal/clash"
)

func TestProcessStatsAreScopedToEachApp(t *testing.T) {
	first := &App{}
	first.UpdateProcessStats([]clash.Connection{{
		ID: "one", Upload: 10, Download: 20,
		Metadata: clash.Metadata{Process: "First App"},
	}})
	if len(first.GetTopProcesses()) != 1 {
		t.Fatal("first app did not retain its process snapshot")
	}
	second := &App{}
	if got := second.GetTopProcesses(); len(got) != 0 {
		t.Fatalf("second app inherited another app's processes: %+v", got)
	}
}

func TestProcessStatsDropsInactiveHistory(t *testing.T) {
	a := &App{}
	a.UpdateProcessStats([]clash.Connection{{
		ID: "one", Metadata: clash.Metadata{Process: "Transient"},
	}})
	if len(a.processHist) != 1 {
		t.Fatalf("history=%+v", a.processHist)
	}
	a.UpdateProcessStats(nil)
	if len(a.processHist) != 0 {
		t.Fatalf("inactive process history was retained: %+v", a.processHist)
	}
}
