package core

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
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

func TestVerifySHA256(t *testing.T) {
	data := []byte("trusted core")
	digest := sha256.Sum256(data)
	expected := hex.EncodeToString(digest[:])
	if err := verifySHA256(data, expected); err != nil {
		t.Fatal(err)
	}
	if err := verifySHA256(data, strings.Repeat("0", 64)); err == nil {
		t.Fatal("checksum mismatch was accepted")
	}
	if _, err := normalizeSHA256("not-a-checksum"); err == nil {
		t.Fatal("malformed checksum was accepted")
	}
}

func TestMatchDarwinAsset(t *testing.T) {
	if !MatchDarwinAsset("sing-box-1.11.0-darwin-arm64.tar.gz", "arm64") {
		t.Fatal("arm64 asset should match")
	}
	if MatchDarwinAsset("sing-box-1.11.0-darwin-amd64.tar.gz", "arm64") {
		t.Fatal("amd64 asset should not match arm64")
	}
	if MatchDarwinAsset("sing-box-1.11.0-darwin-amd64.tar.gz", "amd64") {
		t.Fatal("amd64 asset should be rejected under ARM64-only policy")
	}
	if MatchDarwinAsset("clash-darwin-arm64.tar.gz", "arm64") {
		t.Fatal("non sing-box name should not match")
	}
}

func TestMirrorURL(t *testing.T) {
	raw := "https://github.com/SagerNet/sing-box/releases/download/v1.0.0/a.tar.gz"
	if MirrorURL(raw, "") != raw {
		t.Fatal("empty prefix should keep URL")
	}
	got := MirrorURL(raw, "https://ghproxy.net/")
	want := "https://ghproxy.net/" + raw
	if got != want {
		t.Fatalf("got %s want %s", got, want)
	}
}

func TestExtractSingBox(t *testing.T) {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	body := []byte("fake-binary")
	hdr := &tar.Header{
		Name:     "sing-box-1.0.0-darwin-arm64/sing-box",
		Mode:     0755,
		Size:     int64(len(body)),
		Typeflag: tar.TypeReg,
	}
	if err := tw.WriteHeader(hdr); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write(body); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}

	f, err := os.CreateTemp("", "aster-test-*.tar.gz")
	if err != nil {
		t.Fatal(err)
	}
	path := f.Name()
	t.Cleanup(func() { _ = os.Remove(path) })
	if _, err := f.Write(buf.Bytes()); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()

	got, err := extractSingBox(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, body) {
		t.Fatalf("extracted mismatch")
	}
}

func TestVerifyBinaryRejectsGarbage(t *testing.T) {
	f, err := os.CreateTemp("", "aster-not-singbox-*")
	if err != nil {
		t.Fatal(err)
	}
	path := f.Name()
	t.Cleanup(func() { _ = os.Remove(path) })
	_, _ = f.Write([]byte("not a binary"))
	_ = f.Close()
	_ = os.Chmod(path, 0755)
	if err := verifyBinary(path); err == nil {
		t.Fatal("expected verify to reject garbage")
	}
}
