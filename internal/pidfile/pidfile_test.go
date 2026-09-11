package pidfile

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRemoveIfOwnerLeavesForeignPID(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	if err := Write(path, 1); err != nil {
		t.Fatal(err)
	}
	RemoveIfOwner(path, os.Getpid())
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("foreign pid file must survive: %v", err)
	}
}

func TestRemoveIfOwnerDeletesOwnPID(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	if err := Write(path, os.Getpid()); err != nil {
		t.Fatal(err)
	}
	RemoveIfOwner(path, os.Getpid())
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("own pid file must be removed: %v", err)
	}
}

func TestOwns(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.pid")
	if Owns(path, os.Getpid()) {
		t.Fatal("missing file is not owned")
	}
	if err := Write(path, os.Getpid()); err != nil {
		t.Fatal(err)
	}
	if !Owns(path, os.Getpid()) {
		t.Fatal("writer must own the pid file")
	}
	if Owns(path, os.Getpid()+1) {
		t.Fatal("other pid must not own the file")
	}
}
