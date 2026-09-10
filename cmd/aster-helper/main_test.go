package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestVerifyManagedCoreRejectsWritableCore(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sing-box")
	if err := os.WriteFile(path, []byte("not a binary"), 0o722); err != nil {
		t.Fatal(err)
	}
	if err := verifyManagedCore(path); err == nil {
		t.Fatal("writable core was accepted")
	}
}
