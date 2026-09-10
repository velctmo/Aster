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
}

// Groups parses only the standard sing-box strategy outbound graph. Unknown
// outbound types are leaves, which makes the parser forward compatible with
// proxy protocols without treating direct/block/dns as probe targets.
func Groups(config []byte) ([]Group, error) {
	var document struct { Outbounds []outboundMeta `json:"outbounds"` }
	if err := json.Unmarshal(config, &document); err != nil { return nil, fmt.Errorf("配置不是有效 JSON: %w", err) }
	byTag := make(map[string]outboundMeta, len(document.Outbounds))
	for _, outbound := range document.Outbounds {
		if outbound.Tag != "" { byTag[outbound.Tag] = outbound }
	}
	var groups []Group
	for _, outbound := range document.Outbounds {
		switch outbound.Type {
		case "selector", "urltest", "fallback":
			if outbound.Tag == "" { continue }
			leaves, err := expandLeaves(outbound.Tag, byTag, map[string]bool{})
			if err != nil { return nil, err }
			groups = append(groups, Group{Tag: outbound.Tag, Name: outbound.Tag, Type: outbound.Type, Members: append([]string(nil), outbound.Outbounds...), LeafTags: leaves})
		}
	}
	// 保留配置中原始定义的策略组顺序，不进行字母字典序强行重排
	return groups, nil
}

func expandLeaves(tag string, byTag map[string]outboundMeta, visiting map[string]bool) ([]string, error) {
	if visiting[tag] { return nil, fmt.Errorf("策略组存在循环引用: %s", tag) }
	item, exists := byTag[tag]
	if !exists { return nil, fmt.Errorf("策略组引用不存在的出站: %s", tag) }
	if item.Type != "selector" && item.Type != "urltest" && item.Type != "fallback" {
		if item.Type == "direct" || item.Type == "block" || item.Type == "dns" { return nil, nil }
		return []string{tag}, nil
	}
	visiting[tag] = true
	defer delete(visiting, tag)
	seen := map[string]bool{}
	var leaves []string
	for _, member := range item.Outbounds {
		memberLeaves, err := expandLeaves(member, byTag, visiting)
		if err != nil { return nil, err }
		for _, leaf := range memberLeaves {
			if !seen[leaf] { seen[leaf] = true; leaves = append(leaves, leaf) }
		}
	}
	return leaves, nil
}
