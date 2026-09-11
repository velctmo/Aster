package app

import (
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"time"
)

// SpeedtestNode 针对指定节点进行单次真实下行吞吐测速 (10MB CDN 切片)
func (a *App) SpeedtestNode(tag string) (float64, error) {
	if err := a.requireNodeProfile(); err != nil {
		return 0, err
	}
	// A speed test temporarily changes the single selector. Serialize the full
	// select → request → restore transaction so concurrent UI actions cannot
	// restore a different test's original selection.
	a.speedtestMu.Lock()
	defer a.speedtestMu.Unlock()
	realTag := tag
	found := tag == "direct"
	if tag == "auto" {
		for _, n := range a.Nodes() {
			if n.Tag == "auto" {
				found = true
				break
			}
		}
	} else if tag != "direct" {
		for _, n := range a.Nodes() {
			if n.ID == tag {
				realTag = n.Tag
				found = true
				break
			}
			if n.Tag == tag {
				found = true
				break
			}
		}
	}
	if !found {
		return 0, fmt.Errorf("节点不存在: %s", tag)
	}

	// A speed test only touches the current selector and local proxy endpoint;
	// inactive profiles are irrelevant and can be large.
	f := a.st.Active()
	port := proxyPort(f)
	previous := f.Selected

	// 临时切换至待测节点 (如果是具体节点且不同于当前节点)
	if realTag != "auto" && realTag != "direct" {
		if err := a.clash.Select("proxy", realTag); err != nil {
			return 0, fmt.Errorf("切换测速节点失败: %w", err)
		}
		defer func() {
			if previous != "" {
				_ = a.clash.Select("proxy", previous)
			}
		}()
	}

	// 构造经由本地代理出站的 HTTP Client
	proxyURL, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
	if err != nil {
		return 0, err
	}
	transport := &http.Transport{
		Proxy:                 http.ProxyURL(proxyURL),
		ResponseHeaderTimeout: 6 * time.Second,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport: transport,
		Timeout:   12 * time.Second,
	}

	// 测速靶点：优先使用 Cloudflare 10MB 切片，失败容灾至 CacheFly 10MB
	testURLs := []string{
		"https://speed.cloudflare.com/__down?bytes=10485760",
		"https://cachefly.cachefly.net/10mb.test",
	}

	var resp *http.Response
	for _, target := range testURLs {
		req, rErr := http.NewRequest("GET", target, nil)
		if rErr != nil {
			continue
		}
		req.Header.Set("User-Agent", "Aster-Speedtest/1.0")
		r, doErr := client.Do(req)
		if doErr == nil && r.StatusCode == 200 {
			resp = r
			break
		}
		if r != nil {
			_ = r.Body.Close()
		}
	}

	if resp == nil {
		return 0, fmt.Errorf("测速源连接失败或不可达")
	}
	defer resp.Body.Close()

	start := time.Now()
	buf := make([]byte, 32*1024)
	var totalBytes int64

	for {
		n, rErr := resp.Body.Read(buf)
		if n > 0 {
			totalBytes += int64(n)
		}
		if rErr == io.EOF {
			break
		}
		if rErr != nil {
			return 0, fmt.Errorf("测速数据传输失败: %w", rErr)
		}
		// 保护：如果已测试超过 7 秒，提前完成结算，避免在极慢线路上长时间卡死
		if time.Since(start) >= 7*time.Second {
			break
		}
	}

	elapsed := time.Since(start)
	if totalBytes <= 0 || elapsed <= 0 {
		return 0, fmt.Errorf("无有效数据流传输")
	}

	// 计算吞吐量 Mbps: (bytes * 8) / (seconds * 1,000,000)
	seconds := elapsed.Seconds()
	mbps := (float64(totalBytes) * 8.0) / (seconds * 1000000.0)
	mbps = math.Round(mbps*10) / 10.0 // 保留一位小数

	a.mu.Lock()
	if a.bandwidths == nil {
		a.bandwidths = make(map[string]float64)
	}
	a.bandwidths[realTag] = mbps
	a.mu.Unlock()

	// 广播带宽数据通知 UI
	a.hub.Broadcast("node_speed", map[string]any{
		"tag":           realTag,
		"bandwidthMbps": mbps,
	})

	return mbps, nil
}
