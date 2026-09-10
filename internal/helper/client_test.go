package helper

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
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
