package app

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"aster/internal/state"
)

func TestControlAddrAndToken(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ASTER_DATA_DIR", dir)
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if a.APIToken() == "" {
		t.Fatal("empty token")
	}
	if a.ControlAddr() != "127.0.0.1:1780" {
		t.Fatalf("addr=%s", a.ControlAddr())
	}
	if err := a.WriteDaemonPID(); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "daemon.pid"))
	if err != nil || len(b) == 0 {
		t.Fatalf("pid file: %v %q", err, b)
	}
	a.ClearDaemonPID()
	if _, err := os.Stat(filepath.Join(dir, "daemon.pid")); !os.IsNotExist(err) {
		t.Fatalf("pid should be removed: %v", err)
	}
	_ = time.Second
}

func TestAuthorizationFailureDoesNotAutoRestart(t *testing.T) {
	f := state.DefaultFile()
	now := time.Now()
	if shouldAutoRestart(f, true, 0, now.Add(-time.Second), now) {
		t.Fatal("authorization failure must wait for an explicit user action")
	}
	if !shouldAutoRestart(f, false, 0, now.Add(-time.Second), now) {
		t.Fatal("ordinary stopped core should still use bounded recovery")
	}
}

func TestStartSessionPreservesFailureInsteadOfPersistingStoppedState(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Wanted = false
		f.Settings.CorePath = filepath.Join(t.TempDir(), "missing-sing-box")
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := a.StartSession(); err == nil {
		t.Fatal("expected unavailable core failure")
	}
	if a.Store().Get().Wanted {
		t.Fatal("failed auto-start must not pretend the core is running")
	}
	status := a.Status()
	if status.SessionPhase != "failed" || status.Error == "" {
		t.Fatalf("failure must remain visible: %+v", status)
	}
}

func TestRunBackgroundCoalescesSlowPeriodicWork(t *testing.T) {
	a := &App{}
	var running bool
	var calls atomic.Int32
	started := make(chan struct{})
	release := make(chan struct{})
	a.runBackground(context.Background(), &running, func() {
		calls.Add(1)
		close(started)
		<-release
	})
	<-started
	a.runBackground(context.Background(), &running, func() { calls.Add(1) })
	if got := calls.Load(); got != 1 {
		t.Fatalf("slow periodic task should be coalesced, calls=%d", got)
	}
	close(release)
	deadline := time.After(time.Second)
	for {
		a.mu.Lock()
		done := !running
		a.mu.Unlock()
		if done {
			return
		}
		select {
		case <-deadline:
			t.Fatal("background task did not clear running flag")
		case <-time.After(time.Millisecond):
		}
	}
}

func TestWaitBackgroundWaitsForTrackedWork(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	release := make(chan struct{})
	a.runBackground(context.Background(), new(bool), func() {
		close(started)
		<-release
	})
	<-started
	done := make(chan struct{})
	go func() {
		a.waitBackground()
		close(done)
	}()
	select {
	case <-done:
		t.Fatal("wait barrier finished before tracked background work")
	case <-time.After(25 * time.Millisecond):
	}
	close(release)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("wait barrier did not finish after background work drained")
	}
}
