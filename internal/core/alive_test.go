package core

import (
	"os"
	"testing"
)

func TestProcessAliveTreatsEPERMAsAlive(t *testing.T) {
	// PID 1 is launchd/init, owned by root. kill -0 from an unprivileged
	// process returns EPERM, which must still mean "alive" — otherwise a
	// TUN-started (root) sing-box looks dead and the app repeatedly requests authorization.
	if !processAlive(1) {
		t.Fatal("pid 1 exists; EPERM from Signal(0) must count as alive")
	}
}

func TestProcessAliveMissingPID(t *testing.T) {
	if processAlive(0) || processAlive(-1) {
		t.Fatal("non-positive pid must be dead")
	}
	if processAlive(999999999) {
		t.Fatal("unused pid must be dead")
	}
}

func TestProcessAliveSelf(t *testing.T) {
	if !processAlive(os.Getpid()) {
		t.Fatal("current process must be alive")
	}
}
