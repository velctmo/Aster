package helper

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestClientSendsOnlyBoundedStructuredRequest(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "ht-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "h.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var request Request
		if err := json.NewDecoder(conn).Decode(&request); err != nil {
			return
		}
		if request.Action != "start" || string(request.Config) != `{"inbounds":[]}` {
			return
		}
		_ = json.NewEncoder(conn).Encode(Response{OK: true, PID: 42, Generation: 3})
	}()
	response, err := (Client{Socket: socket}).Start([]byte(`{"inbounds":[]}`))
	if err != nil {
		t.Fatal(err)
	}
	if response.PID != 42 || response.Generation != 3 {
		t.Fatalf("unexpected response: %+v", response)
	}
	<-done
}

func TestClientRejectsOversizedConfigBeforeDialing(t *testing.T) {
	_, err := (Client{Socket: filepath.Join(t.TempDir(), "missing.sock")}).Start(make([]byte, MaxConfigSize+1))
	if err == nil {
		t.Fatal("expected oversized request rejection")
	}
}

func TestInstalledRequiresResponsiveHelperInsteadOfSocketFile(t *testing.T) {
	dir := t.TempDir()
	socket := filepath.Join(dir, "stale.sock")
	if err := os.WriteFile(socket, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	if (Client{Socket: socket}).Installed() {
		t.Fatal("a stale socket file must not be reported as an installed helper")
	}
}

func TestHealthDoesNotRequireConfigPayload(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "aster-health-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "health.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var request Request
		if json.NewDecoder(conn).Decode(&request) == nil && request.Action == "health" && len(request.Config) == 0 {
			_ = json.NewEncoder(conn).Encode(Response{OK: true})
		}
	}()
	if !(Client{Socket: socket}).Installed() {
		t.Fatal("responsive helper must be reported as installed")
	}
}

func TestHealthTimesOutAgainstUnresponsiveSocket(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "aster-health-stall-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "stall.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			accepted <- conn
		}
	}()
	started := time.Now()
	if _, err := (Client{Socket: socket}).Health(); err == nil {
		t.Fatal("unresponsive helper must fail health check")
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("health check stalled for %s", elapsed)
	}
	select {
	case conn := <-accepted:
		_ = conn.Close()
	default:
	}
}
