package sub

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestFetchContextRejectsOversizedResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = fmt.Fprint(w, strings.Repeat("x", maxSubscriptionBytes+1))
	}))
	defer server.Close()
	if _, err := FetchContext(context.Background(), server.URL); err == nil || !strings.Contains(err.Error(), "超过 8 MB") {
		t.Fatalf("oversized subscription was accepted: %v", err)
	}
}

func TestFetchContextCancelsInFlightRequest(t *testing.T) {
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
	}))
	defer server.Close()

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := FetchContext(ctx, server.URL)
		done <- err
	}()
	select {
	case <-started:
		cancel()
	case <-time.After(time.Second):
		t.Fatal("request did not start")
	}
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled fetch unexpectedly succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled fetch did not return promptly")
	}
}
