package app

import (
	"net"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"aster/internal/state"
)

type RuleEvaluateResult struct {
	Target           string  `json:"target"`
	Matched          bool    `json:"matched"`
	RuleType         string  `json:"ruleType"`
	Payload          string  `json:"payload"`
	Outbound         string  `json:"outbound"`
	SelectedNode     string  `json:"selectedNode"`
	EvaluationTimeMs float64 `json:"evaluationTimeMs"`
}

type RuleEvaluator struct {
	rules []state.Rule
}

func NewRuleEvaluator(rules []state.Rule) *RuleEvaluator {
	return &RuleEvaluator{rules: rules}
}

func (e *RuleEvaluator) Evaluate(target string, process string, port int, network string) *RuleEvaluateResult {
	start := time.Now()
	res := &RuleEvaluateResult{
		Target:  target,
		Matched: false,
	}

	host := strings.TrimSpace(target)
	if h, p, err := net.SplitHostPort(host); err == nil {
		host = h
		if port == 0 {
			if parsedPort, pErr := strconv.Atoi(p); pErr == nil {
				port = parsedPort
			}
		}
	}

	targetLower := strings.ToLower(host)
	targetIP, ipErr := netip.ParseAddr(host)
	processClean := strings.TrimSpace(process)
	processLower := strings.ToLower(processClean)

	for _, rule := range e.rules {
		matchType := strings.ToUpper(strings.ReplaceAll(rule.Match, "_", "-"))
		ruleVal := strings.TrimSpace(rule.Value)
		ruleValLower := strings.ToLower(ruleVal)

		matched := false

		switch matchType {
		case "PROCESS-NAME", "PROCESS":
			if processClean != "" {
				if strings.EqualFold(ruleVal, processClean) ||
					strings.Contains(processLower, ruleValLower) ||
					strings.Contains(ruleValLower, processLower) {
					matched = true
				}
			}

		case "DOMAIN":
			if host != "" && strings.EqualFold(host, ruleVal) {
				matched = true
			}

		case "DOMAIN-SUFFIX":
			val := strings.TrimPrefix(ruleValLower, ".")
			if targetLower == val || strings.HasSuffix(targetLower, "."+val) {
				matched = true
			}

		case "DOMAIN-KEYWORD":
			if ruleValLower != "" && strings.Contains(targetLower, ruleValLower) {
				matched = true
			}

		case "IP-CIDR", "IP-CIDR6":
			if ipErr == nil {
				if prefix, err := netip.ParsePrefix(ruleVal); err == nil {
					if prefix.Contains(targetIP) {
						matched = true
					}
				} else if addr, err := netip.ParseAddr(ruleVal); err == nil {
					if addr == targetIP {
						matched = true
					}
				}
			}

		case "GEOSITE", "RULE-SET":
			matched = matchGeositeOrRuleSet(targetLower, ruleValLower)

		case "MATCH", "FINAL":
			matched = true

		case "PORT", "DST-PORT":
			if port > 0 {
				if p, err := strconv.Atoi(ruleVal); err == nil && p == port {
					matched = true
				}
			}

		case "IP-IS-PRIVATE":
			if ipErr == nil && (targetIP.IsPrivate() || targetIP.IsLoopback() || targetIP.IsLinkLocalUnicast()) {
				matched = true
			}
		}

		if matched {
			res.Matched = true
			res.RuleType = rule.Match
			res.Payload = rule.Value
			res.Outbound = rule.Action
			break
		}
	}

	res.EvaluationTimeMs = float64(time.Since(start).Microseconds()) / 1000.0
	return res
}

func matchGeositeOrRuleSet(targetLower, ruleValLower string) bool {
	key := ruleValLower
	key = strings.TrimPrefix(key, "geosite-")
	key = strings.TrimPrefix(key, "geosite:")
	key = strings.TrimPrefix(key, "geoip-")
	key = strings.TrimPrefix(key, "geoip:")
	key = strings.TrimSuffix(key, "-all")

	switch key {
	case "cn":
		if strings.HasSuffix(targetLower, ".cn") {
			return true
		}
		cnDomains := []string{
			"baidu.com", "qq.com", "tencent.com", "aliyun.com", "alipay.com",
			"taobao.com", "jd.com", "bilibili.com", "weibo.com", "163.com",
			"126.net", "sina.com", "zhihu.com", "douyin.com", "bytedance.com",
			"xiaomi.com", "huawei.com", "meituan.com", "ctrip.com", "sohu.com",
		}
		for _, d := range cnDomains {
			if targetLower == d || strings.HasSuffix(targetLower, "."+d) {
				return true
			}
		}
	case "google":
		googleKeywords := []string{"google", "youtube", "gmail", "googlevideo", "gstatic", "gvt1"}
		for _, kw := range googleKeywords {
			if strings.Contains(targetLower, kw) {
				return true
			}
		}
	case "apple":
		appleKeywords := []string{"apple", "icloud", "mzstatic", "aaplimg"}
		for _, kw := range appleKeywords {
			if strings.Contains(targetLower, kw) {
				return true
			}
		}
	case "telegram":
		if strings.Contains(targetLower, "telegram") || strings.HasSuffix(targetLower, "t.me") {
			return true
		}
	case "category-ads", "category-ads-all", "ads":
		adsKeywords := []string{"ads", "adservice", "doubleclick", "pagead", "analytics"}
		for _, kw := range adsKeywords {
			if strings.Contains(targetLower, kw) {
				return true
			}
		}
	default:
		if key != "" && strings.Contains(targetLower, key) {
			return true
		}
	}
	return false
}

func (a *App) EvaluateRule(target string, process string, port int, network string) (*RuleEvaluateResult, error) {
	eval := NewRuleEvaluator(a.LiveRules())
	res := eval.Evaluate(target, process, port, network)
	if !res.Matched {
		return res, nil
	}

	st := a.st.Get()
	if st.SelectorNow != nil && st.SelectorNow[res.Outbound] != "" {
		res.SelectedNode = st.SelectorNow[res.Outbound]
	} else if strings.EqualFold(res.Outbound, "proxy") && st.Selected != "" {
		res.SelectedNode = st.Selected
	} else if saved := selectorSaved(st, res.Outbound); saved != "" {
		res.SelectedNode = saved
	} else {
		res.SelectedNode = res.Outbound
	}

	return res, nil
}
