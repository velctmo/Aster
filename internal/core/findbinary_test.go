package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFindBinaryRejectsConfiguredNonMachOFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "not-an-arm64-core")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := FindBinary(path); err == nil || !strings.Contains(err.Error(), "Apple Silicon") {
		t.Fatalf("non-ARM64 configured core was accepted: %v", err)
	}
}

func TestLatestManagedReturnsAbsolutePath(t *testing.T) {
	td := t.TempDir()
	relDir := filepath.Join(td, "cores")
	if err := os.MkdirAll(relDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Copy a real arm64 binary from vendor/cores or sing-box if available
	src := "../../vendor/cores/sing-box-1.14.0-darwin-arm64"
	data, err := os.ReadFile(src)
	if err != nil {
		t.Skip("vendor core not present for test")
	}
	dst := filepath.Join(relDir, "sing-box-test")
	if err := os.WriteFile(dst, data, 0o755); err != nil {
		t.Fatal(err)
	}
	found := latestManaged(relDir)
	if found == "" {
		t.Fatalf("expected to find binary in %s", relDir)
	}
	if !filepath.IsAbs(found) {
		t.Fatalf("expected absolute path, got: %s", found)
	}
}
