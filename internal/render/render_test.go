package render

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"aster/internal/state"
)

func TestMergePrefixAndUnique(t *testing.T) {
	f := state.File{
		Profiles: []state.ConfigProfile{{ID: "nodes", Kind: state.ProfileKindNodes, Sources: []state.ConfigSource{
			{ID: "a", URL: "机场A", Nodes: []state.Node{
				{ID: "1", Name: "香港01", Protocol: "vless", Outbound: json.RawMessage(`{"type":"vless","tag":"香港01"}`)},
			}},
			{ID: "b", URL: "机场B", Nodes: []state.Node{
				{ID: "2", Name: "香港01", Protocol: "ss", Outbound: json.RawMessage(`{"type":"shadowsocks","tag":"香港01"}`)},
			}},
		}}}, ActiveConfigID: "nodes",
	}
	m := Merge(f)
	if len(m) != 2 {
		t.Fatalf("len %d", len(m))
	}
	if m[0].Tag != "机场A · 香港01" || m[1].Tag != "机场B · 香港01" {
		t.Fatalf("%s %s", m[0].Tag, m[1].Tag)
	}
}

func TestMergeRedactsSubscriptionURLFromTags(t *testing.T) {
	f := state.DefaultFile()
	f.Profiles[0].Sources = []state.ConfigSource{{
		ID: "source", URL: "https://user:secret@sub.example/path?token=private",
		Nodes: []state.Node{{ID: "n", Name: "node", Outbound: json.RawMessage(`{"type":"direct"}`)}},
	}}
	merged := Merge(f)
	if len(merged) != 1 || merged[0].Tag != "sub.example · node" || merged[0].SubName != "sub.example" {
		t.Fatalf("unexpected source label: %+v", merged)
	}
	if strings.Contains(merged[0].Tag, "secret") || strings.Contains(merged[0].Tag, "private") {
		t.Fatalf("raw URL leaked into tag: %s", merged[0].Tag)
	}
}

func TestEffectiveAppliesScriptWithoutLosingNodeSources(t *testing.T) {
	f := state.DefaultFile()
	f.Profiles[0].Sources = []state.ConfigSource{{
		ID: "source", URL: "https://sub.example/list",
		Nodes: []state.Node{{ID: "node", Name: "原始节点", Protocol: "direct", Outbound: json.RawMessage(`{"type":"direct"}`)}},
	}}
	f.Profiles[0].Script = `function transform(nodes) { return nodes.map(n => ({...n, name: "优选 " + n.name})); }`

	effective, err := Effective(f)
	if err != nil {
		t.Fatal(err)
	}
	merged := Merge(effective)
	if len(merged) != 1 || merged[0].Name != "优选 原始节点" || merged[0].SubID != "source" {
		t.Fatalf("unexpected effective nodes: %+v", merged)
	}
	if got := f.Profiles[0].Sources[0].Nodes[0].Name; got != "原始节点" {
		t.Fatalf("Effective mutated source node: %q", got)
	}
}

func withNode(f state.File, node state.Node) state.File {
	p := f.ActiveProfile()
	if p == nil {
		panic("default file needs a profile")
	}
	for i := range f.Profiles {
		if f.Profiles[i].ID == p.ID {
			f.Profiles[i].ManualNodes = []state.Node{node}
		}
	}
	return f
}

func TestConfigHasSelectorAndClashAPI(t *testing.T) {
	f := state.DefaultFile()
	f = withNode(f, state.Node{
		ID: "n", Name: "n1", Protocol: "vless",
		Outbound: json.RawMessage(`{"type":"vless","server":"x.com","server_port":443,"uuid":"u"}`),
	})
	dataDir := t.TempDir()
	b, err := Config(f, dataDir)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	for _, need := range []string{`"tag": "proxy"`, `"type": "selector"`, `"cache_file"`, `127.0.0.1:9090`, `"hijack-dns"`, `"find_process"`, `198.18.0.0/15`, `223.5.5.5`} {
		if !strings.Contains(s, need) {
			t.Fatalf("missing %s in %s", need, s[:min(len(s), 400)])
		}
	}
}

func TestNodePoolDefaultHasSingleProxyGroup(t *testing.T) {
	f := state.DefaultFile()
	f = withNode(f, state.Node{
		ID: "n", Name: "n1", Protocol: "vless",
		Outbound: json.RawMessage(`{"type":"vless","server":"x.com","server_port":443,"uuid":"u"}`),
	})
	b, err := Config(f, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	proxy, groups, hasAuto := parseStrategyOutbounds(t, b)
	if hasAuto {
		t.Fatal("node pool must not inject a default auto urltest")
	}
	if len(groups) != 1 || groups[0] != "proxy" {
		t.Fatalf("default groups=%v", groups)
	}
	if len(proxy) != 2 || proxy[0] != "direct" || proxy[1] != "n1" {
		t.Fatalf("proxy members=%v", proxy)
	}
	groupsOut, err := Groups(b)
	if err != nil {
		t.Fatal(err)
	}
	if len(groupsOut) != 1 || groupsOut[0].Tag != "proxy" || groupsOut[0].Name != "节点选择" {
		t.Fatalf("groups=%+v", groupsOut)
	}
}

func TestNodePoolEmptyProxyFallsBackToDirect(t *testing.T) {
	b, err := Config(state.DefaultFile(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	proxy, _, hasAuto := parseStrategyOutbounds(t, b)
	if hasAuto {
		t.Fatal("empty node pool must not inject auto")
	}
	if len(proxy) != 1 || proxy[0] != "direct" {
		t.Fatalf("empty proxy members=%v", proxy)
	}
}

func TestConfigPersistsSelectedIntoProxyDefault(t *testing.T) {
	f := state.DefaultFile()
	f = withNode(f, state.Node{
		ID: "n", Name: "hk-01", Protocol: "vless",
		Outbound: json.RawMessage(`{"type":"vless","server":"x.com","server_port":443,"uuid":"u"}`),
	})
	f.Selected = "hk-01"
	b, err := Config(f, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var cfg struct {
		Outbounds []struct {
			Tag     string   `json:"tag"`
			Type    string   `json:"type"`
			Default string   `json:"default"`
			Members []string `json:"outbounds"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, outbound := range cfg.Outbounds {
		if outbound.Tag != "proxy" || outbound.Type != "selector" {
			continue
		}
		found = true
		if outbound.Default != "hk-01" {
			t.Fatalf("proxy default=%q members=%v", outbound.Default, outbound.Members)
		}
	}
	if !found {
		t.Fatal("missing proxy selector")
	}
	groups, err := Groups(b)
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 1 || groups[0].Now != "hk-01" {
		t.Fatalf("groups now=%+v", groups)
	}
}

func TestConfigAppliesSelectorNowAfterScript(t *testing.T) {
	f := state.DefaultFile()
	f = withNode(f, state.Node{
		ID: "n", Name: "hk-01", Protocol: "vless",
		Outbound: json.RawMessage(`{"type":"vless","server":"x.com","server_port":443,"uuid":"u"}`),
	})
	f.Selected = "hk-01"
	f.SelectorNow = map[string]string{"香港": "hk-01"}
	p := f.ActiveProfile()
	for i := range f.Profiles {
		if f.Profiles[i].ID == p.ID {
			f.Profiles[i].Script = `function main(config) {
  config.outbounds.push({type:'selector', tag:'香港', outbounds:['hk-01','direct']});
  const proxy = config.outbounds.find(o => o.tag === 'proxy');
  if (proxy) delete proxy.default;
  return config;
}`
		}
	}
	b, err := Config(f, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	groups, err := Groups(b)
	if err != nil {
		t.Fatal(err)
	}
	var proxyNow, hkNow string
	for _, group := range groups {
		switch group.Tag {
		case "proxy":
			proxyNow = group.Now
		case "香港":
			hkNow = group.Now
		}
	}
	if proxyNow != "hk-01" {
		t.Fatalf("proxy now=%q groups=%+v", proxyNow, groups)
	}
	if hkNow != "hk-01" {
		t.Fatalf("hongkong now=%q groups=%+v", hkNow, groups)
	}
}

func TestNodePoolScriptAddsUrltestGroups(t *testing.T) {
	f := state.DefaultFile()
	f = withNode(f, state.Node{
		ID: "n", Name: "日本01", Protocol: "vless",
		Outbound: json.RawMessage(`{"type":"vless","server":"x.com","server_port":443,"uuid":"u"}`),
	})
	p := f.ActiveProfile()
	for i := range f.Profiles {
		if f.Profiles[i].ID == p.ID {
			f.Profiles[i].Script = `function main(config) {
  const skip = new Set(['direct','proxy','reject','block','dns']);
  const tags = (config.outbounds || []).filter(o => o.tag && !skip.has(o.tag) && o.type !== 'selector' && o.type !== 'urltest' && o.type !== 'fallback').map(o => o.tag);
  config.outbounds.push({type:'urltest', tag:'日本', outbounds: tags, url:'https://www.gstatic.com/generate_204', tolerance:50});
  const proxy = config.outbounds.find(o => o.tag === 'proxy');
  if (proxy) proxy.outbounds = ['日本'].concat(tags);
  return config;
}`
		}
	}
	b, err := Config(f, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	groups, err := Groups(b)
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 2 {
		t.Fatalf("groups=%+v", groups)
	}
	if groups[0].Tag != "proxy" || groups[0].Name != "节点选择" {
		t.Fatalf("main group=%+v", groups[0])
	}
	if len(groups[0].Members) != 2 || groups[0].Members[0] != "日本" {
		t.Fatalf("proxy members=%v", groups[0].Members)
	}
	if groups[1].Tag != "日本" || groups[1].Type != "urltest" {
		t.Fatalf("region group=%+v", groups[1])
	}
}

func parseStrategyOutbounds(t *testing.T, raw []byte) (proxy []string, groups []string, hasAuto bool) {
	t.Helper()
	var cfg struct {
		Outbounds []struct {
			Type      string   `json:"type"`
			Tag       string   `json:"tag"`
			Outbounds []string `json:"outbounds"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	for _, outbound := range cfg.Outbounds {
		if outbound.Tag == "auto" {
			hasAuto = true
		}
		switch outbound.Type {
		case "selector", "urltest", "fallback":
			groups = append(groups, outbound.Tag)
		}
		if outbound.Tag == "proxy" {
			proxy = outbound.Outbounds
		}
	}
	return proxy, groups, hasAuto
}

func TestConfigUsesExplicitDirectHTTPClientForRemoteRuleSets(t *testing.T) {
	b, err := Config(state.DefaultFile(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var cfg struct {
		HTTPClients []struct {
			Tag string `json:"tag"`
		} `json:"http_clients"`
		Route struct {
			DefaultHTTPClient string           `json:"default_http_client"`
			RuleSet           []map[string]any `json:"rule_set"`
		} `json:"route"`
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		t.Fatal(err)
	}
	if len(cfg.HTTPClients) != 1 || cfg.HTTPClients[0].Tag != "rule-set-direct" {
		t.Fatalf("unexpected HTTP clients: %+v", cfg.HTTPClients)
	}
	if cfg.Route.DefaultHTTPClient != "rule-set-direct" {
		t.Fatalf("default HTTP client=%q", cfg.Route.DefaultHTTPClient)
	}
	for _, ruleSet := range cfg.Route.RuleSet {
		if _, legacy := ruleSet["download_detour"]; legacy {
			t.Fatalf("deprecated download_detour emitted: %+v", ruleSet)
		}
	}
}

func TestConfigTunUsesMixedStack(t *testing.T) {
	f := state.DefaultFile()
	f.Wanted = true
	f.Capture.Tun = true
	f = withNode(f, state.Node{
		ID: "n", Name: "n1", Protocol: "vless",
		Outbound: json.RawMessage(`{"type":"vless","server":"x.com","server_port":443,"uuid":"u"}`),
	})
	dataDir := t.TempDir()
	b, err := Config(f, dataDir)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	for _, need := range []string{`"type": "tun"`, `"stack": "mixed"`, `"auto_route": true`, `"mtu": 1500`} {
		if !strings.Contains(s, need) {
			t.Fatalf("missing %s", need)
		}
	}
	if strings.Contains(s, `"stack": "system"`) {
		t.Fatal("macOS TUN should not use system stack")
	}
}

func TestFullConfigIsReadOnly(t *testing.T) {
	raw := json.RawMessage(`{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"},"dns":{"servers":[{"type":"udp","tag":"dns","server":"1.1.1.1"}]},"experimental":{"clash_api":{"external_controller":"127.0.0.1:3456","secret":"original","store_selected":true}}}`)
	f := state.DefaultFile()
	f.Profiles = []state.ConfigProfile{{ID: "full", Name: "完整", Kind: state.ProfileKindSubscription, Config: raw}}
	f.ActiveConfigID = "full"
	b, err := Config(f, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != string(raw) {
		t.Fatalf("full profile changed:\nwant %s\n got %s", raw, b)
	}
}

func TestFullConfigRejectsNonArrayOutbounds(t *testing.T) {
	f := state.DefaultFile()
	f.Profiles = []state.ConfigProfile{{ID: "full", Kind: state.ProfileKindSubscription, Config: json.RawMessage(`{"outbounds":{"type":"direct"}}`)}}
	f.ActiveConfigID = "full"
	if _, err := Config(f, t.TempDir()); err == nil {
		t.Fatal("non-array outbounds should be rejected")
	}
}

func TestImportedInboundCapabilitiesRequireLoopbackMixed(t *testing.T) {
	f := state.DefaultFile()
	f.Profiles = []state.ConfigProfile{{ID: "full", Kind: state.ProfileKindSubscription, Config: json.RawMessage(`{"outbounds":[{"type":"direct","tag":"direct"}],"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":7890},{"type":"tun"}]}`)}}
	f.ActiveConfigID = "full"
	caps := ImportedInboundCapabilities(f)
	if !caps.SystemProxy || caps.MixedPort != 7890 || !caps.Tun {
		t.Fatalf("caps=%+v", caps)
	}
	f.Profiles[0].Config = json.RawMessage(`{"outbounds":[{"type":"direct","tag":"direct"}],"inbounds":[{"type":"mixed","listen":"0.0.0.0","listen_port":7890}]}`)
	if ImportedInboundCapabilities(f).SystemProxy {
		t.Fatal("non-loopback mixed inbound must not enable system proxy")
	}
}

func TestImportedInboundCapabilitiesPreserveLoopbackAddress(t *testing.T) {
	f := state.DefaultFile()
	f.Profiles = []state.ConfigProfile{{ID: "full", Kind: state.ProfileKindSubscription, Config: json.RawMessage(`{"outbounds":[{"type":"direct","tag":"direct"}],"inbounds":[{"type":"mixed","listen":"::1","listen_port":7890}]}`)}}
	f.ActiveConfigID = "full"
	caps := ImportedInboundCapabilities(f)
	if !caps.SystemProxy || caps.MixedListen != "::1" || caps.MixedPort != 7890 {
		t.Fatalf("caps=%+v", caps)
	}
}

func TestNodeScriptPreservesSourceOwnership(t *testing.T) {
	f := state.DefaultFile()
	f.Profiles[0].Sources = []state.ConfigSource{
		{ID: "one", URL: "https://one.example", Nodes: []state.Node{{ID: "one-node", Name: "one", Outbound: json.RawMessage(`{"type":"direct"}`)}}},
		{ID: "two", URL: "https://two.example", Nodes: []state.Node{{ID: "two-node", Name: "two", Outbound: json.RawMessage(`{"type":"direct"}`)}}},
	}
	f.Profiles[0].Script = `function transform(nodes) { return nodes.filter(n => n.id === "two-node"); }`
	b, err := Config(f, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	config := string(b)
	if strings.Contains(config, "one.example · one") || !strings.Contains(config, "two.example · two") {
		t.Fatalf("source ownership was not preserved in render: %s", config)
	}

	f.Profiles[0].Script = `function transform(nodes) { return [...nodes, {...nodes[0], id: "invented"}]; }`
	if _, err := Config(f, t.TempDir()); err == nil || (!strings.Contains(err.Error(), "不能创建没有来源") && !strings.Contains(err.Error(), "未知节点 id")) {
		t.Fatalf("unknown source node was accepted: %v", err)
	}
}

func TestCompileRuleReject(t *testing.T) {
	m := compileRule(state.Rule{Match: "domain_keyword", Value: "ads", Action: "reject"})
	if m["action"] != "reject" {
		t.Fatalf("%v", m)
	}
}

func TestSingBoxValidationIfAvailable(t *testing.T) {
	bin, err := bundledSingBox()
	if err != nil {
		bin, err = exec.LookPath("sing-box")
	}
	if err != nil {
		cands := []string{"/opt/homebrew/bin/sing-box"}
		if home, homeErr := os.UserHomeDir(); homeErr == nil {
			cands = append(cands, home+"/bin/sing-box")
		}
		for _, p := range cands {
			if st, statErr := os.Stat(p); statErr == nil && !st.IsDir() {
				bin = p
				err = nil
				break
			}
		}
	}
	if err != nil {
		t.Skip("本地环境未检测到可用的 sing-box 二进制，跳过集成验证测试")
	}
	if !isSingBoxAtLeast114(bin) {
		t.Skipf("检测到的 sing-box 二进制 (%s) 版本低于 1.14.0，跳过针对 1.14+ 语法的集成校验测试", bin)
	}

	f := state.DefaultFile()
	f.Settings.MixedPort = 29080
	f.Settings.ClashPort = 29090
	f = withNode(f, state.Node{
		ID: "n", Name: "n1", Protocol: "vless",
		Outbound: json.RawMessage(`{"type":"vless","server":"1.1.1.1","server_port":443,"uuid":"00000000-0000-0000-0000-000000000000"}`),
	})
	dataDir := t.TempDir()
	b, err := Config(f, dataDir)
	if err != nil {
		t.Fatal(err)
	}
	tmpCfg := filepath.Join(dataDir, "config.json")
	_ = os.WriteFile(tmpCfg, b, 0o600)

	cmd := exec.Command(bin, "check", "-c", tmpCfg)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("sing-box check failed: %v, output: %s", err, string(out))
	}

	// Test real sing-box run runtime stability
	runCmd := exec.Command(bin, "run", "-c", tmpCfg)
	var runOutput bytes.Buffer
	runCmd.Stdout = &runOutput
	runCmd.Stderr = &runOutput
	if err := runCmd.Start(); err != nil {
		t.Fatalf("failed to start sing-box: %v", err)
	}
	defer func() {
		if runCmd.Process != nil {
			_ = runCmd.Process.Kill()
		}
	}()

	done := make(chan error, 1)
	go func() {
		done <- runCmd.Wait()
	}()

	select {
	case err := <-done:
		t.Fatalf("sing-box exited prematurely: %v: %s", err, runOutput.String())
	case <-time.After(1 * time.Second):
		// sing-box is running stably!
	}
}

func TestBundledSingBoxChecks500Nodes(t *testing.T) {
	bin, err := bundledSingBox()
	if err != nil {
		t.Skip("未找到构建产物中的 sing-box")
	}
	f := state.DefaultFile()
	f.Settings.MixedPort = 28080
	f.Settings.ClashPort = 28090
	for i := 0; i < 500; i++ {
		f.Profiles[0].ManualNodes = append(f.Profiles[0].ManualNodes, state.Node{
			ID: fmt.Sprintf("n-%d", i), Name: fmt.Sprintf("n-%d", i), Protocol: "vless",
			Outbound: json.RawMessage(`{"type":"vless","server":"1.1.1.1","server_port":443,"uuid":"00000000-0000-0000-0000-000000000000"}`),
		})
	}
	b, err := Config(f, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(t.TempDir(), "500-nodes.json")
	if err := os.WriteFile(cfg, b, 0o600); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command(bin, "check", "-c", cfg).CombinedOutput(); err != nil {
		t.Fatalf("bundled sing-box rejected 500 nodes: %v: %s", err, out)
	}
}

func TestBundledSingBoxServes100ConcurrentProxyConnections(t *testing.T) {
	bin, err := bundledSingBox()
	if err != nil {
		t.Skip("未找到构建产物中的 sing-box")
	}
	mixedPort := freeTCPPort(t)
	clashPort := freeTCPPort(t)
	f := state.DefaultFile()
	f.Settings.MixedPort = mixedPort
	f.Settings.ClashPort = clashPort
	dataDir := t.TempDir()
	config, err := Config(f, dataDir)
	if err != nil {
		t.Fatal(err)
	}
	// The test sandbox cannot subscribe to macOS network-interface updates. Disable
	// only the two host-observation features in this test fixture so the proxy data
	// path can be exercised without changing the product configuration.
	var document map[string]any
	if err := json.Unmarshal(config, &document); err != nil {
		t.Fatal(err)
	}
	route, ok := document["route"].(map[string]any)
	if !ok {
		t.Fatal("rendered configuration has no route block")
	}
	route["auto_detect_interface"] = false
	delete(route, "find_process")
	config, err = json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dataDir, "concurrent.json")
	if err := os.WriteFile(path, config, 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(bin, "run", "-c", path)
	var output lockedBuffer
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	processExited := false
	defer func() {
		if !processExited {
			_ = cmd.Process.Kill()
			<-done
		}
	}()
	if err := waitForTCP("127.0.0.1:"+strconv.Itoa(mixedPort), func() string { return output.String() }); err != nil {
		if strings.Contains(err.Error(), "listen network update: operation not permitted") {
			t.Skipf("宿主环境禁止 sing-box 监听网络变化，跳过真实代理并发验证：%v", err)
		}
		t.Fatal(err)
	}

	const active = 100
	started := make(chan struct{}, active)
	release := make(chan struct{})
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started <- struct{}{}
		<-release
		_, _ = w.Write([]byte("ok"))
	}))
	defer backend.Close()
	proxyURL, err := url.Parse("http://127.0.0.1:" + strconv.Itoa(mixedPort))
	if err != nil {
		t.Fatal(err)
	}
	transport := &http.Transport{Proxy: http.ProxyURL(proxyURL), MaxConnsPerHost: active, MaxIdleConns: active}
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	defer transport.CloseIdleConnections()
	errs := make(chan error, active)
	var wg sync.WaitGroup
	for i := 0; i < active; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, err := client.Get(backend.URL)
			if err == nil {
				_ = resp.Body.Close()
			}
			errs <- err
		}()
	}
	for i := 0; i < active; i++ {
		select {
		case <-started:
		case err := <-done:
			processExited = true
			t.Fatalf("sing-box exited with %v: %s", err, output.String())
		case <-time.After(8 * time.Second):
			t.Fatalf("only %d/%d proxy requests became active", i, active)
		}
	}
	close(release)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("proxied request failed: %v", err)
		}
	}
}

func freeTCPPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.String()
}

func waitForTCP(address string, diagnostics func() string) error {
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", address, 100*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("sing-box did not listen on %s: %s", address, diagnostics())
}

func bundledSingBox() (string, error) {
	root, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		candidate := filepath.Join(root, "build", "Aster.app", "Contents", "Resources", "sing-box")
		if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
			return candidate, nil
		}
		coresDir := filepath.Join(root, "vendor", "cores")
		if entries, err := os.ReadDir(coresDir); err == nil {
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), "sing-box") && !entry.IsDir() {
					full := filepath.Join(coresDir, entry.Name())
					if st, err := os.Stat(full); err == nil && st.Mode()&0o111 != 0 {
						return full, nil
					}
				}
			}
		}
		parent := filepath.Dir(root)
		if parent == root {
			break
		}
		root = parent
	}
	return "", os.ErrNotExist
}

func isSingBoxAtLeast114(bin string) bool {
	out, err := exec.Command(bin, "version").Output()
	if err != nil {
		return false
	}
	fields := strings.Fields(string(out))
	for i, f := range fields {
		if f == "version" && i+1 < len(fields) {
			ver := fields[i+1]
			parts := strings.Split(ver, ".")
			if len(parts) >= 2 {
				major, err1 := strconv.Atoi(parts[0])
				minor, err2 := strconv.Atoi(parts[1])
				if err1 == nil && err2 == nil {
					return major > 1 || (major == 1 && minor >= 14)
				}
			}
		}
	}
	return false
}

func TestConfigScriptFailSafeProtections(t *testing.T) {
	f := state.DefaultFile()
	p := f.ActiveProfile()
	if p == nil {
		t.Fatal("need active profile")
	}
	f.ClashSecret = "my-secret"
	f.Settings.ClashPort = 2090
	f.Scripts = []state.ScriptItem{
		{
			ID:   "custom-script",
			Name: "用户自定义脚本",
			Kind: "config",
			// 用户脚本重写了 outbounds 并完全没写 experimental 和 inbounds
			Content: `function main(config) {
				config.outbounds = [
					{ type: "direct", tag: "direct" },
					{ type: "selector", tag: "🚀 自定义选择", outbounds: ["direct"] }
				];
				delete config.experimental;
				delete config.inbounds;
				return config;
			}`,
		},
	}
	for i := range f.Profiles {
		if f.Profiles[i].ID == p.ID {
			f.Profiles[i].ScriptID = "custom-script"
		}
	}

	b, err := Config(f, t.TempDir())
	if err != nil {
		t.Fatalf("Config failed: %v", err)
	}

	var parsed struct {
		Inbounds     []map[string]any `json:"inbounds"`
		Outbounds    []map[string]any `json:"outbounds"`
		Experimental struct {
			ClashAPI map[string]any `json:"clash_api"`
		} `json:"experimental"`
	}
	if err := json.Unmarshal(b, &parsed); err != nil {
		t.Fatalf("Unmarshal failed: %v", err)
	}

	// 1. 验证 Fail-Safe 成功补充 clash_api
	controller, ok := parsed.Experimental.ClashAPI["external_controller"].(string)
	if !ok || controller != "127.0.0.1:2090" {
		t.Fatalf("fail-safe did not restore clash external_controller: %v", parsed.Experimental.ClashAPI)
	}
	if sec := parsed.Experimental.ClashAPI["secret"]; sec != "my-secret" {
		t.Fatalf("fail-safe secret mismatch: %v", sec)
	}

	// 2. 验证 Fail-Safe 成功补充 mixed-in
	hasMixed := false
	for _, in := range parsed.Inbounds {
		if in["type"] == "mixed" {
			hasMixed = true
			break
		}
	}
	if !hasMixed {
		t.Fatal("fail-safe did not restore mixed inbound")
	}

	// 3. 验证 Fail-Safe 成功补充 proxy selector 并映射首个 selector
	hasProxy := false
	for _, out := range parsed.Outbounds {
		if out["tag"] == "proxy" && out["type"] == "selector" {
			hasProxy = true
			outs, _ := out["outbounds"].([]any)
			if len(outs) == 0 || outs[0] != "🚀 自定义选择" {
				t.Fatalf("proxy selector outbounds mismatch: %v", outs)
			}
			break
		}
	}
	if !hasProxy {
		t.Fatal("fail-safe did not inject proxy selector alias")
	}
}

func TestConfigNewProtocols_TransformAndGroups(t *testing.T) {
	f := state.DefaultFile()
	p := f.ActiveProfile()
	if p == nil {
		t.Fatal("need active profile")
	}
	f.Profiles[0].ManualNodes = []state.Node{
		{
			ID: "wg-1", Name: "wg-node", Protocol: "wireguard",
			Outbound: json.RawMessage(`{"type":"wireguard","server":"198.51.100.1","server_port":51820,"private_key":"priv","peer_public_key":"pub","local_address":["172.16.0.2/32"],"reserved":[0,0,0],"mtu":1420}`),
		},
		{
			ID: "hy2-1", Name: "hy2-node", Protocol: "hysteria2",
			Outbound: json.RawMessage(`{"type":"hysteria2","server":"hy2.example.com","server_port":8443,"password":"pass","up_mbps":100,"down_mbps":500,"obfs":{"type":"salamander","password":"sec"},"tls":{"enabled":true,"server_name":"example.com"}}`),
		},
		{
			ID: "tuic-1", Name: "tuic-node", Protocol: "tuic",
			Outbound: json.RawMessage(`{"type":"tuic","server":"example.com","server_port":8443,"uuid":"11111111-1111-1111-1111-111111111111","password":"pass","congestion_controller":"bbr","congestion_control":"bbr","udp_relay_mode":"native","zero_rtt_handshake":true,"heartbeat":"10s","tls":{"enabled":true,"server_name":"example.com"}}`),
		},
		{
			ID: "st-1", Name: "st-node", Protocol: "shadowtls",
			Outbound: json.RawMessage(`{"type":"shadowtls","server":"1.2.3.4","server_port":443,"version":3,"password":"pass","strict_mode":true,"tls":{"enabled":true,"server_name":"gateway.icloud.com"}}`),
		},
	}

	dataDir := t.TempDir()
	b, err := Config(f, dataDir)
	if err != nil {
		t.Fatalf("Config failed: %v", err)
	}

	var parsed struct {
		Endpoints []map[string]any `json:"endpoints"`
		Outbounds []map[string]any `json:"outbounds"`
	}
	if err := json.Unmarshal(b, &parsed); err != nil {
		t.Fatalf("unmarshal config: %v", err)
	}

	// 1. Verify WireGuard is in endpoints, not outbounds
	if len(parsed.Endpoints) != 1 {
		t.Fatalf("expected 1 endpoint, got %d", len(parsed.Endpoints))
	}
	ep := parsed.Endpoints[0]
	if ep["type"] != "wireguard" || ep["tag"] != "wg-node" {
		t.Fatalf("unexpected endpoint: %+v", ep)
	}
	peers, ok := ep["peers"].([]any)
	if !ok || len(peers) != 1 {
		t.Fatalf("expected 1 peer, got %+v", ep["peers"])
	}
	peer := peers[0].(map[string]any)
	if peer["address"] != "198.51.100.1" || peer["port"] != float64(51820) || peer["public_key"] != "pub" {
		t.Fatalf("unexpected peer config: %+v", peer)
	}

	// Check WireGuard is not in outbounds
	for _, ob := range parsed.Outbounds {
		if ob["type"] == "wireguard" {
			t.Fatalf("wireguard must not be in outbounds: %+v", ob)
		}
	}

	// 2. Verify TUIC has congestion_control and NOT congestion_controller
	var tuicFound bool
	for _, ob := range parsed.Outbounds {
		if ob["type"] == "tuic" {
			tuicFound = true
			if ob["congestion_control"] != "bbr" {
				t.Fatalf("expected congestion_control bbr, got %v", ob["congestion_control"])
			}
			if _, has := ob["congestion_controller"]; has {
				t.Fatalf("congestion_controller should be sanitized out: %+v", ob)
			}
		}
	}
	if !tuicFound {
		t.Fatal("tuic outbound not found")
	}

	// 3. Verify ShadowTLS does not have strict_mode
	var stFound bool
	for _, ob := range parsed.Outbounds {
		if ob["type"] == "shadowtls" {
			stFound = true
			if _, has := ob["strict_mode"]; has {
				t.Fatalf("strict_mode must be sanitized out: %+v", ob)
			}
		}
	}
	if !stFound {
		t.Fatal("shadowtls outbound not found")
	}

	// 4. Verify Groups includes all 4 nodes in proxy selector leaves
	groups, err := Groups(b)
	if err != nil {
		t.Fatalf("Groups failed: %v", err)
	}
	if len(groups) == 0 {
		t.Fatal("expected at least 1 group")
	}
	proxyGroup := groups[0]
	expectedLeaves := map[string]bool{
		"wg-node":   false,
		"hy2-node":  false,
		"tuic-node": false,
		"st-node":   false,
	}
	for _, leaf := range proxyGroup.LeafTags {
		if _, ok := expectedLeaves[leaf]; ok {
			expectedLeaves[leaf] = true
		}
	}
	for tag, found := range expectedLeaves {
		if !found {
			t.Fatalf("leaf tag %s was not found in proxy group leaves: %v", tag, proxyGroup.LeafTags)
		}
	}
}

func TestSingBoxCheck_AllNewProtocols(t *testing.T) {
	bin, err := exec.LookPath("sing-box")
	if err != nil {
		cands := []string{"/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"}
		for _, c := range cands {
			if st, statErr := os.Stat(c); statErr == nil && !st.IsDir() {
				bin = c
				err = nil
				break
			}
		}
	}
	if err != nil {
		t.Skip("sing-box binary not found, skipping check")
	}

	testCfg := map[string]any{
		"endpoints": []any{
			map[string]any{
				"type":        "wireguard",
				"tag":         "wg-node",
				"address":     []string{"172.16.0.2/32"},
				"private_key": "a2V5MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODk=",
				"peers": []any{
					map[string]any{
						"address":     "198.51.100.1",
						"port":        51820,
						"public_key":  "a2V5MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODk=",
						"allowed_ips": []string{"0.0.0.0/0", "::/0"},
						"reserved":    []int{0, 0, 0},
					},
				},
				"mtu": 1420,
			},
		},
		"outbounds": []any{
			map[string]any{
				"type": "direct",
				"tag":  "direct",
			},
			map[string]any{
				"type":      "selector",
				"tag":       "proxy",
				"outbounds": []string{"wg-node", "hy2-node", "tuic-node", "st-node"},
			},
			map[string]any{
				"type":        "hysteria2",
				"tag":         "hy2-node",
				"server":      "hy2.example.com",
				"server_port": 8443,
				"password":    "mypassword",
				"up_mbps":     100,
				"down_mbps":   500,
				"obfs": map[string]any{
					"type":     "salamander",
					"password": "secret",
				},
				"tls": map[string]any{
					"enabled":     true,
					"server_name": "example.com",
				},
			},
			map[string]any{
				"type":               "tuic",
				"tag":                "tuic-node",
				"server":             "example.com",
				"server_port":        8443,
				"uuid":               "11111111-1111-1111-1111-111111111111",
				"password":           "my-pass",
				"congestion_control": "bbr",
				"udp_relay_mode":     "native",
				"zero_rtt_handshake": true,
				"heartbeat":          "10s",
				"tls": map[string]any{
					"enabled":     true,
					"server_name": "example.com",
				},
			},
			map[string]any{
				"type":        "shadowtls",
				"tag":         "st-node",
				"server":      "1.2.3.4",
				"server_port": 443,
				"version":     3,
				"password":    "secret",
				"tls": map[string]any{
					"enabled":     true,
					"server_name": "gateway.icloud.com",
				},
			},
		},
	}

	b, err := json.Marshal(testCfg)
	if err != nil {
		t.Fatal(err)
	}

	tmpFile := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(tmpFile, b, 0o600); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command(bin, "check", "-c", tmpFile)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("sing-box check failed: %v, output: %s", err, string(out))
	}
}
