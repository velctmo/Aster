package app

import (
	"fmt"
	"net"
	"strings"

	"golang.org/x/net/publicsuffix"

	"aster/internal/state"
)

func (a *App) AddRule(match, value, action string) error {
	if err := a.requireNodeProfile(); err != nil {
		return err
	}
	old := a.st.Get()
	candidate := state.CloneFile(old)
	for i, r := range candidate.Rules {
		if r.Match == match && r.Value == value {
			candidate.Rules[i].Action = action
			if err := a.applyAndCommitCandidate(old, candidate, func(cur *state.File) { cur.Rules = candidate.Rules }); err != nil {
				return err
			}
			_ = a.clash.CloseAll()
			return nil
		}
	}
	candidate.Rules = append([]state.Rule{{ID: state.NewID(), Match: match, Value: value, Action: action}}, candidate.Rules...)
	if err := a.applyAndCommitCandidate(old, candidate, func(cur *state.File) { cur.Rules = candidate.Rules }); err != nil {
		return err
	}
	_ = a.clash.CloseAll()
	return nil
}

func (a *App) RuleFromLog(host, matchKind, action string) error {
	host = strings.TrimSpace(host)
	if host == "" {
		return fmt.Errorf("没有主机")
	}
	cleanedHost := stripPort(host)
	if ip := net.ParseIP(cleanedHost); ip != nil {
		var v string
		if ip.To4() != nil {
			v = ip.String() + "/32"
		} else {
			v = ip.String() + "/128"
		}
		return a.AddRule("ip_cidr", v, action)
	}
	switch matchKind {
	case "domain":
		return a.AddRule("domain", strings.ToLower(cleanedHost), action)
	default:
		reg, err := publicsuffix.EffectiveTLDPlusOne(cleanedHost)
		if err != nil || reg == "" {
			return a.AddRule("domain", strings.ToLower(cleanedHost), action)
		}
		return a.AddRule("domain_suffix", strings.ToLower(reg), action)
	}
}

func stripPort(h string) string {
	if strings.HasPrefix(h, "[") {
		if i := strings.LastIndex(h, "]"); i >= 0 {
			return h[1:i]
		}
	}
	if i := strings.LastIndex(h, ":"); i > 0 && strings.Count(h, ":") == 1 {
		return h[:i]
	}
	return h
}

func (a *App) DeleteRule(id string) error {
	if err := a.requireNodeProfile(); err != nil {
		return err
	}
	old := a.st.Get()
	candidate := state.CloneFile(old)
	out := make([]state.Rule, 0, len(candidate.Rules))
	for _, r := range candidate.Rules {
		if r.ID != id {
			out = append(out, r)
		}
	}
	if len(out) == len(candidate.Rules) {
		return fmt.Errorf("规则不存在")
	}
	candidate.Rules = out
	return a.applyAndCommitCandidate(old, candidate, func(cur *state.File) { cur.Rules = candidate.Rules })
}

func (a *App) ReorderRules(ids []string) error {
	if err := a.requireNodeProfile(); err != nil {
		return err
	}
	old := a.st.Get()
	candidate := state.CloneFile(old)
	idx := map[string]state.Rule{}
	for _, r := range candidate.Rules {
		idx[r.ID] = r
	}
	var next []state.Rule
	for _, id := range ids {
		if r, ok := idx[id]; ok {
			next = append(next, r)
			delete(idx, id)
		}
	}
	for _, r := range candidate.Rules {
		if _, ok := idx[r.ID]; ok {
			next = append(next, r)
		}
	}
	candidate.Rules = next
	return a.applyAndCommitCandidate(old, candidate, func(cur *state.File) { cur.Rules = candidate.Rules })
}
