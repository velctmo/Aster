package script

import (
	"encoding/json"
	"strings"
	"testing"

	"aster/internal/state"
)

func TestTransformFiltersAndRenamesNodes(t *testing.T) {
	nodes := []state.Node{{ID: "a", Name: "香港", Outbound: json.RawMessage(`{"type":"vless"}`)}, {ID: "b", Name: "测试", Outbound: json.RawMessage(`{"type":"vless"}`)}}
	out, err := Transform(`function transform(nodes) { return nodes.filter(n => n.name !== "测试").map(n => ({...n, name: "优选 " + n.name})); }`, nodes, state.ConfigProfile{Kind: state.ProfileKindNodes})
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 1 || out[0].Name != "优选 香港" {
		t.Fatalf("out=%+v", out)
	}
}

func TestTransformRejectsDuplicateNodeIdentity(t *testing.T) {
	nodes := []state.Node{{ID: "a", Name: "香港", Outbound: json.RawMessage(`{"type":"vless"}`)}}
	_, err := Transform(`function transform(nodes) { return [nodes[0], nodes[0]]; }`, nodes, state.ConfigProfile{Kind: state.ProfileKindNodes})
	if err == nil || !strings.Contains(err.Error(), "重复节点 id") {
		t.Fatalf("duplicate identity was accepted: %v", err)
	}
}

func TestTransformRejectsChangingExistingNodeOutbound(t *testing.T) {
	nodes := []state.Node{{ID: "a", Name: "香港", Outbound: json.RawMessage(`{"type":"vless","server":"source.example"}`)}}
	_, err := Transform(`function transform(nodes) { return [{...nodes[0], outbound: {type: "direct", tag: "bypass"}}]; }`, nodes, state.ConfigProfile{Kind: state.ProfileKindNodes})
	if err == nil || !strings.Contains(err.Error(), "不能修改既有节点的出站内容") {
		t.Fatalf("outbound rewrite was accepted: %v", err)
	}
}

func TestTransformAllowsEquivalentOutboundWithDifferentKeyOrder(t *testing.T) {
	nodes := []state.Node{{ID: "a", Name: "香港", Outbound: json.RawMessage(`{"server":"source.example","type":"vless"}`)}}
	out, err := Transform(`function transform(nodes) { return nodes.map(n => ({...n, name: "优选 " + n.name})); }`, nodes, state.ConfigProfile{Kind: state.ProfileKindNodes})
	if err != nil || len(out) != 1 || out[0].Name != "优选 香港" {
		t.Fatalf("equivalent outbound was rejected: out=%+v err=%v", out, err)
	}
}

func TestTransformInterruptsInfiniteLoop(t *testing.T) {
	_, err := Transform(`function transform(nodes) { while (true) {} }`, nil, state.ConfigProfile{Kind: state.ProfileKindNodes})
	if err == nil || !strings.Contains(err.Error(), "执行超时") {
		t.Fatalf("infinite script was not interrupted: %v", err)
	}
}

func TestTransformConfigAddsStrategyGroup(t *testing.T) {
	in := json.RawMessage(`{"outbounds":[{"type":"vless","tag":"node"}]}`)
	out, err := TransformConfig(`function transformConfig(config) { config.outbounds.push({type:"selector",tag:"all",outbounds:["node"]}); return config }`, in, state.ConfigProfile{Kind: state.ProfileKindSubscription})
	if err != nil || !strings.Contains(string(out), `"tag":"all"`) { t.Fatalf("out=%s err=%v", out, err) }
}

func TestTransformConfigSupportsMainEntry(t *testing.T) {
	in := json.RawMessage(`{"outbounds":[{"type":"vless","tag":"node"}]}`)
	out, err := TransformConfig(`function main(config) { config.outbounds.push({type:"selector",tag:"ai",outbounds:["node"]}); return config; }`, in, state.ConfigProfile{Kind: state.ProfileKindSubscription})
	if err != nil || !strings.Contains(string(out), `"tag":"ai"`) { t.Fatalf("out=%s err=%v", out, err) }
}

func TestTransformConfigFullFeaturedRuleSetsTemplate(t *testing.T) {
	template := `
function main(config) {
  config = config || {};
  config.outbounds = config.outbounds || [];
  config.route = config.route || {};
  config.route.rule_set = config.route.rule_set || [];
  config.route.rules = config.route.rules || [];

  const reserved = new Set(['direct', 'proxy', 'auto', 'reject', 'block', 'dns']);
  const allNodeTags = config.outbounds
    .filter(function(o) {
      return o && o.tag && !reserved.has(o.tag) && !['selector', 'urltest', 'fallback'].includes(o.type);
    })
    .map(function(o) { return o.tag; });

  if (!allNodeTags.length) return config;

  const regions = [
    { tag: '香港', re: /香港|HK|Hong\s*Kong|🇭🇰/i },
    { tag: '日本', re: /日本|JP|Japan|东京|🇯🇵/i },
    { tag: '台湾', re: /台湾|台灣|TW|Taiwan|🇹🇼/i },
    { tag: '新加坡', re: /新加坡|SG|Singapore|🇸🇬/i },
    { tag: '美国', re: /美国|美國|US|United\s*States|🇺🇸/i }
  ];

  const regionalGroups = [];
  for (var i = 0; i < regions.length; i++) {
    var reg = regions[i];
    var matched = allNodeTags.filter(function(t) { return reg.re.test(t); });
    if (matched.length > 0) {
      regionalGroups.push({
        type: 'urltest',
        tag: reg.tag,
        outbounds: matched,
        url: 'https://www.gstatic.com/generate_204',
        interval: '3m',
        tolerance: 50
      });
    }
  }

  const autoGroup = {
    type: 'urltest',
    tag: '自动优选',
    outbounds: allNodeTags,
    url: 'https://www.gstatic.com/generate_204',
    interval: '3m',
    tolerance: 50
  };

  const groupOptions = ['自动优选']
    .concat(regionalGroups.map(function(g) { return g.tag; }))
    .concat(allNodeTags);

  const appGroups = [
    { type: 'selector', tag: 'AI 平台', outbounds: groupOptions, default: '自动优选' },
    { type: 'selector', tag: '国际媒体', outbounds: groupOptions, default: '自动优选' },
    { type: 'selector', tag: 'Telegram', outbounds: groupOptions, default: '自动优选' },
    { type: 'selector', tag: 'GitHub', outbounds: ['direct'].concat(groupOptions), default: '自动优选' }
  ];

  const newGroups = [autoGroup].concat(regionalGroups).concat(appGroups);
  const newGroupTags = newGroups.map(function(g) { return g.tag; });

  config.outbounds = config.outbounds.filter(function(o) { return !newGroupTags.includes(o.tag); });
  var proxy = config.outbounds.find(function(o) { return o.tag === 'proxy'; });
  if (proxy) {
    proxy.outbounds = ['自动优选']
      .concat(regionalGroups.map(function(g) { return g.tag; }))
      .concat(allNodeTags);
    proxy.default = '自动优选';
  }
  var proxyIdx = Math.max(0, config.outbounds.findIndex(function(o) { return o.tag === 'proxy'; }));
  config.outbounds.splice.apply(config.outbounds, [proxyIdx + 1, 0].concat(newGroups));

  const ruleSetBase = 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/';
  const ruleSetsToAdd = [
    { tag: 'geosite-openai', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/openai.srs', download_detour: 'proxy' },
    { tag: 'geosite-anthropic', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/anthropic.srs', download_detour: 'proxy' },
    { tag: 'geosite-youtube', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/youtube.srs', download_detour: 'proxy' },
    { tag: 'geosite-netflix', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/netflix.srs', download_detour: 'proxy' },
    { tag: 'geosite-telegram', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/telegram.srs', download_detour: 'proxy' },
    { tag: 'geoip-telegram', type: 'remote', format: 'binary', url: ruleSetBase + 'geoip/telegram.srs', download_detour: 'proxy' },
    { tag: 'geosite-github', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/github.srs', download_detour: 'proxy' },
    { tag: 'geosite-ads', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/category-ads-all.srs', download_detour: 'proxy' },
    { tag: 'geosite-cn', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/cn.srs', download_detour: 'direct' },
    { tag: 'geoip-cn', type: 'remote', format: 'binary', url: ruleSetBase + 'geoip/cn.srs', download_detour: 'direct' }
  ];

  const existingRSTags = new Set(config.route.rule_set.map(function(rs) { return rs.tag; }));
  for (var j = 0; j < ruleSetsToAdd.length; j++) {
    if (!existingRSTags.has(ruleSetsToAdd[j].tag)) {
      config.route.rule_set.push(ruleSetsToAdd[j]);
    }
  }

  const businessRules = [
    { rule_set: 'geosite-ads', action: 'reject' },
    { rule_set: ['geosite-openai', 'geosite-anthropic'], outbound: 'AI 平台' },
    { rule_set: ['geosite-youtube', 'geosite-netflix'], outbound: '国际媒体' },
    { rule_set: ['geosite-telegram', 'geoip-telegram'], outbound: 'Telegram' },
    { rule_set: 'geosite-github', outbound: 'GitHub' },
    { rule_set: ['geosite-cn', 'geoip-cn'], outbound: 'direct' }
  ];

  config.route.rules = businessRules.concat(config.route.rules);
  config.route.final = 'proxy';

  return config;
}
`
	base := json.RawMessage(`{
		"outbounds": [
			{"type": "selector", "tag": "proxy", "outbounds": ["HK 01", "JP 01", "US 01"]},
			{"type": "vless", "tag": "HK 01"},
			{"type": "vless", "tag": "JP 01"},
			{"type": "vless", "tag": "US 01"},
			{"type": "direct", "tag": "direct"}
		],
		"route": {"rules": []}
	}`)

	out, err := TransformConfig(template, base, state.ConfigProfile{Kind: state.ProfileKindSubscription})
	if err != nil {
		t.Fatalf("TransformConfig failed: %v", err)
	}

	var res struct {
		Outbounds []struct {
			Tag  string   `json:"tag"`
			Type string   `json:"type"`
			List []string `json:"outbounds"`
		} `json:"outbounds"`
		Route struct {
			RuleSet []struct {
				Tag string `json:"tag"`
			} `json:"rule_set"`
			Rules []map[string]any `json:"rules"`
		} `json:"route"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		t.Fatalf("Unmarshal result failed: %v", err)
	}

	// Verify rule_sets were added
	hasOpenAI := false
	hasAds := false
	for _, rs := range res.Route.RuleSet {
		if rs.Tag == "geosite-openai" {
			hasOpenAI = true
		}
		if rs.Tag == "geosite-ads" {
			hasAds = true
		}
	}
	if !hasOpenAI || !hasAds {
		t.Fatalf("Expected OpenAI and Ads rule_set in config, got %+v", res.Route.RuleSet)
	}

	// Verify app groups and regional groups exist
	tags := map[string]bool{}
	for _, o := range res.Outbounds {
		tags[o.Tag] = true
	}
	for _, expected := range []string{"自动优选", "香港", "日本", "美国", "AI 平台", "国际媒体", "Telegram", "GitHub"} {
		if !tags[expected] {
			t.Errorf("Expected outbound tag %q not found", expected)
		}
	}
}

func TestTransformConfigSmartFakeIPDNSTemplate(t *testing.T) {
	template := `
function main(config) {
  config = config || {};
  config.outbounds = config.outbounds || [];
  config.route = config.route || {};
  config.route.rules = config.route.rules || [];

  config.dns = {
    servers: [
      { tag: 'dns-remote', address: 'https://1.1.1.1/dns-query', detour: 'proxy' },
      { tag: 'dns-direct', address: 'https://223.5.5.5/dns-query', detour: 'direct' },
      { tag: 'dns-fakeip', address: 'fakeip' }
    ],
    rules: [
      { outbound: 'any', server: 'dns-direct' },
      { query_type: ['A', 'AAAA'], server: 'dns-fakeip' }
    ],
    fakeip: {
      enabled: true,
      inet4_range: '198.18.0.0/15'
    }
  };

  const dnsHijackRule = { protocol: 'dns', action: 'hijack-dns' };
  config.route.rules.unshift(dnsHijackRule);
  return config;
}
`
	base := json.RawMessage(`{"outbounds": [{"type": "vless", "tag": "node"}]}`)
	out, err := TransformConfig(template, base, state.ConfigProfile{Kind: state.ProfileKindSubscription})
	if err != nil {
		t.Fatalf("TransformConfig failed: %v", err)
	}

	var res struct {
		DNS struct {
			FakeIP struct {
				Enabled    bool   `json:"enabled"`
				Inet4Range string `json:"inet4_range"`
			} `json:"fakeip"`
		} `json:"dns"`
		Route struct {
			Rules []struct {
				Protocol string `json:"protocol"`
				Action   string `json:"action"`
			} `json:"rules"`
		} `json:"route"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		t.Fatalf("Unmarshal result failed: %v", err)
	}
	if !res.DNS.FakeIP.Enabled || res.DNS.FakeIP.Inet4Range != "198.18.0.0/15" {
		t.Fatalf("FakeIP not properly set: %+v", res.DNS.FakeIP)
	}
	if len(res.Route.Rules) == 0 || res.Route.Rules[0].Action != "hijack-dns" {
		t.Fatalf("DNS hijack rule not set at start: %+v", res.Route.Rules)
	}
}

func TestTransformConfigNodeOptimizerTemplate(t *testing.T) {
	template := `
function main(config) {
  config = config || {};
  config.outbounds = config.outbounds || [];

  const tlsProtocols = new Set(['vmess', 'vless', 'trojan']);

  for (var i = 0; i < config.outbounds.length; i++) {
    var out = config.outbounds[i];
    if (!out || !out.type) continue;

    if (out.tag && !['direct', 'proxy', 'auto', 'reject', 'block', 'dns'].includes(out.tag)) {
      out.tag = out.tag
        .replace(/\[\d+(\.\d+)?x\]/gi, '')
        .replace(/\|\s*倍率[:：]?\s*\d+(\.\d+)?/gi, '')
        .replace(/(官网|地址|群组)[:：]?\s*\S+/gi, '')
        .trim();
    }

    if (tlsProtocols.has(out.type)) {
      out.tls = out.tls || {};
      out.tls.enabled = true;
      out.tls.utls = { enabled: true, fingerprint: 'chrome' };
      out.multiplex = { enabled: true, protocol: 'h2mux', max_connections: 4, min_streams: 4 };
    }
  }

  return config;
}
`
	base := json.RawMessage(`{
		"outbounds": [
			{"type": "selector", "tag": "proxy", "outbounds": ["香港 01"]},
			{"type": "vless", "tag": "香港 01 [1.5x] | 倍率:1.5 官网:abc.com"}
		]
	}`)
	out, err := TransformConfig(template, base, state.ConfigProfile{Kind: state.ProfileKindSubscription})
	if err != nil {
		t.Fatalf("TransformConfig failed: %v", err)
	}

	var res struct {
		Outbounds []struct {
			Tag string `json:"tag"`
			TLS struct {
				UTLS struct {
					Fingerprint string `json:"fingerprint"`
				} `json:"utls"`
			} `json:"tls"`
			Multiplex struct {
				Enabled  bool   `json:"enabled"`
				Protocol string `json:"protocol"`
			} `json:"multiplex"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		t.Fatalf("Unmarshal result failed: %v", err)
	}

	cleanedNode := res.Outbounds[1]
	if cleanedNode.Tag != "香港 01" {
		t.Fatalf("Node tag not cleaned, got %q", cleanedNode.Tag)
	}
	if cleanedNode.TLS.UTLS.Fingerprint != "chrome" {
		t.Fatalf("uTLS fingerprint not chrome, got %q", cleanedNode.TLS.UTLS.Fingerprint)
	}
	if !cleanedNode.Multiplex.Enabled || cleanedNode.Multiplex.Protocol != "h2mux" {
		t.Fatalf("multiplex not enabled or protocol not h2mux: %+v", cleanedNode.Multiplex)
	}
}

func TestTransformConfigGeneratedFullFeatures(t *testing.T) {
	script := `
function main(config) {
  config = config || {};
  config.outbounds = config.outbounds || [];
  config.route = config.route || {};
  config.route.rules = config.route.rules || [];

  const reserved = new Set(['direct', 'proxy', 'auto', 'reject', 'block', 'dns']);

  // 1. 净化节点名称
  for (var i = 0; i < config.outbounds.length; i++) {
    var out = config.outbounds[i];
    if (out && out.tag && !reserved.has(out.tag) && !['selector', 'urltest', 'fallback'].includes(out.type)) {
      out.tag = out.tag
        .replace(/\[\d+(\.\d+)?x\]/gi, '')
        .replace(/\|\s*倍率[:：]?\s*\d+(\.\d+)?/gi, '')
        .replace(/(官网|地址|群组|频道|发布页)[:：]?\s*\S+/gi, '')
        .replace(/\s+/g, ' ')
        .trim();
    }
  }

  // 2. 协议优化与指纹伪装
  const tlsProtocols = new Set(['vmess', 'vless', 'trojan', 'shadowtls']);
  const muxProtocols = new Set(['vmess', 'vless', 'trojan']);
  for (var i = 0; i < config.outbounds.length; i++) {
    var out = config.outbounds[i];
    if (!out || !out.type) continue;
    if (tlsProtocols.has(out.type)) {
      out.tls = out.tls || {};
      out.tls.enabled = true;
      out.tls.utls = { enabled: true, fingerprint: 'chrome' };
    }
    if (muxProtocols.has(out.type)) {
      out.multiplex = { enabled: true, protocol: 'h2mux', max_connections: 4, min_streams: 4, padding: true };
    }
  }

  // 3. 智能 FakeIP 与双轨 DoH
  config.dns = {
    servers: [
      { tag: 'dns-remote', address: 'https://1.1.1.1/dns-query', detour: 'proxy' },
      { tag: 'dns-direct', address: 'https://223.5.5.5/dns-query', detour: 'direct' },
      { tag: 'dns-fakeip', address: 'fakeip' },
      { tag: 'dns-block', address: 'rcode://success' }
    ],
    rules: [
      { outbound: 'any', server: 'dns-direct' },
      { rule_set: 'geosite-ads', server: 'dns-block' },
      { rule_set: 'geosite-cn', server: 'dns-direct' },
      { query_type: ['A', 'AAAA'], server: 'dns-fakeip' }
    ],
    fakeip: { enabled: true, inet4_range: '198.18.0.0/15' },
    independent_cache: true
  };
  const dnsHijackRule = { protocol: 'dns', action: 'hijack-dns' };
  if (!config.route.rules.some(function(r) { return r.protocol === 'dns'; })) {
    config.route.rules.unshift(dnsHijackRule);
  }

  // 4. 提取节点与地区测速组
  const allNodeTags = config.outbounds
    .filter(function(o) {
      return o && o.tag && !reserved.has(o.tag) && !['selector', 'urltest', 'fallback'].includes(o.type);
    })
    .map(function(o) { return o.tag; });

  if (!allNodeTags.length) return config;

  const extraGroups = [
    { type: 'urltest', tag: '自动选择', outbounds: allNodeTags, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 }
  ];

  const hkNodes = allNodeTags.filter(function(t) { return /香港|HK|Hong\s*Kong|🇭🇰/i.test(t); });
  if (hkNodes.length) extraGroups.push({ type: 'urltest', tag: '香港', outbounds: hkNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });
  const jpNodes = allNodeTags.filter(function(t) { return /日本|JP|Japan|东京|大阪|🇯🇵/i.test(t); });
  if (jpNodes.length) extraGroups.push({ type: 'urltest', tag: '日本', outbounds: jpNodes, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });

  // 5. 业务场景策略组
  extraGroups.push({ type: 'selector', tag: 'AI 平台', outbounds: ['自动选择'].concat(allNodeTags), default: '自动选择' });
  extraGroups.push({ type: 'selector', tag: '国际媒体', outbounds: ['自动选择'].concat(allNodeTags), default: '自动选择' });
  extraGroups.push({ type: 'selector', tag: 'Telegram', outbounds: ['自动选择'].concat(allNodeTags), default: '自动选择' });

  // 6. 自定义策略组
  extraGroups.push({ type: 'urltest', tag: '专线组', outbounds: allNodeTags, url: 'https://www.gstatic.com/generate_204', interval: '3m', tolerance: 50 });

  const extraTags = extraGroups.map(function(g) { return g.tag; });
  config.outbounds = config.outbounds.filter(function(o) { return !extraTags.includes(o.tag); });
  const proxy = config.outbounds.find(function(o) { return o.tag === 'proxy'; });
  if (proxy) {
    proxy.outbounds = extraTags.concat(allNodeTags);
    proxy.default = extraTags[0];
  }
  const proxyIdx = Math.max(0, config.outbounds.findIndex(function(o) { return o.tag === 'proxy'; }));
  config.outbounds.splice.apply(config.outbounds, [proxyIdx + 1, 0].concat(extraGroups));

  // 7. 规则集注入
  const ruleSetBase = 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/';
  config.route.rule_set = config.route.rule_set || [];
  const existingRSTags = new Set(config.route.rule_set.map(function(rs) { return rs.tag; }));
  const ruleSetsToAdd = [
    { tag: 'geosite-ads', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/category-ads-all.srs', download_detour: 'proxy' },
    { tag: 'geosite-openai', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/openai.srs', download_detour: 'proxy' },
    { tag: 'geosite-anthropic', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/anthropic.srs', download_detour: 'proxy' },
    { tag: 'geosite-youtube', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/youtube.srs', download_detour: 'proxy' },
    { tag: 'geosite-netflix', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/netflix.srs', download_detour: 'proxy' },
    { tag: 'geosite-telegram', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/telegram.srs', download_detour: 'proxy' },
    { tag: 'geoip-telegram', type: 'remote', format: 'binary', url: ruleSetBase + 'geoip/telegram.srs', download_detour: 'proxy' },
    { tag: 'geosite-cn', type: 'remote', format: 'binary', url: ruleSetBase + 'geosite/cn.srs', download_detour: 'direct' }
  ];
  for (var j = 0; j < ruleSetsToAdd.length; j++) {
    if (!existingRSTags.has(ruleSetsToAdd[j].tag)) {
      config.route.rule_set.push(ruleSetsToAdd[j]);
    }
  }

  // 8. 路由规则注入
  const scenarioRules = [
    { domain_suffix: ['github.com'], action: 'route', outbound: 'proxy' },
    { rule_set: 'geosite-ads', action: 'reject' },
    { rule_set: ['geosite-openai', 'geosite-anthropic'], outbound: 'AI 平台' },
    { rule_set: ['geosite-youtube', 'geosite-netflix'], outbound: '国际媒体' },
    { rule_set: ['geosite-telegram', 'geoip-telegram'], outbound: 'Telegram' },
    { rule_set: 'geosite-cn', outbound: 'direct' }
  ];
  config.route.rules = scenarioRules.concat(config.route.rules);
  config.route.final = 'proxy';
  return config;
}
`
	base := json.RawMessage(`{
		"outbounds": [
			{"type": "selector", "tag": "proxy", "outbounds": ["HK 01", "JP 01"]},
			{"type": "vless", "tag": "HK 01 [1.0x] | 倍率:1.0 官网:foo.com"},
			{"type": "vmess", "tag": "JP 01 官网:bar.com"}
		],
		"route": {"rules": []}
	}`)
	out, err := TransformConfig(script, base, state.ConfigProfile{Kind: state.ProfileKindSubscription})
	if err != nil {
		t.Fatalf("TransformConfig failed: %v", err)
	}

	var res struct {
		Outbounds []struct {
			Tag string `json:"tag"`
		} `json:"outbounds"`
		Route struct {
			RuleSet []struct {
				Tag string `json:"tag"`
			} `json:"rule_set"`
			Rules []struct {
				Action   string `json:"action"`
				Outbound string `json:"outbound"`
			} `json:"rules"`
		} `json:"route"`
		DNS struct {
			FakeIP struct {
				Enabled bool `json:"enabled"`
			} `json:"fakeip"`
		} `json:"dns"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		t.Fatalf("Unmarshal result failed: %v", err)
	}

	if !res.DNS.FakeIP.Enabled {
		t.Error("Expected FakeIP enabled")
	}
	if len(res.Route.RuleSet) != 8 {
		t.Errorf("Expected 8 rule sets, got %d", len(res.Route.RuleSet))
	}
	if len(res.Route.Rules) < 7 { // 1 hijack dns + 1 custom + 5 scenario
		t.Errorf("Expected at least 7 route rules, got %d", len(res.Route.Rules))
	}
}
