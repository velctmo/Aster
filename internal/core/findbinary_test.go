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
