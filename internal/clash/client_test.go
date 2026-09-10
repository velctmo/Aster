package clash

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestDelayContextRejectsCanceledRequest(t *testing.T) {
	client := New("", 2090)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := client.DelayContext(ctx, "node", "https://example.test", 1000); err == nil {
		t.Fatal("cancelled delay request unexpectedly succeeded")
	}
}

type roundTripFunc func(req *http.Request) *http.Response

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req), nil
}

func TestClientDelayAndStatus(t *testing.T) {
	client := New("secret", 2090)
	client.http.Transport = roundTripFunc(func(req *http.Request) *http.Response {
		path := req.URL.Path
		switch {
		case strings.Contains(path, "/proxies/test-node/delay"):
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(bytes.NewBufferString(`{"delay":45}`)),
				Header:     make(http.Header),
			}
		case strings.Contains(path, "/proxies/timeout-node/delay"):
			return &http.Response{
				StatusCode: http.StatusGatewayTimeout,
				Body:       io.NopCloser(bytes.NewBufferString(`{"message":"timeout"}`)),
				Header:     make(http.Header),
			}
		case strings.HasPrefix(path, "/proxies/"):
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(bytes.NewBufferString(`{}`)),
				Header:     make(http.Header),
			}
		case path == "/connections":
			return &http.Response{
				StatusCode: http.StatusNoContent,
				Body:       io.NopCloser(bytes.NewBufferString(``)),
				Header:     make(http.Header),
			}
		case path == "/configs":
			return &http.Response{
				StatusCode: http.StatusNoContent,
				Body:       io.NopCloser(bytes.NewBufferString(``)),
				Header:     make(http.Header),
			}
		default:
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(bytes.NewBufferString(`{}`)),
				Header:     make(http.Header),
			}
		}
	})

	// 1. 成功延迟
	delay, err := client.Delay("test-node", "https://gstatic.com/generate_204", 1000)
	if err != nil {
		t.Fatalf("Delay 预期成功，实际报错: %v", err)
	}
	if delay != 45 {
		t.Fatalf("Delay 预期 45ms，实际: %d", delay)
	}

	// 2. 超时/非200状态码
	_, err = client.Delay("timeout-node", "https://gstatic.com/generate_204", 1000)
	if err == nil {
		t.Fatalf("Delay 预期失败，实际成功")
	}

	// 3. 各种写操作
	if err := client.Select("proxy", "test-node"); err != nil {
		t.Fatalf("Select 失败: %v", err)
	}
	if err := client.CloseAll(); err != nil {
		t.Fatalf("CloseAll 失败: %v", err)
	}
	if err := client.PatchMode("Rule"); err != nil {
		t.Fatalf("PatchMode 失败: %v", err)
	}
}
