package app

import (
	"testing"

	"aster/internal/state"
)

func TestRuleEvaluator_Domain(t *testing.T) {
	rules := []state.Rule{
		{ID: "1", Match: "DOMAIN", Value: "google.com", Action: "proxy"},
	}
	eval := NewRuleEvaluator(rules)

	res := eval.Evaluate("google.com", "", 0, "")
	if !res.Matched || res.Outbound != "proxy" || res.RuleType != "DOMAIN" || res.Payload != "google.com" {
		t.Fatalf("expected google.com match, got %+v", res)
	}

	resUpper := eval.Evaluate("GOOGLE.COM", "", 0, "")
	if !resUpper.Matched {
		t.Fatalf("expected case-insensitive match, got %+v", resUpper)
	}

	resSub := eval.Evaluate("mail.google.com", "", 0, "")
	if resSub.Matched {
		t.Fatalf("expected DOMAIN to not match subdomain, got %+v", resSub)
	}
}

func TestRuleEvaluator_DomainSuffix(t *testing.T) {
	rules := []state.Rule{
		{ID: "1", Match: "DOMAIN-SUFFIX", Value: "apple.com", Action: "proxy"},
		{ID: "2", Match: "domain_suffix", Value: ".github.com", Action: "proxy"},
	}
	eval := NewRuleEvaluator(rules)

	// Exact domain
	res1 := eval.Evaluate("apple.com", "", 0, "")
	if !res1.Matched || res1.Outbound != "proxy" {
		t.Fatalf("expected apple.com match, got %+v", res1)
	}

	// Subdomain
	res2 := eval.Evaluate("developer.apple.com", "", 0, "")
	if !res2.Matched || res2.Outbound != "proxy" {
		t.Fatalf("expected developer.apple.com match, got %+v", res2)
	}

	// Leading dot rule
	res3 := eval.Evaluate("api.github.com", "", 0, "")
	if !res3.Matched || res3.Outbound != "proxy" {
		t.Fatalf("expected api.github.com match, got %+v", res3)
	}

	// Suffix not boundary
	res4 := eval.Evaluate("fakeapple.com", "", 0, "")
	if res4.Matched {
		t.Fatalf("expected fakeapple.com to not match, got %+v", res4)
	}
}

func TestRuleEvaluator_DomainKeyword(t *testing.T) {
	rules := []state.Rule{
		{ID: "1", Match: "DOMAIN-KEYWORD", Value: "tele", Action: "proxy"},
	}
	eval := NewRuleEvaluator(rules)

	res := eval.Evaluate("telegram.org", "", 0, "")
	if !res.Matched || res.Outbound != "proxy" || res.Payload != "tele" {
		t.Fatalf("expected keyword match, got %+v", res)
	}

	res2 := eval.Evaluate("example.com", "", 0, "")
	if res2.Matched {
		t.Fatalf("expected no keyword match, got %+v", res2)
	}
}

func TestRuleEvaluator_IPCIDR(t *testing.T) {
	rules := []state.Rule{
		{ID: "1", Match: "IP-CIDR", Value: "192.168.0.0/16", Action: "direct"},
		{ID: "2", Match: "IP-CIDR6", Value: "2001:db8::/32", Action: "direct"},
		{ID: "3", Match: "IP-CIDR", Value: "1.1.1.1", Action: "proxy"},
	}
	eval := NewRuleEvaluator(rules)

	resIPv4 := eval.Evaluate("192.168.1.100", "", 0, "")
	if !resIPv4.Matched || resIPv4.Outbound != "direct" {
		t.Fatalf("expected 192.168.1.100 match, got %+v", resIPv4)
	}

	resIPv6 := eval.Evaluate("2001:db8::ffff", "", 0, "")
	if !resIPv6.Matched || resIPv6.Outbound != "direct" {
		t.Fatalf("expected IPv6 CIDR match, got %+v", resIPv6)
	}

	resExactIP := eval.Evaluate("1.1.1.1", "", 0, "")
	if !resExactIP.Matched || resExactIP.Outbound != "proxy" {
		t.Fatalf("expected exact IP match, got %+v", resExactIP)
	}

	resOut := eval.Evaluate("10.0.0.1", "", 0, "")
	if resOut.Matched {
		t.Fatalf("expected 10.0.0.1 not to match, got %+v", resOut)
	}

	// Non-IP target should not match IP-CIDR rule
	resDomain := eval.Evaluate("example.com", "", 0, "")
	if resDomain.Matched {
		t.Fatalf("expected example.com not to match IP-CIDR, got %+v", resDomain)
	}
}

func TestRuleEvaluator_ProcessName(t *testing.T) {
	rules := []state.Rule{
		{ID: "1", Match: "PROCESS-NAME", Value: "curl", Action: "direct"},
		{ID: "2", Match: "PROCESS-NAME", Value: "Slack.app", Action: "proxy"},
	}
	eval := NewRuleEvaluator(rules)

	// EqualFold match
	res1 := eval.Evaluate("example.com", "curl", 0, "")
	if !res1.Matched || res1.Outbound != "direct" {
		t.Fatalf("expected curl match, got %+v", res1)
	}

	// Path containing process name
	res2 := eval.Evaluate("example.com", "/usr/bin/curl", 0, "")
	if !res2.Matched || res2.Outbound != "direct" {
		t.Fatalf("expected /usr/bin/curl match, got %+v", res2)
	}

	// Substring / app match
	res3 := eval.Evaluate("slack.com", "/Applications/Slack.app/Contents/MacOS/Slack", 0, "")
	if !res3.Matched || res3.Outbound != "proxy" {
		t.Fatalf("expected Slack match, got %+v", res3)
	}

	// Empty process name does not match
	res4 := eval.Evaluate("example.com", "", 0, "")
	if res4.Matched {
		t.Fatalf("expected no match with empty process, got %+v", res4)
	}
}

func TestRuleEvaluator_GeositeAndRuleSet(t *testing.T) {
	rules := []state.Rule{
		{ID: "1", Match: "GEOSITE", Value: "geosite-google", Action: "proxy"},
		{ID: "2", Match: "RULE-SET", Value: "cn", Action: "direct"},
		{ID: "3", Match: "GEOSITE", Value: "apple", Action: "proxy"},
	}
	eval := NewRuleEvaluator(rules)

	resGoogle := eval.Evaluate("www.google.com", "", 0, "")
	if !resGoogle.Matched || resGoogle.Outbound != "proxy" {
		t.Fatalf("expected geosite-google match, got %+v", resGoogle)
	}

	resCN := eval.Evaluate("bilibili.com", "", 0, "")
	if !resCN.Matched || resCN.Outbound != "direct" {
		t.Fatalf("expected cn rule-set match, got %+v", resCN)
	}

	resCNDomain := eval.Evaluate("something.cn", "", 0, "")
	if !resCNDomain.Matched || resCNDomain.Outbound != "direct" {
		t.Fatalf("expected .cn domain match, got %+v", resCNDomain)
	}

	resApple := eval.Evaluate("api.apple.com", "", 0, "")
	if !resApple.Matched || resApple.Outbound != "proxy" {
		t.Fatalf("expected apple geosite match, got %+v", resApple)
	}
}

func TestRuleEvaluator_MatchFallbackAndOrder(t *testing.T) {
	rules := []state.Rule{
		{ID: "1", Match: "DOMAIN-SUFFIX", Value: "google.com", Action: "proxy"},
		{ID: "2", Match: "MATCH", Value: "", Action: "direct"},
	}
	eval := NewRuleEvaluator(rules)

	// First rule hits
	res1 := eval.Evaluate("google.com", "", 0, "")
	if !res1.Matched || res1.Outbound != "proxy" || res1.RuleType != "DOMAIN-SUFFIX" {
		t.Fatalf("expected google.com to match first rule, got %+v", res1)
	}

	// Fallback hits
	res2 := eval.Evaluate("random-other-domain.org", "", 0, "")
	if !res2.Matched || res2.Outbound != "direct" || res2.RuleType != "MATCH" {
		t.Fatalf("expected fallback MATCH rule, got %+v", res2)
	}
}

func TestRuleEvaluator_NoMatch(t *testing.T) {
	rules := []state.Rule{
		{ID: "1", Match: "DOMAIN", Value: "foo.com", Action: "proxy"},
	}
	eval := NewRuleEvaluator(rules)

	res := eval.Evaluate("bar.com", "", 0, "")
	if res.Matched {
		t.Fatalf("expected no match, got %+v", res)
	}
	if res.Target != "bar.com" {
		t.Fatalf("expected target bar.com, got %s", res.Target)
	}
	if res.EvaluationTimeMs < 0 {
		t.Fatalf("expected positive evaluation time, got %f", res.EvaluationTimeMs)
	}
}

func TestApp_EvaluateRule_SelectedNodeResolution(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ASTER_DATA_DIR", dir)

	a, err := New()
	if err != nil {
		t.Fatal(err)
	}

	// Configure user rules
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Rules = []state.Rule{
			{ID: "r1", Match: "domain_suffix", Value: "google.com", Action: "proxy"},
			{ID: "r2", Match: "domain_suffix", Value: "cn", Action: "direct"},
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	// Case 1: Proxy uses Selected node
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Selected = "jp-node-01"
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	res, err := a.EvaluateRule("google.com", "", 443, "tcp")
	if err != nil {
		t.Fatal(err)
	}
	if !res.Matched || res.Outbound != "proxy" || res.SelectedNode != "jp-node-01" {
		t.Fatalf("expected SelectedNode jp-node-01, got %+v", res)
	}

	// Case 2: SelectorNow overrides strategy group
	if _, err := a.Store().Update(func(f *state.File) error {
		if f.SelectorNow == nil {
			f.SelectorNow = make(map[string]string)
		}
		f.SelectorNow["proxy"] = "hk-node-02"
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	res2, err := a.EvaluateRule("maps.google.com", "", 443, "tcp")
	if err != nil {
		t.Fatal(err)
	}
	if !res2.Matched || res2.SelectedNode != "hk-node-02" {
		t.Fatalf("expected SelectorNow hk-node-02, got %+v", res2)
	}

	// Case 3: Outbound is "direct"
	res3, err := a.EvaluateRule("service.cn", "", 80, "tcp")
	if err != nil {
		t.Fatal(err)
	}
	if !res3.Matched || res3.Outbound != "direct" {
		t.Fatalf("expected direct outbound, got %+v", res3)
	}
}
