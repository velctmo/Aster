package clash

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"aster/internal/state"
)

type Client struct {
	secret string
	base   string
	http   *http.Client
	mu     sync.Mutex
	last   *Connections
}

type Connections struct {
	DownloadTotal int64        `json:"downloadTotal"`
	UploadTotal   int64        `json:"uploadTotal"`
	Connections   []Connection `json:"connections"`
}

type Connection struct {
	ID          string   `json:"id"`
	Upload      int64    `json:"upload"`
	Download    int64    `json:"download"`
	Start       string   `json:"start"`
	Chains      []string `json:"chains"`
	Rule        string   `json:"rule"`
	RulePayload string   `json:"rulePayload"`
	Metadata    Metadata `json:"metadata"`
}

type Metadata struct {
	Network         string `json:"network"`
	Type            string `json:"type"`
	SourceIP        string `json:"sourceIP"`
	Destination     string `json:"destinationIP"`
	Host            string `json:"host"`
	Process         string `json:"process"`
	ProcessPath     string `json:"processPath"`
	DestinationPort string `json:"destinationPort"`
}

func New(secret string, port int) *Client {
	if port <= 0 {
		port = state.DefaultClashPort
	}
	return &Client{
		secret: secret,
		base:   fmt.Sprintf("http://127.0.0.1:%d", port),
		http:   &http.Client{Timeout: 8 * time.Second},
	}
}

func (c *Client) SetSecret(s string) {
	c.mu.Lock()
	c.secret = s
	c.mu.Unlock()
}

func (c *Client) SetPort(port int) {
	if port <= 0 {
		port = state.DefaultClashPort
	}
	c.mu.Lock()
	c.base = fmt.Sprintf("http://127.0.0.1:%d", port)
	c.mu.Unlock()
}

func (c *Client) do(method, path string, body io.Reader) (*http.Response, error) {
	return c.doContext(context.Background(), method, path, body)
}

func (c *Client) doContext(ctx context.Context, method, path string, body io.Reader) (*http.Response, error) {
	c.mu.Lock()
	base := c.base
	secret := c.secret
	c.mu.Unlock()
	req, err := http.NewRequestWithContext(ctx, method, base+path, body)
	if err != nil {
		return nil, err
	}
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return c.http.Do(req)
}

func (c *Client) Healthy() bool {
	resp, err := c.do(http.MethodGet, "/version", nil)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == 200
}

func (c *Client) Snapshot() (*Connections, error) {
	resp, err := c.do(http.MethodGet, "/connections", nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("connections %d %s", resp.StatusCode, b)
	}
	var snap Connections
	if err := json.NewDecoder(resp.Body).Decode(&snap); err != nil {
		return nil, err
	}
	c.mu.Lock()
	c.last = &snap
	c.mu.Unlock()
	return &snap, nil
}

func (c *Client) Last() *Connections {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.last
}

func drainAndClose(resp *http.Response) {
	if resp != nil && resp.Body != nil {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 2048))
		_ = resp.Body.Close()
	}
}

func (c *Client) CloseAll() error {
	resp, err := c.do(http.MethodDelete, "/connections", nil)
	if err != nil {
		return err
	}
	defer drainAndClose(resp)
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("close all connections: %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

func (c *Client) CloseOne(id string) error {
	resp, err := c.do(http.MethodDelete, "/connections/"+url.PathEscape(id), nil)
	if err != nil {
		return err
	}
	defer drainAndClose(resp)
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("close connection %s: %d %s", id, resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

func (c *Client) Select(group, name string) error {
	body := fmt.Sprintf(`{"name":%q}`, name)
	resp, err := c.do(http.MethodPut, "/proxies/"+url.PathEscape(group), strings.NewReader(body))
	if err != nil {
		return err
	}
	defer drainAndClose(resp)
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("select: %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

func (c *Client) Delay(name, testURL string, timeout int) (int, error) {
	return c.DelayContext(context.Background(), name, testURL, timeout)
}

func (c *Client) DelayContext(ctx context.Context, name, testURL string, timeout int) (int, error) {
	path := fmt.Sprintf("/proxies/%s/delay?url=%s&timeout=%d", url.PathEscape(name), url.QueryEscape(testURL), timeout)
	resp, err := c.doContext(ctx, http.MethodGet, path, nil)
	if err != nil {
		return 0, err
	}
	defer drainAndClose(resp)
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		msg := strings.TrimSpace(string(b))
		if msg == "" {
			msg = fmt.Sprintf("HTTP %d", resp.StatusCode)
		}
		return 0, fmt.Errorf("延迟探测失败: %s", msg)
	}
	var out struct {
		Delay int `json:"delay"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return 0, err
	}
	if out.Delay <= 0 {
		return 0, fmt.Errorf("超时")
	}
	return out.Delay, nil
}

func (c *Client) PatchMode(mode string) error {
	body := fmt.Sprintf(`{"mode":%q}`, mode)
	resp, err := c.do(http.MethodPatch, "/configs", strings.NewReader(body))
	if err != nil {
		return err
	}
	defer drainAndClose(resp)
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("patch mode %s: %d %s", mode, resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

type Traffic struct {
	Up   int64 `json:"up"`
	Down int64 `json:"down"`
}

type ProxyInfo struct {
	Name    string   `json:"name"`
	Type    string   `json:"type"`
	Now     string   `json:"now,omitempty"`
	All     []string `json:"all,omitempty"`
	History []struct {
		Time  string `json:"time"`
		Delay int    `json:"delay"`
	} `json:"history,omitempty"`
}

func (c *Client) Proxies() (map[string]ProxyInfo, error) {
	resp, err := c.do(http.MethodGet, "/proxies", nil)
	if err != nil {
		return nil, err
	}
	defer drainAndClose(resp)
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("proxies %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	var out struct {
		Proxies map[string]ProxyInfo `json:"proxies"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out.Proxies, nil
}

type RuleInfo struct {
	Type    string `json:"type"`
	Payload string `json:"payload"`
	Proxy   string `json:"proxy"`
}

func (c *Client) Rules() ([]RuleInfo, error) {
	resp, err := c.do(http.MethodGet, "/rules", nil)
	if err != nil {
		return nil, err
	}
	defer drainAndClose(resp)
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("rules %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	var out struct {
		Rules []RuleInfo `json:"rules"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out.Rules, nil
}
