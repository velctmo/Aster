package render

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"aster/internal/script"
	"aster/internal/state"
)

type MergedNode struct {
	Tag      string
	SubID    string
	SubName  string
	Name     string
	Protocol string
	Disabled bool
	Outbound json.RawMessage
	NodeID   string
}

func Merge(f state.File) []MergedNode {
	p := f.ActiveProfile()
	if p == nil || p.Kind != state.ProfileKindNodes {
		return nil
	}
	out := make([]MergedNode, 0, len(p.ManualNodes))
	used := map[string]int{}
	appendMergedNodes := func(nodes []state.Node, sourceID, sourceName string, local bool) {
		for _, n := range nodes {
			tag := n.Name
			if !local {
				tag = sourceName + " · " + n.Name
			}
			if c := used[tag]; c > 0 {
				tag = fmt.Sprintf("%s (%d)", tag, c+1)
			}
			used[tag]++
			out = append(out, MergedNode{Tag: tag, SubID: sourceID, SubName: sourceName, Name: n.Name,
				Protocol: n.Protocol, Disabled: n.Disabled, Outbound: setTag(n.Outbound, tag), NodeID: n.ID})
		}
	}
	appendMergedNodes(p.ManualNodes, state.LocalSubID, "本地", true)
	for _, source := range p.Sources {
		appendMergedNodes(source.Nodes, source.ID, sourceLabel(source.URL), false)
	}
	return out
}

// sourceLabel deliberately never uses a raw subscription URL in a node tag or
// API response: subscription query strings frequently carry credentials.
func sourceLabel(raw string) string {
	u, err := url.Parse(raw)
	if err == nil && u.Hostname() != "" {
		return u.Hostname()
	}
	// Legacy migrated sources sometimes used a plain display name instead of a
	// URL. Keep that label, but never echo a malformed HTTP(S) value.
	trimmed := strings.TrimSpace(raw)
	if trimmed != "" && !strings.Contains(trimmed, "://") && !strings.ContainsAny(trimmed, "?@") {
		return trimmed
	}
	return "订阅来源"
}

func EnabledTags(nodes []MergedNode) []string {
	var tags []string
	for _, n := range nodes {
		if !n.Disabled {
			tags = append(tags, n.Tag)
		}
	}
	return tags
}

func ProfileScript(f state.File, p *state.ConfigProfile) string {
	if p == nil {
		return ""
	}
	if p.ScriptID != "" {
		for _, s := range f.Scripts {
			if s.ID == p.ScriptID {
				return s.Content
			}
		}
	}
	return p.Script
}

func Config(f state.File, dir string) ([]byte, error) {
	if p := f.ActiveProfile(); p != nil && p.Kind == state.ProfileKindSubscription {
		return fullConfig(f, *p)
	}
	var err error
	f, err = Effective(f)
	if err != nil {
		return nil, err
	}
	nodes := Merge(f)
	tags := EnabledTags(nodes)
	listen := "127.0.0.1"
	if f.Settings.AllowLan {
		listen = "0.0.0.0"
	}
	port := f.Settings.MixedPort
	if port == 0 {
		port = state.DefaultMixedPort
	}
	inbounds := []any{
		map[string]any{
			"type":             "mixed",
			"tag":              "mixed-in",
			"listen":           listen,
			"listen_port":      port,
			"set_system_proxy": false,
		},
	}
	if f.Wanted && f.Capture.Tun {
		inbounds = append(inbounds, map[string]any{
			"type":         "tun",
			"tag":          "tun-in",
			"address":      []string{"172.19.0.1/30"},
			"mtu":          1500,
			"auto_route":   true,
			"strict_route": f.Settings.StrictRoute,
			"stack":        "mixed",
		})
	}

	var outbounds []any
	outbounds = append(outbounds, map[string]any{"type": "direct", "tag": "direct"})
	proxyList := proxyMembers(tags)
	outbounds = append(outbounds, map[string]any{
		"type":                        "selector",
		"tag":                         "proxy",
		"outbounds":                   proxyList,
		"default":                     defaultSelect(f.Selected, proxyList),
		"interrupt_exist_connections": false,
	})
	nodeServersMap := make(map[string]struct{})
	for _, n := range nodes {
		if n.Disabled {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal(n.Outbound, &m); err != nil {
			continue
		}
		if srv, ok := m["server"].(string); ok && srv != "" {
			srv = strings.TrimSpace(srv)
			if strings.ContainsAny(srv, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") {
				nodeServersMap[srv] = struct{}{}
			}
		}
		m["tag"] = n.Tag
		outbounds = append(outbounds, m)
	}
	var nodeServers []string
	for srv := range nodeServersMap {
		nodeServers = append(nodeServers, srv)
	}

	rules := []any{
		map[string]any{"action": "sniff"},
		map[string]any{"inbound": []string{"mixed-in", "tun-in"}, "protocol": "dns", "action": "hijack-dns"},
		map[string]any{"clash_mode": "Direct", "action": "route", "outbound": "direct"},
		map[string]any{"clash_mode": "Global", "action": "route", "outbound": "proxy"},
		map[string]any{"ip_is_private": true, "action": "route", "outbound": "direct"},
	}
	for _, r := range f.Rules {
		rules = append(rules, compileRule(r))
	}
	if f.Settings.DirectCN {
		geositePath := filepath.Join(dir, "rules", "geosite-cn.srs")
		if _, err := os.Stat(geositePath); err == nil {
			rules = append(rules, map[string]any{
				"rule_set": []string{"geosite-cn", "geoip-cn"},
				"action":   "route",
				"outbound": "direct",
			})
		} else {
			rules = append(rules, map[string]any{
				"domain_suffix": []string{".cn", ".cn.", "aliyun.com", "qq.com", "baidu.com", "jd.com", "taobao.com", "bilibili.com", "163.com", "douyin.com", "zhihu.com"},
				"action":        "route",
				"outbound":      "direct",
			})
		}
	}
	clashPort := f.Settings.ClashPort
	if clashPort <= 0 {
		clashPort = state.DefaultClashPort
	}
	cfg := map[string]any{
		"log": map[string]any{"level": f.Settings.LogLevel, "timestamp": true},
		"dns": dnsBlock(f, nodeServers, dir),
		// Remote rule-sets must always be downloaded directly: using the
		// selected proxy here can form a startup dependency loop.  An HTTP
		// client without a detour is direct; this is the sing-box 1.14
		// replacement for the deprecated download_detour field.
		"http_clients": []any{map[string]any{
			"tag": "rule-set-direct",
		}},
		"inbounds":  inbounds,
		"outbounds": outbounds,
		"route": map[string]any{
			"auto_detect_interface":   true,
			"find_process":            true,
			"default_domain_resolver": "bootstrap",
			"default_http_client":     "rule-set-direct",
			"rule_set": func() []any {
				var rs []any
				geositePath := filepath.Join(dir, "rules", "geosite-cn.srs")
				if _, err := os.Stat(geositePath); err == nil {
					rs = append(rs, map[string]any{
						"tag":    "geosite-cn",
						"type":   "local",
						"format": "binary",
						"path":   geositePath,
					})
				}
				geoipPath := filepath.Join(dir, "rules", "geoip-cn.srs")
				if _, err := os.Stat(geoipPath); err == nil {
					rs = append(rs, map[string]any{
						"tag":    "geoip-cn",
						"type":   "local",
						"format": "binary",
						"path":   geoipPath,
					})
				}
				return rs
			}(),
			"rules": rules,
			"final": "proxy",
		},
		"experimental": map[string]any{
			"clash_api": map[string]any{
				"external_controller": fmt.Sprintf("127.0.0.1:%d", clashPort),
				"secret":              f.ClashSecret,
				"default_mode":        clashMode(f.Mode),
			},
			"cache_file": map[string]any{
				"enabled":      true,
				"path":         filepath.Join(dir, "cache.db"),
				"store_fakeip": true,
			},
		},
	}
	applySelectorDefaults(cfg, f.Selected, f.SelectorNow)
	baseJSON, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return nil, err
	}
	p := f.ActiveProfile()
	scriptSource := ProfileScript(f, p)
	if p != nil && scriptSource != "" {
		if strings.Contains(scriptSource, "transformConfig") || strings.Contains(scriptSource, "main") {
			transformed, err := script.TransformConfig(scriptSource, baseJSON, *p)
			if err != nil {
				return nil, err
			}
			// Fail-Safe 后置兜底保护：
			// 避免用户脚本重构 outbounds/experimental 时意外丢失 clash_api 或 inbounds，
			// 导致 sing-box 未监听 Clash API 端口而健康检查超时被强杀。
			var finalMap map[string]any
			if err := json.Unmarshal(transformed, &finalMap); err == nil {
				// 1. 确保 experimental.clash_api 存在且监听 127.0.0.1:clashPort
				exp, _ := finalMap["experimental"].(map[string]any)
				if exp == nil {
					exp = map[string]any{}
					finalMap["experimental"] = exp
				}
				clashAPI, _ := exp["clash_api"].(map[string]any)
				if clashAPI == nil {
					clashAPI = map[string]any{}
					exp["clash_api"] = clashAPI
				}
				if ext, _ := clashAPI["external_controller"].(string); ext == "" {
					clashAPI["external_controller"] = fmt.Sprintf("127.0.0.1:%d", clashPort)
				}
				if sec, _ := clashAPI["secret"].(string); sec == "" {
					clashAPI["secret"] = f.ClashSecret
				}
				if mode, _ := clashAPI["default_mode"].(string); mode == "" {
					clashAPI["default_mode"] = clashMode(f.Mode)
				}

				// 2. 确保必须包含 mixed-in 本地代理入站
				inboundsList, _ := finalMap["inbounds"].([]any)
				hasMixed := false
				for _, in := range inboundsList {
					if inm, ok := in.(map[string]any); ok {
						if typ, _ := inm["type"].(string); typ == "mixed" {
							hasMixed = true
							break
						}
					}
				}
				if !hasMixed {
					finalMap["inbounds"] = append(inbounds, inboundsList...)
				}

				// 3. 确保包含 proxy selector 策略组
				outboundsList, _ := finalMap["outbounds"].([]any)
				hasProxySelector := false
				var firstSelector string
				for _, out := range outboundsList {
					if om, ok := out.(map[string]any); ok {
						tag, _ := om["tag"].(string)
						typ, _ := om["type"].(string)
						if tag == "proxy" {
							hasProxySelector = true
							break
						}
						if typ == "selector" && firstSelector == "" {
							firstSelector = tag
						}
					}
				}
				if !hasProxySelector {
					targetGroup := firstSelector
					if targetGroup == "" {
						targetGroup = "direct"
					}
					// 注入 proxy 别名 selector（放置在末尾），兼容 app.go 健康检查和默认选择，不喧宾夺主
					proxySelector := map[string]any{
						"type":                        "selector",
						"tag":                         "proxy",
						"outbounds":                   []string{targetGroup},
						"interrupt_exist_connections": false,
					}
					finalMap["outbounds"] = append(outboundsList, proxySelector)
				}

				applySelectorDefaults(finalMap, f.Selected, f.SelectorNow)

				// 4. 确保 route 中基础 DNS 劫持与必要 rule_set 完备
				routeMap, _ := finalMap["route"].(map[string]any)
				if routeMap != nil {
					// 若脚本配置了引用 geosite-cn / geoip-cn 的规则，自动补全本地 rule_set 声明
					rsList, _ := routeMap["rule_set"].([]any)
					hasGeosite := false
					hasGeoip := false
					for _, item := range rsList {
						if rm, ok := item.(map[string]any); ok {
							if tag, _ := rm["tag"].(string); tag == "geosite-cn" {
								hasGeosite = true
							}
							if tag, _ := rm["tag"].(string); tag == "geoip-cn" {
								hasGeoip = true
							}
						}
					}
					geositePath := filepath.Join(dir, "rules", "geosite-cn.srs")
					if !hasGeosite {
						if _, err := os.Stat(geositePath); err == nil {
							rsList = append(rsList, map[string]any{
								"tag": "geosite-cn", "type": "local", "format": "binary", "path": geositePath,
							})
						}
					}
					geoipPath := filepath.Join(dir, "rules", "geoip-cn.srs")
					if !hasGeoip {
						if _, err := os.Stat(geoipPath); err == nil {
							rsList = append(rsList, map[string]any{
								"tag": "geoip-cn", "type": "local", "format": "binary", "path": geoipPath,
							})
						}
					}
					routeMap["rule_set"] = rsList

					// 确保 DNS 劫持规则始终存在于 route.rules 顶部，防止脚本覆盖导致 DNS 无法被 FakeIP 捕获
					ruleEntries, _ := routeMap["rules"].([]any)
					hasDNSHijack := false
					for _, r := range ruleEntries {
						if rm, ok := r.(map[string]any); ok {
							if act, _ := rm["action"].(string); act == "hijack-dns" {
								hasDNSHijack = true
								break
							}
						}
					}
					if !hasDNSHijack {
						routeMap["rules"] = append([]any{
							map[string]any{"action": "sniff"},
							map[string]any{"inbound": []string{"mixed-in", "tun-in"}, "protocol": "dns", "action": "hijack-dns"},
						}, ruleEntries...)
					}
				}

				if safeBytes, err := json.MarshalIndent(finalMap, "", "  "); err == nil {
					return safeBytes, nil
				}
			}
			return transformed, nil
		}
	}
	return baseJSON, nil
}

// Effective returns the active node profile after its restricted transform is
// applied. It never mutates the source File; profile ownership is restored by
// node ID before the resulting view is returned.
func Effective(f state.File) (state.File, error) {
	p := f.ActiveProfile()
	if p == nil || p.Kind != state.ProfileKindNodes {
		return f, nil
	}
	scriptSource := ProfileScript(f, p)
	if scriptSource == "" {
		return f, nil
	}
	// 严格判断：只有明确包含 transformNodes 或作为旧节点转换脚本的 transform(nodes 时才执行
	if !strings.Contains(scriptSource, "transformNodes") && !strings.Contains(scriptSource, "transform(") && !strings.Contains(scriptSource, "transform =") {
		return f, nil
	}
	nodes, locations := scriptInput(*p)
	transformed, err := script.Transform(scriptSource, nodes, *p)
	if err != nil {
		if strings.Contains(err.Error(), "必须定义 transformNodes") && (strings.Contains(scriptSource, "main") || strings.Contains(scriptSource, "transformConfig")) {
			return f, nil
		}
		return state.File{}, err
	}
	updated, err := restoreNodeSources(*p, transformed, locations)
	if err != nil {
		return state.File{}, err
	}
	f.Profiles = append([]state.ConfigProfile(nil), f.Profiles...)
	for i := range f.Profiles {
		if f.Profiles[i].ID == p.ID {
			f.Profiles[i] = updated
		}
	}
	return f, nil
}

type nodeLocation struct {
	manual bool
	source int
}

// scriptInput records the source for every node before a transform runs.  The
// transform API deliberately works with plain nodes, so restoring this mapping
// afterwards keeps the profile's source health and grouping intact.
func scriptInput(p state.ConfigProfile) ([]state.Node, map[string]nodeLocation) {
	nodes := make([]state.Node, 0, len(p.ManualNodes))
	locations := make(map[string]nodeLocation, len(p.ManualNodes))
	for _, n := range p.ManualNodes {
		nodes = append(nodes, n)
		locations[n.ID] = nodeLocation{manual: true}
	}
	for i, source := range p.Sources {
		for _, n := range source.Nodes {
			nodes = append(nodes, n)
			locations[n.ID] = nodeLocation{source: i}
		}
	}
	return nodes, locations
}

func restoreNodeSources(profile state.ConfigProfile, nodes []state.Node, locations map[string]nodeLocation) (state.ConfigProfile, error) {
	updated := profile
	updated.ManualNodes = nil
	updated.Sources = append([]state.ConfigSource(nil), profile.Sources...)
	for i := range updated.Sources {
		updated.Sources[i].Nodes = nil
	}
	for _, n := range nodes {
		location, ok := locations[n.ID]
		if !ok {
			return state.ConfigProfile{}, fmt.Errorf("脚本覆写不能创建没有来源的节点: %s", n.ID)
		}
		if location.manual {
			updated.ManualNodes = append(updated.ManualNodes, n)
			continue
		}
		updated.Sources[location.source].Nodes = append(updated.Sources[location.source].Nodes, n)
	}
	return updated, nil
}

// fullConfig is deliberately byte-for-byte read-only.  A complete sing-box
// profile belongs to its author; Aster must not inject an API, an inbound, or
// any routing policy into it.
func fullConfig(f state.File, profile state.ConfigProfile) ([]byte, error) {
	scriptSource := ProfileScript(f, &profile)
	raw, err := script.TransformConfig(scriptSource, profile.Config, profile)
	if err != nil {
		return nil, err
	}
	var cfg map[string]json.RawMessage
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("完整配置不是有效 JSON: %w", err)
	}
	outbounds, ok := cfg["outbounds"]
	if !ok {
		return nil, fmt.Errorf("完整配置缺少 outbounds")
	}
	var entries []json.RawMessage
	if err := json.Unmarshal(outbounds, &entries); err != nil {
		return nil, fmt.Errorf("完整配置的 outbounds 必须是数组")
	}
	return append([]byte(nil), raw...), nil
}

// SupportsSystemProxy reports whether the active profile exposes a mixed
// inbound that macOS can use as its HTTP/HTTPS/SOCKS proxy endpoint.
func SupportsSystemProxy(f state.File) bool {
	return ImportedInboundCapabilities(f).SystemProxy
}

func SupportsTun(f state.File) bool {
	return ImportedInboundCapabilities(f).Tun
}

// InboundCapabilities describes only capabilities that can be verified from
// an imported profile.  Node profiles use Aster-owned inbounds and are always
// locally controllable.
type InboundCapabilities struct {
	SystemProxy bool
	MixedListen string
	MixedPort   int
	Tun         bool
}

func ImportedInboundCapabilities(f state.File) InboundCapabilities {
	p := f.ActiveProfile()
	if p == nil || p.Kind == state.ProfileKindNodes {
		port := f.Settings.MixedPort
		if port <= 0 {
			port = state.DefaultMixedPort
		}
		return InboundCapabilities{SystemProxy: true, MixedListen: "127.0.0.1", MixedPort: port, Tun: true}
	}
	if p.ImportedTun || p.ImportedMixedPort > 0 {
		return InboundCapabilities{SystemProxy: p.ImportedMixedPort > 0, MixedListen: p.ImportedMixedListen, MixedPort: p.ImportedMixedPort, Tun: p.ImportedTun}
	}
	// Backward-compatible fallback for callers holding a pre-migration state
	// snapshot or constructing a profile directly in an integration test.
	var cfg struct {
		Inbounds []struct {
			Type       string `json:"type"`
			Listen     string `json:"listen"`
			ListenPort int    `json:"listen_port"`
		} `json:"inbounds"`
	}
	if json.Unmarshal(p.Config, &cfg) != nil {
		return InboundCapabilities{}
	}
	var caps InboundCapabilities
	for _, inbound := range cfg.Inbounds {
		switch inbound.Type {
		case "tun":
			caps.Tun = true
		case "mixed":
			// An omitted listen address binds broadly in sing-box, which is not
			// safe to claim as the app's private system-proxy endpoint.
			if inbound.ListenPort > 0 && (inbound.Listen == "127.0.0.1" || inbound.Listen == "::1" || inbound.Listen == "localhost") {
				caps.SystemProxy = true
				caps.MixedListen = inbound.Listen
				caps.MixedPort = inbound.ListenPort
			}
		}
	}
	return caps
}

func hasInboundType(f state.File, typ string) bool {
	caps := ImportedInboundCapabilities(f)
	if typ == "mixed" {
		return caps.SystemProxy
	}
	return typ == "tun" && caps.Tun
}

func compileRule(r state.Rule) map[string]any {
	m := map[string]any{}
	switch r.Match {
	case "domain":
		m["domain"] = []string{r.Value}
	case "domain_suffix", "domain-suffix":
		m["domain_suffix"] = []string{strings.TrimPrefix(r.Value, ".")}
	case "domain_keyword", "domain-keyword":
		m["domain_keyword"] = []string{r.Value}
	case "ip_cidr":
		m["ip_cidr"] = []string{r.Value}
	case "process_name", "process-name":
		m["process_name"] = []string{r.Value}
	case "process_path", "process-path":
		m["process_path"] = []string{r.Value}
	case "port", "dst_port":
		if p, err := strconv.Atoi(r.Value); err == nil {
			m["port"] = []int{p}
		}
	default:
		m["domain_suffix"] = []string{r.Value}
	}
	act := strings.ToLower(strings.TrimSpace(r.Action))
	switch act {
	case "reject":
		m["action"] = "reject"
	case "direct":
		m["action"] = "route"
		m["outbound"] = "direct"
	case "proxy":
		m["action"] = "route"
		m["outbound"] = "proxy"
	default:
		m["action"] = "route"
		if r.Action != "" {
			m["outbound"] = r.Action
		} else {
			m["outbound"] = "proxy"
		}
	}
	return m
}

func dnsBlock(f state.File, nodeServers []string, dir string) map[string]any {
	servers := []any{
		map[string]any{"type": "https", "tag": "bootstrap", "server": "223.5.5.5", "path": "/dns-query"},
		map[string]any{"type": "udp", "tag": "cn", "server": "223.5.5.5"},
		map[string]any{"type": "https", "tag": "remote", "server": "1.1.1.1", "path": "/dns-query", "detour": "proxy"},
	}
	rules := []any{}
	if len(nodeServers) > 0 {
		rules = append(rules, map[string]any{
			"domain": nodeServers,
			"server": "bootstrap",
		})
	}
	geositePath := filepath.Join(dir, "rules", "geosite-cn.srs")
	if _, err := os.Stat(geositePath); err == nil {
		rules = append(rules, map[string]any{"rule_set": "geosite-cn", "server": "cn"})
	} else {
		rules = append(rules, map[string]any{
			"domain_suffix": []string{".cn", ".cn.", "aliyun.com", "qq.com", "baidu.com", "jd.com", "taobao.com", "bilibili.com", "163.com", "douyin.com", "zhihu.com"},
			"server":        "cn",
		})
	}
	if f.Settings.DNSMode != "redir-host" {
		servers = append(servers, map[string]any{
			"type":        "fakeip",
			"tag":         "fakeip",
			"inet4_range": "198.18.0.0/15",
			"inet6_range": "fc00::/18",
		})
		rules = append(rules, map[string]any{
			"inbound":    []string{"mixed-in", "tun-in"},
			"query_type": []string{"A", "AAAA"},
			"server":     "fakeip",
		})
	}
	return map[string]any{
		"servers":  servers,
		"rules":    rules,
		"final":    "cn",
		"strategy": "ipv4_only",
	}
}

func clashMode(mode string) string {
	switch mode {
	case "global":
		return "Global"
	case "direct":
		return "Direct"
	default:
		return "Rule"
	}
}

func proxyMembers(tags []string) []string {
	out := []string{"direct"}
	seen := map[string]bool{"direct": true}
	for _, tag := range tags {
		if tag == "" || seen[tag] {
			continue
		}
		seen[tag] = true
		out = append(out, tag)
	}
	return out
}

func defaultSelect(sel string, list []string) string {
	for _, t := range list {
		if t == sel {
			return sel
		}
	}
	for _, t := range list {
		if t != "direct" && t != "block" && t != "reject" && t != "dns" {
			return t
		}
	}
	if len(list) > 0 {
		return list[0]
	}
	return "direct"
}

func applySelectorDefaults(cfg map[string]any, selected string, byGroup map[string]string) {
	outbounds, ok := cfg["outbounds"].([]any)
	if !ok {
		return
	}
	for _, raw := range outbounds {
		outbound, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		if typ, _ := outbound["type"].(string); typ != "selector" {
			continue
		}
		tag, _ := outbound["tag"].(string)
		members := stringList(outbound["outbounds"])
		want := ""
		if byGroup != nil {
			want = byGroup[tag]
		}
		if tag == "proxy" && selected != "" {
			want = selected
		}
		if def := defaultSelect(want, members); def != "" {
			outbound["default"] = def
		}
	}
}

func stringList(v any) []string {
	switch typed := v.(type) {
	case []string:
		return append([]string(nil), typed...)
	case []any:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			if s, ok := item.(string); ok && s != "" {
				out = append(out, s)
			}
		}
		return out
	default:
		return nil
	}
}

func setTag(raw json.RawMessage, tag string) json.RawMessage {
	var m map[string]any
	if json.Unmarshal(raw, &m) != nil {
		return raw
	}
	m["tag"] = tag
	b, _ := json.Marshal(m)
	return b
}
