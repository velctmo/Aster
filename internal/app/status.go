package app

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"

	"aster/internal/clash"
	"aster/internal/helper"
	"aster/internal/macos"
	"aster/internal/render"
	"aster/internal/state"
)

func (a *App) PutSettings(s state.Settings) error {
	if err := validateSettings(s); err != nil {
		return err
	}
	old := a.st.Get()
	if p := old.ActiveProfile(); p != nil && p.Kind == state.ProfileKindSubscription && changesNodeRenderSettings(old.Settings, s) {
		return fmt.Errorf("完整订阅配置为只读，节点模式渲染设置不可修改")
	}
	restart := old.Settings.MixedPort != s.MixedPort || old.Settings.ClashPort != s.ClashPort || old.Settings.AllowLan != s.AllowLan ||
		old.Settings.DNSMode != s.DNSMode || old.Settings.CorePath != s.CorePath || old.Settings.StrictRoute != s.StrictRoute
	candidate := state.CloneFile(old)
	candidate.Settings = s
	if err := a.applyAndCommitCandidateWithRestart(old, candidate, restart, func(cur *state.File) { cur.Settings = s }); err != nil {
		return err
	}
	_ = macos.SetAutostart(s.Autostart, mustExe())
	return nil
}

func changesNodeRenderSettings(old, next state.Settings) bool {
	return old.MixedPort != next.MixedPort || old.ClashPort != next.ClashPort ||
		old.AllowLan != next.AllowLan || old.DirectCN != next.DirectCN ||
		old.DNSMode != next.DNSMode || old.StrictRoute != next.StrictRoute
}

func validateSettings(s state.Settings) error {
	for _, port := range []struct {
		name  string
		value int
	}{
		{"mixedPort", s.MixedPort},
		{"clashPort", s.ClashPort},
	} {
		if port.value < 1 || port.value > 65535 {
			return fmt.Errorf("%s 必须在 1 到 65535 之间", port.name)
		}
	}
	if s.MixedPort == s.ClashPort {
		return fmt.Errorf("混合端口与 Clash API 端口必须互不相同")
	}
	u, err := url.ParseRequestURI(s.DelayURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("测速 URL 必须是 HTTP(S) 地址")
	}
	if s.DelayTimeoutMs < 100 || s.DelayTimeoutMs > 120000 {
		return fmt.Errorf("测速超时必须在 100 到 120000 毫秒之间")
	}
	if s.DelayConcurrency < 1 || s.DelayConcurrency > 64 {
		return fmt.Errorf("测速并发必须在 1 到 64 之间")
	}
	if s.DNSMode != "fake-ip" && s.DNSMode != "redir-host" {
		return fmt.Errorf("不支持的 DNS 模式: %s", s.DNSMode)
	}
	switch s.LogLevel {
	case "trace", "debug", "info", "warn", "error", "fatal", "panic":
	default:
		return fmt.Errorf("不支持的日志级别: %s", s.LogLevel)
	}
	switch s.LogRetention {
	case "5m", "15m", "1h", "6h", "24h":
	default:
		return fmt.Errorf("不支持的审计保留期: %s", s.LogRetention)
	}
	return nil
}

func (a *App) Delay(tag string) (int, error) {
	if !a.core.Running() {
		return 0, fmt.Errorf("核心未运行，无法测速")
	}
	realTag := tag
	f := a.st.Active()

	// 针对节点名称、ID 或后缀进行精准映射
	if tag != "auto" {
		found := false
		nodes := a.Nodes()
		for _, n := range nodes {
			if n.Tag == tag {
				realTag = n.Tag
				found = true
				break
			}
		}
		if !found {
			for _, n := range nodes {
				if n.ID == tag || n.Name == tag || strings.HasSuffix(tag, n.Name) || strings.HasSuffix(n.Tag, tag) {
					realTag = n.Tag
					found = true
					break
				}
			}
		}
		if !found {
			// 支持策略组与复合出站（如 proxy, auto, direct 等）
			groups, gErr := a.StrategyGroups()
			if gErr == nil {
				for _, g := range groups {
					if g.Tag == tag || g.Name == tag {
						realTag = g.Tag
						break
					}
				}
			}
		}
	}

	timeoutMs := f.Settings.DelayTimeoutMs
	if timeoutMs <= 0 || timeoutMs > 2500 {
		timeoutMs = 2000 // 极速超时熔断
	}

	targetURL := f.Settings.DelayURL
	if targetURL == "" {
		targetURL = state.DefaultDelayURL
	}

	// 经由 sing-box 核心原生真实隧道探测，天然支持全协议 (VLESS/VMess/SS/Trojan/Hysteria2/TUIC/WireGuard)
	d, err := a.clash.Delay(realTag, targetURL, timeoutMs)

	a.mu.Lock()
	if err == nil && d > 0 {
		a.delays[tag] = d
		a.delays[realTag] = d
		if realTag == f.Selected || realTag == "auto" {
			a.delay = d
		}
	} else {
		d = -1
		a.delays[tag] = -1
		a.delays[realTag] = -1
		if realTag == f.Selected || realTag == "auto" {
			a.delay = -1
		}
	}
	a.mu.Unlock()
	a.hub.Broadcast("status", a.Status())
	// 逐节点/策略组增量流式广播，通知前端毫秒级点亮
	a.hub.Broadcast("node_delay", map[string]any{"tag": realTag, "delay": d})
	return d, err
}

func (a *App) DelayMany(tags []string) []map[string]any {
	if !a.core.Running() {
		return []map[string]any{{"error": "核心未运行，无法测速"}}
	}
	f := a.st.Active()
	if len(tags) == 0 {
		groups, err := a.StrategyGroups()
		if err == nil {
			seen := map[string]bool{}
			for _, group := range groups {
				if !seen[group.Tag] {
					seen[group.Tag] = true
					tags = append(tags, group.Tag)
				}
				for _, tag := range group.LeafTags {
					if !seen[tag] {
						seen[tag] = true
						tags = append(tags, tag)
					}
				}
			}
		}
	}
	if len(tags) == 0 {
		for _, n := range a.Nodes() {
			if n.Disabled || n.Tag == "auto" {
				continue
			}
			tags = append(tags, n.Tag)
		}
	}
	workers := f.Settings.DelayConcurrency
	if workers <= 0 || workers < 32 {
		workers = 32 // Surge 风格高并发抢占
	}
	if workers > 64 {
		workers = 64 // 保证低 CPU 和内存占用
	}
	sem := make(chan struct{}, workers)
	var wg sync.WaitGroup
	out := make([]map[string]any, len(tags))
	for i, tag := range tags {
		wg.Add(1)
		go func(i int, tag string) {
			defer wg.Done()
			sem <- struct{}{}
			d, err := a.Delay(tag)
			<-sem
			item := map[string]any{"tag": tag, "delay": d}
			if err != nil {
				item["delay"] = -1
				item["error"] = err.Error()
			}
			out[i] = item
		}(i, tag)
	}
	wg.Wait()
	return out
}

// StrategyGroups is derived from the rendered active configuration, making
// imported sing-box profiles and Aster-generated node profiles use the same
// presentation and measurement model. When Clash API is available, it enriches
// each group with its live active selection (Now).
func (a *App) StrategyGroups() ([]render.Group, error) {
	f := a.st.Active()
	config, err := render.Config(f, a.st.Dir())
	if err != nil {
		return nil, err
	}
	groups, err := render.Groups(config)
	if err != nil {
		return nil, err
	}
	for i := range groups {
		if groups[i].Now == "" {
			if saved := selectorSaved(f, groups[i].Tag); saved != "" {
				groups[i].Now = saved
			}
		}
	}
	a.mu.Lock()
	delays := make(map[string]int, len(a.delays))
	for k, v := range a.delays {
		delays[k] = v
	}
	a.mu.Unlock()
	for i := range groups {
		if d, ok := delays[groups[i].Tag]; ok {
			groups[i].DelayMs = d
		}
	}
	if a.core.Running() {
		if proxies, pErr := a.clash.Proxies(); pErr == nil && proxies != nil {
			for i := range groups {
				if p, ok := proxies[groups[i].Tag]; ok {
					if p.Now != "" {
						groups[i].Now = p.Now
					}
					if groups[i].DelayMs <= 0 && len(p.History) > 0 {
						lastDelay := p.History[len(p.History)-1].Delay
						if lastDelay > 0 {
							groups[i].DelayMs = lastDelay
						}
					}
				}
			}
		}
	}
	return groups, nil
}

func (a *App) DelayGroup(tag string) ([]map[string]any, error) {
	groups, err := a.StrategyGroups()
	if err != nil {
		return nil, err
	}
	strategyTags := make(map[string]bool, len(groups))
	for _, group := range groups {
		strategyTags[group.Tag] = true
	}
	for _, group := range groups {
		if group.Tag != tag {
			continue
		}
		tags := render.ProbeTags(group, strategyTags)
		if len(tags) == 0 {
			return nil, fmt.Errorf("策略组没有可测速的节点")
		}
		return a.DelayMany(tags), nil
	}
	return nil, fmt.Errorf("策略组不存在: %s", tag)
}

func (a *App) SelectGroupNode(groupTag, nodeTag string) error {
	groups, err := a.StrategyGroups()
	if err != nil {
		return err
	}
	for _, group := range groups {
		if group.Tag != groupTag {
			continue
		}
		if group.Type != "selector" {
			return fmt.Errorf("策略组 %s 不支持手动选择", groupTag)
		}
		allowed := false
		for _, member := range group.Members {
			if member == nodeTag {
				allowed = true
				break
			}
		}
		if !allowed {
			return fmt.Errorf("节点不属于策略组 %s", groupTag)
		}
		isMain := groupTag == "proxy" || (len(groups) > 0 && groups[0].Tag == groupTag)
		if !a.core.Running() {
			old := a.st.Get()
			candidate := state.CloneFile(old)
			if candidate.SelectorNow == nil {
				candidate.SelectorNow = map[string]string{}
			}
			candidate.SelectorNow[groupTag] = nodeTag
			if isMain {
				candidate.Selected = nodeTag
				if nodeTag != "auto" {
					candidate.RecentNodes = prepend(candidate.RecentNodes, nodeTag, 8)
				}
			}
			if err := a.applyAndCommitCandidate(old, candidate, func(cur *state.File) {
				if cur.SelectorNow == nil {
					cur.SelectorNow = map[string]string{}
				}
				cur.SelectorNow[groupTag] = nodeTag
				if isMain {
					cur.Selected = nodeTag
					if nodeTag != "auto" {
						cur.RecentNodes = prepend(cur.RecentNodes, nodeTag, 8)
					}
				}
			}); err != nil {
				return err
			}
			a.hub.Broadcast("status", a.Status())
			if updatedGroups, gErr := a.StrategyGroups(); gErr == nil {
				a.hub.Broadcast("strategy-groups", updatedGroups)
			}
			return nil
		}

		if err := a.clash.Select(groupTag, nodeTag); err != nil {
			return err
		}
		_, _ = a.st.Update(func(cur *state.File) error {
			if cur.SelectorNow == nil {
				cur.SelectorNow = map[string]string{}
			}
			cur.SelectorNow[groupTag] = nodeTag
			if isMain {
				cur.Selected = nodeTag
				if nodeTag != "auto" {
					cur.RecentNodes = prepend(cur.RecentNodes, nodeTag, 8)
				}
			}
			return nil
		})
		if isMain && nodeTag == "auto" {
			go func() {
				_, _ = a.Delay("auto")
			}()
		}
		a.hub.Broadcast("status", a.Status())
		if updatedGroups, gErr := a.StrategyGroups(); gErr == nil {
			a.hub.Broadcast("strategy-groups", updatedGroups)
		}
		return nil
	}
	return fmt.Errorf("策略组不存在: %s", groupTag)
}

func (a *App) ClashCloseAll() error { return a.clash.CloseAll() }

func (a *App) ClashCloseOne(id string) error { return a.clash.CloseOne(id) }

// LiveRules returns the combined view of user-configured rules and rules
// dynamically injected by override scripts or loaded by the running core.
// Compound rules (multiple domains/suffixes/processes) are flattened into
// distinct individual rows so users can inspect and filter each exact item.
func (a *App) LiveRules() []state.Rule {
	userRules := a.st.Get().Rules
	userRuleSet := make(map[string]bool, len(userRules))
	var result []state.Rule
	for _, r := range userRules {
		r.Source = "USER"
		userRuleSet[strings.ToUpper(r.Match)+"#"+strings.TrimSpace(r.Value)] = true
		result = append(result, r)
	}

	// 优先直接从当前生效的配置文件中读取结构化的 route.rules，避免 Clash API payload 压缩与省略号截断
	var configBytes []byte
	if a.st.ConfigPath() != "" {
		configBytes, _ = os.ReadFile(a.st.ConfigPath())
	}
	if len(configBytes) == 0 {
		configBytes, _ = render.Config(a.st.Active(), a.st.Dir())
	}

	seenItemKey := make(map[string]bool)
	ruleIndex := 1

	addEntry := func(matchType, val, action, defaultSource string) {
		val = strings.TrimSpace(val)
		if val == "" {
			return
		}
		matchUpper := strings.ToUpper(strings.ReplaceAll(matchType, "_", "-"))
		dedupKey := matchUpper + "#" + val
		if userRuleSet[dedupKey] || seenItemKey[dedupKey] {
			return
		}
		seenItemKey[dedupKey] = true

		source := defaultSource
		valLower := strings.ToLower(val)
		if strings.Contains(valLower, "geosite-cn") || strings.Contains(valLower, "geoip-cn") ||
			strings.Contains(valLower, "category-ads") || matchUpper == "IP-IS-PRIVATE" {
			source = "SYSTEM"
		}

		result = append(result, state.Rule{
			ID:     fmt.Sprintf("live-%d", ruleIndex),
			Match:  matchUpper,
			Value:  val,
			Action: action,
			Source: source,
		})
		ruleIndex++
	}

	extractItems := func(v any) []string {
		if v == nil {
			return nil
		}
		switch val := v.(type) {
		case string:
			if val != "" {
				return []string{val}
			}
		case []string:
			return val
		case []any:
			var res []string
			for _, item := range val {
				if s, ok := item.(string); ok && s != "" {
					res = append(res, s)
				}
			}
			return res
		}
		return nil
	}

	if len(configBytes) > 0 {
		var doc struct {
			Route struct {
				Rules []map[string]any `json:"rules"`
			} `json:"route"`
		}
		if err := json.Unmarshal(configBytes, &doc); err == nil && len(doc.Route.Rules) > 0 {
			for _, r := range doc.Route.Rules {
				actionStr, _ := r["action"].(string)
				if actionStr == "sniff" || actionStr == "hijack-dns" || actionStr == "resolve" {
					continue
				}
				if _, hasClashMode := r["clash_mode"]; hasClashMode {
					continue
				}

				outbound, _ := r["outbound"].(string)
				if outbound == "" {
					outbound = actionStr
				}
				if outbound == "" {
					outbound = "direct"
				}

				// 1. domain
				for _, d := range extractItems(r["domain"]) {
					addEntry("DOMAIN", d, outbound, "SCRIPT")
				}
				// 2. domain_suffix
				for _, ds := range extractItems(r["domain_suffix"]) {
					addEntry("DOMAIN-SUFFIX", ds, outbound, "SCRIPT")
				}
				// 3. domain_keyword
				for _, dk := range extractItems(r["domain_keyword"]) {
					addEntry("DOMAIN-KEYWORD", dk, outbound, "SCRIPT")
				}
				// 4. ip_cidr
				for _, ip := range extractItems(r["ip_cidr"]) {
					addEntry("IP-CIDR", ip, outbound, "SCRIPT")
				}
				// 5. process_name
				for _, pn := range extractItems(r["process_name"]) {
					addEntry("PROCESS-NAME", pn, outbound, "SCRIPT")
				}
				// 6. process_path
				for _, pp := range extractItems(r["process_path"]) {
					addEntry("PROCESS-PATH", pp, outbound, "SCRIPT")
				}
				// 7. package_name
				for _, pkg := range extractItems(r["package_name"]) {
					addEntry("PACKAGE-NAME", pkg, outbound, "SCRIPT")
				}
				// 8. rule_set
				for _, rs := range extractItems(r["rule_set"]) {
					addEntry("RULE-SET", rs, outbound, "SCRIPT")
				}
				// 9. ip_is_private
				if isPriv, ok := r["ip_is_private"].(bool); ok && isPriv {
					addEntry("IP-IS-PRIVATE", "局域网私有 IP (LAN 直连)", outbound, "SYSTEM")
				}
			}
			return result
		}
	}

	// 降级兜底：从 Clash API 提取
	if a.core.Running() {
		if rawRules, err := a.clash.Rules(); err == nil && len(rawRules) > 0 {
			for _, cr := range rawRules {
				if cr.Proxy == "sniff" || cr.Proxy == "hijack-dns" || strings.Contains(cr.Payload, "clash_mode=") || strings.Contains(cr.Payload, "inbound=") {
					continue
				}
				action := cr.Proxy
				if strings.HasPrefix(action, "route(") && strings.HasSuffix(action, ")") {
					action = action[6 : len(action)-1]
				}
				payload := strings.TrimSpace(cr.Payload)
				if payload == "" {
					continue
				}
				addEntry(cr.Type, payload, action, "SCRIPT")
			}
		}
	}

	return result
}

func (a *App) ClashConnections() (*clash.Connections, error) {
	snap, err := a.clash.Snapshot()
	if err != nil || snap == nil {
		return snap, err
	}
	for i := range snap.Connections {
		c := &snap.Connections[i]
		c.Metadata.Process = ResolveProcessName(c.Metadata.Process, c.Metadata.ProcessPath)
	}
	return snap, nil
}

func (a *App) Status() StatusJSON {
	f := a.st.Active()
	active := f.ActiveProfile()
	caps := capabilitiesFor(f)
	nodes, _ := a.activeMergedNodes(f)
	has := false
	label := f.Selected
	for _, n := range nodes {
		if !n.Disabled {
			has = true
		}
		if n.Tag == f.Selected || n.NodeID == f.Selected {
			label = n.Name
		}
	}
	running := a.core.Running()
	if f.Selected == "auto" {
		if a.selectableProxyMember("auto") == "" {
			label = "节点选择"
		} else {
			label = "自动选择"
			if running {
				if proxies, pErr := a.clash.Proxies(); pErr == nil && proxies != nil {
					if autoP, ok := proxies["auto"]; ok && autoP.Now != "" {
						winName := autoP.Now
						for _, n := range nodes {
							if n.Tag == autoP.Now || n.NodeID == autoP.Now {
								winName = n.Name
								break
							}
						}
						label = fmt.Sprintf("自动选择 ➔ %s", winName)
					}
				}
			}
		}
	}
	if active != nil && active.Kind == state.ProfileKindSubscription {
		label = "由完整配置管理"
	}
	port := proxyPort(f)

	coreErr := ""
	if !running && f.Wanted {
		coreErr = a.core.LastError()
	}
	coreVer := a.core.Version()

	a.mu.Lock()
	pending := a.pending
	needAdm := a.needAdm
	tunFail := a.tunFail
	errStr := a.lastErr
	delay := a.delay
	up, down := a.up, a.down
	if f.Selected == "auto" && delay <= 0 {
		if d, ok := a.delays["auto"]; ok && d > 0 {
			delay = d
		}
	}
	a.mu.Unlock()

	if f.Selected == "auto" && delay <= 0 && running {
		if proxies, pErr := a.clash.Proxies(); pErr == nil && proxies != nil {
			if autoP, ok := proxies["auto"]; ok && len(autoP.History) > 0 {
				lastD := autoP.History[len(autoP.History)-1].Delay
				if lastD > 0 {
					delay = lastD
				}
			}
		}
	}

	if errStr == "" && !running && f.Wanted {
		errStr = coreErr
	}
	errStr = redactDiagnosticText(errStr)
	phase := "failed"
	if pending {
		phase = "starting"
	} else if running && f.Wanted {
		phase = "running"
	} else if needAdm && strings.Contains(errStr, "网络组件") {
		phase = "networkComponentRequired"
	}
	status := StatusJSON{
		Running:                running && f.Wanted,
		Pending:                pending,
		SessionPhase:           phase,
		NeedAdmin:              needAdm,
		TunFailed:              tunFail,
		Error:                  errStr,
		Mode:                   f.Mode,
		Capture:                effectiveCapture(f, running),
		Selected:               f.Selected,
		SelectedLabel:          label,
		DelayMs:                delay,
		Upload:                 up,
		Download:               down,
		CoreVersion:            coreVer,
		HasNodes:               has,
		RecentNodes:            f.RecentNodes,
		MixedPort:              port,
		DelayURL:               f.Settings.DelayURL,
		APIVersion:             "1",
		Capabilities:           caps,
		LastSuccessfulConfigID: f.Runtime.LastSuccessfulConfigID,
		LastSuccessfulAt:       f.Runtime.LastSuccessfulAt,
	}
	if active != nil {
		status.ActiveConfigID = active.ID
		status.ActiveConfigName = active.Name
		status.ActiveConfigKind = active.Kind
		if active.Kind == state.ProfileKindSubscription {
			status.FeatureRestriction = "完整订阅默认由 sing-box 原样运行；显式绑定配置覆写脚本时使用脚本输出。节点、规则、模式与测速为只读。"
		}
	}
	return status
}

// effectiveCapture reports the system state Aster can actually own. Imported
// profiles retain the user's previous preference in state, but cannot inherit
// a system proxy without a verified loopback mixed inbound and cannot expose a
// controllable TUN switch.
func effectiveCapture(f state.File, running bool) state.Capture {
	capture := f.Capture
	host, port := proxyHost(f), proxyPort(f)
	capture.SystemProxy = macos.SystemProxyPointsTo(host, port)
	if p := f.ActiveProfile(); p != nil && p.Kind == state.ProfileKindSubscription {
		capture.SystemProxy = capture.SystemProxy && render.SupportsSystemProxy(f)
		capture.Tun = running && f.Wanted && render.SupportsTun(f)
	}
	return capture
}

func capabilitiesFor(f state.File) CapabilitiesJSON {
	p := f.ActiveProfile()
	if p == nil || p.Kind == state.ProfileKindNodes {
		tun := CapabilityJSON{Available: helper.NewClient().Installed()}
		if !tun.Available {
			tun.Reason = "请安装 Aster 网络组件（Aster.pkg）"
		}
		return CapabilitiesJSON{
			SystemProxy: CapabilityJSON{Available: true}, Tun: tun,
			NodeControl: CapabilityJSON{Available: true}, RuleControl: CapabilityJSON{Available: true},
			Speedtest: CapabilityJSON{Available: true},
		}
	}
	inbounds := render.ImportedInboundCapabilities(f)
	proxyReason := "完整配置未提供监听在 loopback 的 mixed 入站"
	if inbounds.SystemProxy {
		proxyReason = ""
	}
	tunReason := "完整配置未定义 TUN 入站"
	if inbounds.Tun {
		tunReason = "TUN 由完整配置自行管理，Aster 不提供开关"
	}
	readonly := CapabilityJSON{Reason: "完整订阅配置为严格只读"}
	return CapabilitiesJSON{
		SystemProxy: CapabilityJSON{Available: inbounds.SystemProxy, Reason: proxyReason},
		// A TUN inbound in an imported configuration is observable, but it is
		// never controllable by Aster under the strict read-only contract.
		Tun:         CapabilityJSON{Available: false, Reason: tunReason},
		NodeControl: readonly, RuleControl: readonly, Speedtest: readonly,
	}
}

func proxyPort(f state.File) int {
	if caps := render.ImportedInboundCapabilities(f); caps.SystemProxy && caps.MixedPort > 0 {
		return caps.MixedPort
	}
	if f.Settings.MixedPort > 0 {
		return f.Settings.MixedPort
	}
	return state.DefaultMixedPort
}

func proxyHost(f state.File) string {
	if caps := render.ImportedInboundCapabilities(f); caps.SystemProxy && caps.MixedListen != "" {
		return caps.MixedListen
	}
	return "127.0.0.1"
}

// activeMergedNodes is the single node view used by the control plane. A node
// profile's restricted script is evaluated once per persisted profile version,
// so status polling, the list, selection and delay checks all see the same
// names and disabled state as the generated sing-box configuration.
func (a *App) activeMergedNodes(f state.File) ([]render.MergedNode, error) {
	p := f.ActiveProfile()
	if p == nil || p.Kind != state.ProfileKindNodes {
		return nil, nil
	}
	key := effectiveNodesKey(*p)
	a.mu.Lock()
	if a.effectiveNodesKey == key {
		nodes := append([]render.MergedNode(nil), a.effectiveNodes...)
		a.mu.Unlock()
		return nodes, nil
	}
	a.mu.Unlock()

	effective, err := render.Effective(f)
	if err != nil {
		return nil, err
	}
	nodes := render.Merge(effective)
	a.mu.Lock()
	a.effectiveNodesKey = key
	a.effectiveNodes = append([]render.MergedNode(nil), nodes...)
	a.mu.Unlock()
	return nodes, nil
}

func (a *App) selectableProxyMember(tag string) string {
	if tag == "" {
		return ""
	}
	if tag == "direct" {
		return tag
	}
	if groups, err := a.StrategyGroups(); err == nil {
		for _, group := range groups {
			if group.Tag == tag {
				return tag
			}
			for _, member := range group.Members {
				if member == tag {
					return tag
				}
			}
			for _, leaf := range group.LeafTags {
				if leaf == tag {
					return tag
				}
			}
		}
	}
	nodes, err := a.activeMergedNodes(a.st.Active())
	if err != nil {
		return ""
	}
	for _, n := range nodes {
		if n.Tag == tag || n.NodeID == tag {
			return n.Tag
		}
	}
	return ""
}

func selectorSaved(f state.File, tag string) string {
	if f.SelectorNow != nil {
		if saved := f.SelectorNow[tag]; saved != "" {
			return saved
		}
	}
	if tag == "proxy" {
		return f.Selected
	}
	return ""
}

// effectiveNodesKey uses a durable profile revision rather than hashing every
// node on a status poll. UpdatedAt intentionally remains second-granularity
// for UI display, while Revision changes for every render-affecting mutation.
func effectiveNodesKey(p state.ConfigProfile) string {
	return p.ID + ":" + strconv.FormatUint(p.Revision, 10)
}

func (a *App) Nodes() []NodeJSON {
	// Node presentation is always scoped to the unique active profile. Avoid
	// cloning full subscription documents and every inactive node pool for a
	// routine /nodes snapshot.
	f := a.st.Active()
	if p := f.ActiveProfile(); p != nil && p.Kind != state.ProfileKindNodes {
		return nil
	}
	a.mu.Lock()
	delays := map[string]int{}
	for k, v := range a.delays {
		delays[k] = v
	}
	bandwidths := map[string]float64{}
	for k, v := range a.bandwidths {
		bandwidths[k] = v
	}
	a.mu.Unlock()
	out := []NodeJSON{}
	if groups, err := a.StrategyGroups(); err == nil {
		for _, group := range groups {
			if group.Tag == "auto" {
				out = append(out, NodeJSON{
					ID: "auto", Tag: "auto", Name: "自动选择", Protocol: "urltest", DelayMs: delays["auto"],
				})
				break
			}
		}
	}
	nodes, err := a.activeMergedNodes(f)
	if err != nil {
		return nil
	}
	for _, n := range nodes {
		delay := delays[n.Tag]
		if delay == 0 {
			if d, ok := delays[n.NodeID]; ok {
				delay = d
			} else if d, ok := delays[n.Name]; ok {
				delay = d
			}
		}
		out = append(out, NodeJSON{
			ID: n.NodeID, Tag: n.Tag, Name: n.Name, Protocol: n.Protocol,
			SubID: n.SubID, SubName: n.SubName, Disabled: n.Disabled, DelayMs: delay,
			BandwidthMbps: bandwidths[n.Tag],
		})
	}
	return out
}

func validateBackupCandidate(candidate state.File) error {
	if err := validateSettings(candidate.Settings); err != nil {
		return fmt.Errorf("备份设置无效: %w", err)
	}
	if candidate.ActiveProfile() == nil {
		return fmt.Errorf("备份中没有可用活动配置")
	}
	seen := make(map[string]struct{}, len(candidate.Profiles))
	for _, profile := range candidate.Profiles {
		if profile.ID == "" {
			return fmt.Errorf("备份包含没有 ID 的配置")
		}
		if _, exists := seen[profile.ID]; exists {
			return fmt.Errorf("备份包含重复配置 ID: %s", profile.ID)
		}
		seen[profile.ID] = struct{}{}
		switch profile.Kind {
		case state.ProfileKindSubscription:
			if _, err := validSingBoxConfig(string(profile.Config)); err != nil {
				return fmt.Errorf("配置 %q 无效: %w", profile.Name, err)
			}
			if profile.Source != "" {
				if err := validHTTPURL(profile.Source); err != nil {
					return fmt.Errorf("配置 %q 的订阅地址无效: %w", profile.Name, err)
				}
			}
		case state.ProfileKindNodes:
			if err := validateBackupNodes(profile); err != nil {
				return fmt.Errorf("配置 %q 无效: %w", profile.Name, err)
			}
			view := state.CloneFile(candidate)
			view.ActiveConfigID = profile.ID
			if _, err := render.Config(view, ""); err != nil {
				return fmt.Errorf("配置 %q 的节点覆写无效: %w", profile.Name, err)
			}
		default:
			return fmt.Errorf("配置 %q 使用不支持的类型: %s", profile.Name, profile.Kind)
		}
	}
	return nil
}

func validateBackupNodes(profile state.ConfigProfile) error {
	nodeIDs := map[string]struct{}{}
	validateNodes := func(nodes []state.Node) error {
		for _, node := range nodes {
			if node.ID == "" || node.Name == "" || node.Protocol == "" {
				return fmt.Errorf("节点缺少 id、name 或 protocol")
			}
			if _, exists := nodeIDs[node.ID]; exists {
				return fmt.Errorf("节点 ID 重复: %s", node.ID)
			}
			nodeIDs[node.ID] = struct{}{}
			var outbound map[string]json.RawMessage
			if err := json.Unmarshal(node.Outbound, &outbound); err != nil || outbound == nil {
				return fmt.Errorf("节点 %q 的出站配置不是 JSON 对象", node.Name)
			}
			if _, ok := outbound["type"]; !ok {
				return fmt.Errorf("节点 %q 的出站配置缺少 type", node.Name)
			}
		}
		return nil
	}
	if err := validateNodes(profile.ManualNodes); err != nil {
		return err
	}
	sourceIDs := map[string]struct{}{}
	for _, source := range profile.Sources {
		if source.ID == "" {
			return fmt.Errorf("节点订阅缺少来源 ID")
		}
		if _, exists := sourceIDs[source.ID]; exists {
			return fmt.Errorf("节点订阅来源 ID 重复: %s", source.ID)
		}
		sourceIDs[source.ID] = struct{}{}
		if err := validHTTPURL(source.URL); err != nil {
			return fmt.Errorf("节点订阅地址无效: %w", err)
		}
		if err := validateNodes(source.Nodes); err != nil {
			return err
		}
	}
	return nil
}

func (a *App) ClearProxyResidue() error {
	f := a.st.Get()
	return a.disableSystemProxy(f)
}
