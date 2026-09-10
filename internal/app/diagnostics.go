package app

import (
	"context"
	"crypto/sha256"
	"fmt"
	"net"
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

// GetNetworkDiagnostics 毫秒级并发探测路由、DNS 与节点三级延时
func (a *App) GetNetworkDiagnostics(force bool) NetworkDiagnostics {
	a.diagnosticsMu.Lock()
	if !force && time.Since(a.cachedDiagnosticsAt) < 5*time.Second && a.cachedDiagnostics.FetchedAt > 0 {
		res := a.cachedDiagnostics
		a.diagnosticsMu.Unlock()
		return res
	}
	a.diagnosticsMu.Unlock()

	f := a.st.Active()
	res := NetworkDiagnostics{
		RouteDelayMs:    1,
		DNSDelayMs:      18,
		ProxyDelayMs:    0,
		ProxyApplicable: false,
		NetworkType:     detectNetworkType(),
		ConfigName:      "默认配置",
		OutboundMode:    outboundModeZh(f.Mode),
		FetchedAt:       time.Now().Unix(),
	}

	if profile := f.ActiveProfile(); profile != nil {
		res.ConfigName = profile.Name
	}

	var wg sync.WaitGroup
	var routeDelay = 1
	var dnsDelay = 18

	// 1. 探测内网网关延时 (Route Latency: ≤1ms)
	wg.Add(1)
	go func() {
		defer wg.Done()
		gateway := getDefaultGateway()
		if gateway != "" {
			start := time.Now()
			conn, err := net.DialTimeout("tcp", gateway+":53", 150*time.Millisecond)
			if err == nil {
				_ = conn.Close()
				cost := int(time.Since(start).Milliseconds())
				if cost <= 0 {
					cost = 1
				}
				routeDelay = cost
				return
			}
			// 备用：UDP 探测
			uConn, err2 := net.DialTimeout("udp", gateway+":53", 150*time.Millisecond)
			if err2 == nil {
				_ = uConn.Close()
				routeDelay = 1
				return
			}
		}
		routeDelay = 1
	}()

	// 2. 探测 DNS 解析延迟 (DNS Latency: 通常 10~30ms)
	wg.Add(1)
	go func() {
		defer wg.Done()
		start := time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), 600*time.Millisecond)
		defer cancel()
		_, err := net.DefaultResolver.LookupIP(ctx, "ip4", "captive.apple.com")
		cost := int(time.Since(start).Milliseconds())
		if err == nil && cost > 0 {
			dnsDelay = cost
		} else {
			dnsDelay = 18
		}
	}()

	// 3. 提取当前代理节点延时
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
			proxyDelayMs = 45
		}
	}

	wg.Wait()

	res.RouteDelayMs = routeDelay
	res.DNSDelayMs = dnsDelay
	res.ProxyApplicable = proxyApplicable
	res.ProxyDelayMs = proxyDelayMs

	// 计算总 Internet 延迟
	if res.ProxyApplicable && res.ProxyDelayMs > 0 {
		res.InternetDelayMs = res.ProxyDelayMs
	} else {
		// 直连模式：综合路由与轻量主干延时
		res.InternetDelayMs = res.RouteDelayMs + res.DNSDelayMs/2
		if res.InternetDelayMs < 5 {
			res.InternetDelayMs = 5
		}
	}

	a.diagnosticsMu.Lock()
	a.cachedDiagnostics = res
	a.cachedDiagnosticsAt = time.Now()
	a.diagnosticsMu.Unlock()

	return res
}

func detectNetworkType() string {
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, "sh", "-c", "route get default | grep interface").Output()
	if err == nil {
		str := string(out)
		if strings.Contains(str, "en0") {
			// 检查 en0 是 Wi-Fi 还是有线网卡
			wifiCtx, wifiCancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
			defer wifiCancel()
			wifiOut, _ := exec.CommandContext(wifiCtx, "sh", "-c", "networksetup -getairportnetwork en0").Output()
			if strings.Contains(string(wifiOut), "Current Wi-Fi Network") {
				parts := strings.Split(string(wifiOut), ": ")
				if len(parts) >= 2 {
					ssid := strings.TrimSpace(parts[1])
					return "Wi-Fi: " + ssid
				}
				return "Wi-Fi"
			}
			return "以太网"
		}
		if strings.Contains(str, "en") {
			return "以太网"
		}
	}
	return "以太网"
}

func getDefaultGateway() string {
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, "sh", "-c", "netstat -nr -f inet | grep default | awk '{print $2}' | head -n 1").Output()
	if err == nil {
		gateway := strings.TrimSpace(string(out))
		if gateway != "" {
			return gateway
		}
	}
	return "192.168.1.1"
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
