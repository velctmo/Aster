package render

import (
	"encoding/json"
	"fmt"
)

// Group is the presentation-safe strategy-group graph extracted from a
// rendered sing-box configuration. Members retain the direct outbound edges;
// LeafTags is the recursively expanded, deduplicated set used for probing.
type Group struct {
	Tag      string   `json:"tag"`
	Name     string   `json:"name"`
	Type     string   `json:"type"`
	Now      string   `json:"now,omitempty"`
	Members  []string `json:"members"`
	LeafTags []string `json:"leafTags"`
	DelayMs  int      `json:"delayMs,omitempty"`
}

type outboundMeta struct {
	Type      string   `json:"type"`
	Tag       string   `json:"tag"`
	Outbounds []string `json:"outbounds"`
	Default   string   `json:"default"`
}

// Groups parses only the standard sing-box strategy outbound graph. Unknown
// outbound types are leaves, which makes the parser forward compatible with
// proxy protocols without treating direct/block/dns as probe targets.
func Groups(config []byte) ([]Group, error) {
	var document struct {
		Outbounds []outboundMeta `json:"outbounds"`
		Endpoints []outboundMeta `json:"endpoints"`
	}
	if err := json.Unmarshal(config, &document); err != nil {
		return nil, fmt.Errorf("配置不是有效 JSON: %w", err)
	}
	byTag := make(map[string]outboundMeta, len(document.Outbounds)+len(document.Endpoints))
	for _, outbound := range document.Outbounds {
		if outbound.Tag != "" {
			byTag[outbound.Tag] = outbound
		}
	}
	for _, ep := range document.Endpoints {
		if ep.Tag != "" {
			byTag[ep.Tag] = ep
		}
	}
	groups := []Group{}
	for _, outbound := range document.Outbounds {
		switch outbound.Type {
		case "selector", "urltest", "fallback":
			if outbound.Tag == "" {
				continue
			}
			leaves, err := expandLeaves(outbound.Tag, byTag, map[string]bool{})
			if err != nil {
				return nil, err
			}
			name := outbound.Tag
			if outbound.Tag == "proxy" {
				name = "节点选择"
			}
			groups = append(groups, Group{
				Tag:      outbound.Tag,
				Name:     name,
				Type:     outbound.Type,
				Now:      outbound.Default,
				Members:  append([]string{}, outbound.Outbounds...),
				LeafTags: append([]string{}, leaves...),
			})
		}
	}
	// 没有 selector/urltest 时仍给出 Sparkle 式主组：DIRECT + 全部叶子节点。
	if len(groups) == 0 {
		var leaves []string
		for _, outbound := range document.Outbounds {
			if outbound.Tag == "" || isStrategyOutbound(outbound.Type) || isSpecialOutbound(outbound.Type) {
				continue
			}
			leaves = append(leaves, outbound.Tag)
		}
		for _, ep := range document.Endpoints {
			if ep.Tag == "" || isStrategyOutbound(ep.Type) || isSpecialOutbound(ep.Type) {
				continue
			}
			leaves = append(leaves, ep.Tag)
		}
		if len(leaves) > 0 {
			members := append([]string{"direct"}, leaves...)
			groups = append(groups, Group{
				Tag:      "proxy",
				Name:     "节点选择",
				Type:     "selector",
				Members:  members,
				LeafTags: append([]string{}, leaves...),
			})
		}
	}
	// 保留配置中原始定义的策略组顺序，不进行字母字典序强行重排
	return groups, nil
}

func isStrategyOutbound(typ string) bool {
	return typ == "selector" || typ == "urltest" || typ == "fallback"
}

func isSpecialOutbound(typ string) bool {
	return typ == "direct" || typ == "block" || typ == "dns"
}

func isSpecialTag(tag string) bool {
	return tag == "direct" || tag == "block" || tag == "reject" || tag == "dns"
}

// ProbeTags is the set of protocol outbounds that a group delay test should
// actually ping. Nested strategy groups and built-in direct/block/dns are
// excluded so testing "香港" does not recurse into proxy and hit every node.
func ProbeTags(group Group, strategyTags map[string]bool) []string {
	src := group.LeafTags
	if len(src) == 0 {
		src = group.Members
	}
	out := make([]string, 0, len(src))
	seen := map[string]bool{}
	for _, tag := range src {
		if tag == "" || tag == group.Tag || seen[tag] || isSpecialTag(tag) || strategyTags[tag] {
			continue
		}
		seen[tag] = true
		out = append(out, tag)
	}
	return out
}

func expandLeaves(tag string, byTag map[string]outboundMeta, visiting map[string]bool) ([]string, error) {
	if visiting[tag] {
		return nil, fmt.Errorf("策略组存在循环引用: %s", tag)
	}
	item, exists := byTag[tag]
	if !exists {
		return nil, nil
	}
	if !isStrategyOutbound(item.Type) {
		if isSpecialOutbound(item.Type) {
			return nil, nil
		}
		return []string{tag}, nil
	}
	visiting[tag] = true
	defer delete(visiting, tag)
	seen := map[string]bool{}
	var leaves []string
	for _, member := range item.Outbounds {
		memberLeaves, err := expandLeaves(member, byTag, visiting)
		if err != nil {
			return nil, err
		}
		for _, leaf := range memberLeaves {
			if !seen[leaf] {
				seen[leaf] = true
				leaves = append(leaves, leaf)
			}
		}
	}
	return leaves, nil
}
