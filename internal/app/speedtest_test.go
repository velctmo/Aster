package app

import "testing"

func TestSpeedtestRejectsUnknownNodeBeforeUsingSelector(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.SpeedtestNode("does-not-exist"); err == nil {
		t.Fatal("unknown node must not be passed to the selector")
	}
}
