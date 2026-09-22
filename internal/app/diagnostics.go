package app

import (
	"context"
	"crypto/sha256"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"

	"aster/internal/core"
	"aster/internal/render"
	"aster/internal/state"
)

// NetworkDiagnostics 专业「三级延时诊断」模型
type NetworkDiagnostics struct {
	InternetDelayMs int    `json:"internetDelayMs"` // 总 Internet 延迟 (如 5 ms)
	RouteDelayMs    int    `json:"routeDelayMs"`    // 路由/内网网关往返 (如 ≤1 ms)
	DNSDelayMs      int    `json:"dnsDelayMs"`      // DNS 解析延迟 (如 18 ms)
	ProxyDelayMs    int    `json:"proxyDelayMs"`    // 代理节点握手延迟
	ProxyApplicable bool   `json:"proxyApplicable"` // 是否走代理 (直连时为 false，界面显示 "不适用")
	NetworkType     string `json:"networkType"`     // 网络接入类型 (如 "以太网"、"Wi-Fi")
	ConfigName      string `json:"configName"`      // 当前生效配置名称 (如 "自用维护订阅")
	OutboundMode    string `json:"outboundMode"`    // 出站模式 (如 "智能规则"、"直接连接"、"全局代理")
	FetchedAt       int64  `json:"fetchedAt"`
}

// DiagnosticsReport is intentionally safe to share: it omits subscription
// URLs, complete sing-box JSON, API tokens, secrets, node credentials and IP
// addresses while retaining the metadata needed to diagnose lifecycle issues.
type DiagnosticsReport struct {
	GeneratedAt            int64                  `json:"generatedAt"`
	Status                 StatusJSON             `json:"status"`
	Runtime                state.RuntimeState     `json:"runtime"`
	Profiles               []DiagnosticProfile    `json:"profiles"`
	Network                NetworkDiagnostics     `json:"network"`
	ConfigurationIntegrity ConfigurationIntegrity `json:"configurationIntegrity"`
}

// ConfigurationIntegrity compares only content digests. It gives support a
// useful rendered-vs-applied signal without exporting a complete subscription,
// node credentials, or a potentially sensitive sing-box error message.
type ConfigurationIntegrity struct {
	RenderedSHA256      string `json:"renderedSHA256,omitempty"`
	AppliedSHA256       string `json:"appliedSHA256,omitempty"`
	AppliedConfigExists bool   `json:"appliedConfigExists"`
	MatchesApplied      bool   `json:"matchesApplied"`
	RenderStatus        string `json:"renderStatus"`
	CoreCheckStatus     string `json:"coreCheckStatus"`
}

// DiagnosticProfile contains only shareable profile metadata. In particular,
// it deliberately excludes source URLs, imported configuration, nodes and
// user-authored override source.
type DiagnosticProfile struct {
	ID              string               `json:"id"`
	Name            string               `json:"name"`
	Kind            string               `json:"kind"`
	Active          bool                 `json:"active"`
	SourceCount     int                  `json:"sourceCount"`
	NodeCount       int                  `json:"nodeCount"`
	UpdatedAt       int64                `json:"updatedAt"`
	LastError       string               `json:"lastError"`
	HasScript       bool                 `json:"hasScript"`
	RecentRefreshes []state.RefreshEvent `json:"recentRefreshes,omitempty"`
	Capabilities    CapabilitiesJSON     `json:"capabilities"`
	Sources         []SourceJSON         `json:"sources,omitempty"`
	InboundSummary  *InboundSummaryJSON  `json:"inboundSummary,omitempty"`
}

func (a *App) DiagnosticsReport() DiagnosticsReport {
	// Configuration integrity explicitly renders the current document, so it is
	// an on-demand diagnostic path rather than a high-frequency active snapshot.
	f := a.st.Get()
	status := a.Status()
	status.Error = redactDiagnosticText(status.Error)
	runtime := f.Runtime
	runtime.LastFailure = redactDiagnosticText(runtime.LastFailure)
	for i := range runtime.History {
		runtime.History[i].Reason = redactDiagnosticText(runtime.History[i].Reason)
	}
	return DiagnosticsReport{
		GeneratedAt:            time.Now().Unix(),
		Status:                 status,
		Runtime:                runtime,
		Profiles:               diagnosticProfiles(a.Profiles()),
		Network:                a.GetNetworkDiagnostics(false),
		ConfigurationIntegrity: a.configurationIntegrity(f),
	}
}

func (a *App) configurationIntegrity(f state.File) ConfigurationIntegrity {
	result := ConfigurationIntegrity{RenderStatus: "failed", CoreCheckStatus: "not_run"}
	rendered, err := render.Config(f, a.st.Dir())
	if err != nil {
		return result
	}
	result.RenderStatus = "passed"
	result.RenderedSHA256 = sha256Hex(rendered)
	applied, err := os.ReadFile(a.st.ConfigPath())
	if err != nil {
		if os.IsNotExist(err) {
			result.CoreCheckStatus = "not_applicable"
		}
		return result
	}
	result.AppliedConfigExists = true
	result.AppliedSHA256 = sha256Hex(applied)
	result.MatchesApplied = result.RenderedSHA256 == result.AppliedSHA256
	bin, err := core.FindBinary(f.Settings.CorePath)
	if err != nil {
		result.CoreCheckStatus = "not_available"
		return result
	}
	if err := core.ValidateConfig(bin, a.st.ConfigPath()); err != nil {
		result.CoreCheckStatus = "failed"
		return result
	}
	result.CoreCheckStatus = "passed"
	return result
}

func sha256Hex(content []byte) string {
	sum := sha256.Sum256(content)
	return fmt.Sprintf("%x", sum)
}

func diagnosticProfiles(profiles []ProfileJSON) []DiagnosticProfile {
	out := make([]DiagnosticProfile, 0, len(profiles))
	for _, p := range profiles {
		sources := append([]SourceJSON(nil), p.Sources...)
		for i := range sources {
			sources[i].LastError = redactDiagnosticText(sources[i].LastError)
		}
		refreshes := recentRefreshes(p.RecentRefreshes)
		out = append(out, DiagnosticProfile{
			ID: p.ID, Name: p.Name, Kind: p.Kind, Active: p.Active,
			SourceCount: p.SourceCount, NodeCount: p.NodeCount, UpdatedAt: p.UpdatedAt,
			LastError: redactDiagnosticText(p.LastError), HasScript: p.HasScript, RecentRefreshes: refreshes, Capabilities: p.Capabilities, Sources: sources, InboundSummary: p.InboundSummary,
		})
	}
	return out
}

var diagnosticURL = regexp.MustCompile(`https?://[^\s"']+`)

func redactDiagnosticText(text string) string {
	return diagnosticURL.ReplaceAllString(text, "[URL]")
}

// GetNetworkDiagnostics 毫秒级并发探测路由、DNS 与节点三级真实延时（绝无任何造假与硬编码数据）
func (a *App) GetNetworkDiagnostics(force bool) NetworkDiagnostics {
	a.diagnosticsMu.Lock()
	if !force && time.Since(a.cachedDiagnosticsAt) < 5*time.Second && a.cachedDiagnostics.FetchedAt > 0 {
		res := a.cachedDiagnostics
		a.diagnosticsMu.Unlock()
		return res
	}
	if a.diagnosticsCond == nil {
		a.diagnosticsCond = sync.NewCond(&a.diagnosticsMu)
	}
	for a.diagnosticsRunning {
		a.diagnosticsCond.Wait()
		if !force && time.Since(a.cachedDiagnosticsAt) < 5*time.Second && a.cachedDiagnostics.FetchedAt > 0 {
			res := a.cachedDiagnostics
			a.diagnosticsMu.Unlock()
			return res
		}
	}
	a.diagnosticsRunning = true
	a.diagnosticsMu.Unlock()

	defer func() {
		a.diagnosticsMu.Lock()
		a.diagnosticsRunning = false
		if a.diagnosticsCond != nil {
			a.diagnosticsCond.Broadcast()
		}
		a.diagnosticsMu.Unlock()
	}()

	f := a.st.Active()
	routeInfo := getDefaultRouteInfo()
	activeConfigName := "未激活配置"
	if profile := f.ActiveProfile(); profile != nil && profile.Name != "" {
		activeConfigName = profile.Name
	}
	res := NetworkDiagnostics{
		RouteDelayMs:    0,
		DNSDelayMs:      0,
		ProxyDelayMs:    0,
		ProxyApplicable: false,
		NetworkType:     detectNetworkType(routeInfo.iface),
		ConfigName:      activeConfigName,
		OutboundMode:    outboundModeZh(f.Mode),
		FetchedAt:       time.Now().Unix(),
	}

	var wg sync.WaitGroup
	var routeDelay int
	var dnsDelay int

	// 1. 真实探测内网网关延时 (Route Latency)
	wg.Add(1)
	go func() {
		defer wg.Done()
		gateway := routeInfo.gateway
		if gateway != "" {
			start := time.Now()
			// 优先尝试网关常见服务端口 53 (DNS)
			conn, err := net.DialTimeout("tcp", net.JoinHostPort(gateway, "53"), 250*time.Millisecond)
			if err == nil {
				_ = conn.Close()
				cost := int(time.Since(start).Milliseconds())
				if cost <= 0 {
					cost = 1
				}
				routeDelay = cost
				return
			}
			// 备选端口 80 (路由器管理界面)
			conn2, err2 := net.DialTimeout("tcp", net.JoinHostPort(gateway, "80"), 250*time.Millisecond)
			if err2 == nil {
				_ = conn2.Close()
				cost := int(time.Since(start).Milliseconds())
				if cost <= 0 {
					cost = 1
				}
				routeDelay = cost
				return
			}
			// 备用 UDP 探测
			uConn, err3 := net.DialTimeout("udp", net.JoinHostPort(gateway, "53"), 250*time.Millisecond)
			if err3 == nil {
				_ = uConn.Close()
				cost := int(time.Since(start).Milliseconds())
				if cost <= 0 {
					cost = 1
				}
				routeDelay = cost
				return
			}
		}
		routeDelay = 0
	}()

	// 2. 真实探测 DNS 解析延迟 (DNS Latency)
	wg.Add(1)
	go func() {
		defer wg.Done()
		start := time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), 800*time.Millisecond)
		defer cancel()
		_, err := net.DefaultResolver.LookupIP(ctx, "ip4", "captive.apple.com")
		cost := int(time.Since(start).Milliseconds())
		if err == nil && cost > 0 {
			dnsDelay = cost
		} else {
			dnsDelay = 0
		}
	}()

	// 3. 提取或探测代理节点真实延时
	a.mu.Lock()
	curDelay := a.delay
	a.mu.Unlock()

	var proxyApplicable bool
	var proxyDelayMs int
	if f.Mode == "direct" || !a.core.Running() || !f.Wanted {
		proxyApplicable = false
		proxyDelayMs = 0
	} else {
		proxyApplicable = true
		if curDelay > 0 {
			proxyDelayMs = curDelay
		} else {
			activeTag := f.Selected
			if activeTag == "" {
				activeTag = "proxy"
			}
			a.mu.Lock()
			tagDelay := a.delays[activeTag]
			a.mu.Unlock()

			if tagDelay > 0 {
				proxyDelayMs = tagDelay
			} else if force && a.core.Running() {
				delayURL := strings.TrimSpace(f.Settings.DelayURL)
				if delayURL == "" {
					delayURL = state.DefaultDelayURL
				}
				timeoutMs := f.Settings.DelayTimeoutMs
				if timeoutMs <= 0 {
					timeoutMs = 3000
				}
				if d, err := a.clash.Delay(activeTag, delayURL, timeoutMs); err == nil && d > 0 {
					proxyDelayMs = d
					a.mu.Lock()
					a.delay = d
					if a.delays == nil {
						a.delays = make(map[string]int)
					}
					a.delays[activeTag] = d
					a.mu.Unlock()
				} else {
					proxyDelayMs = 0
				}
			} else {
				proxyDelayMs = 0
			}
		}
	}

	wg.Wait()

	res.RouteDelayMs = routeDelay
	res.DNSDelayMs = dnsDelay
	res.ProxyApplicable = proxyApplicable
	res.ProxyDelayMs = proxyDelayMs

	// 真实 Internet 延迟：
	// 若走代理且代理延迟有效，以代理节点真实 RTT 为准；
	// 若为直连模式，测量实际直连 204 往返；
	// 未测出时严格为 0（未测速），绝不捏造假数据！
	if res.ProxyApplicable {
		if res.ProxyDelayMs > 0 {
			res.InternetDelayMs = res.ProxyDelayMs
		} else {
			res.InternetDelayMs = 0
		}
	} else if f.Mode == "direct" {
		directURL := strings.TrimSpace(f.Settings.DelayURL)
		if directURL == "" {
			directURL = state.DefaultDelayURL
		}
		res.InternetDelayMs = probeDirectDelay(directURL, 600*time.Millisecond)
	} else {
		res.InternetDelayMs = 0
	}

	a.diagnosticsMu.Lock()
	a.cachedDiagnostics = res
	a.cachedDiagnosticsAt = time.Now()
	a.diagnosticsMu.Unlock()

	return res
}

func probeDirectDelay(targetURL string, timeout time.Duration) int {
	if targetURL == "" {
		targetURL = state.DefaultDelayURL
	}
	client := &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			DisableKeepAlives: true,
		},
	}
	start := time.Now()
	resp, err := client.Get(targetURL)
	if err != nil {
		return 0
	}
	_ = resp.Body.Close()
	cost := int(time.Since(start).Milliseconds())
	if cost <= 0 {
		return 1
	}
	return cost
}

type defaultRouteInfo struct {
	gateway string
	iface   string
}

func getDefaultRouteInfo() defaultRouteInfo {
	ctx, cancel := context.WithTimeout(context.Background(), 350*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, "route", "-n", "get", "default").Output()
	if err != nil {
		return defaultRouteInfo{}
	}
	var info defaultRouteInfo
	for _, line := range strings.Split(string(out), "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "gateway:") {
			parts := strings.Fields(trimmed)
			if len(parts) >= 2 {
				gw := parts[1]
				if !strings.Contains(gw, "link") {
					info.gateway = gw
				}
			}
		} else if strings.HasPrefix(trimmed, "interface:") {
			parts := strings.Fields(trimmed)
			if len(parts) >= 2 {
				info.iface = parts[1]
			}
		}
	}
	return info
}

func detectNetworkType(iface string) string {
	if iface == "" {
		return "未连接网络"
	}
	if strings.HasPrefix(iface, "pdp_ip") {
		return "蜂窝网络"
	}
	if strings.HasPrefix(iface, "en") {
		wifiCtx, wifiCancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
		defer wifiCancel()
		wifiOut, err := exec.CommandContext(wifiCtx, "networksetup", "-getairportnetwork", iface).Output()
		if err == nil && strings.Contains(string(wifiOut), "Current Wi-Fi Network") {
			parts := strings.Split(string(wifiOut), ": ")
			if len(parts) >= 2 {
				ssid := strings.TrimSpace(parts[1])
				if ssid != "" {
					return "Wi-Fi: " + ssid
				}
			}
			return "Wi-Fi"
		}
		return "以太网"
	}
	return iface
}

func outboundModeZh(mode string) string {
	switch mode {
	case "direct":
		return "直接连接"
	case "global":
		return "全局代理"
	default:
		return "智能规则"
	}
}
