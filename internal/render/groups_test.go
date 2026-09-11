package render

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestGroupsExpandsNestedStrategyMembers(t *testing.T) {
	groups, err := Groups([]byte(`{"outbounds":[
        {"type":"vless","tag":"a"},{"type":"shadowsocks","tag":"b"},
        {"type":"selector","tag":"all","outbounds":["a","b"]},
        {"type":"urltest","tag":"auto","outbounds":["all"]},
        {"type":"fallback","tag":"service","outbounds":["auto","direct"]},
        {"type":"direct","tag":"direct"}
    ]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 3 {
		t.Fatalf("groups=%+v", groups)
	}
	if got := groups[2].LeafTags; len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("leaves=%v", got)
	}
}

func TestGroupsReadsSelectorDefaultAsNow(t *testing.T) {
	groups, err := Groups([]byte(`{"outbounds":[
        {"type":"vless","tag":"hk-01"},
        {"type":"selector","tag":"proxy","outbounds":["direct","hk-01"],"default":"hk-01"}
    ]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 1 || groups[0].Now != "hk-01" {
		t.Fatalf("now=%+v", groups)
	}
}

func TestGroupsNamesProxy节点选择(t *testing.T) {
	groups, err := Groups([]byte(`{"outbounds":[
        {"type":"vless","tag":"a"},
        {"type":"selector","tag":"proxy","outbounds":["a"]}
    ]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 1 || groups[0].Tag != "proxy" || groups[0].Name != "节点选择" {
		t.Fatalf("groups=%+v", groups)
	}
}

func TestGroupsSkipsMissingOutboundMember(t *testing.T) {
	groups, err := Groups([]byte(`{"outbounds":[
        {"type":"vless","tag":"a"},
        {"type":"selector","tag":"proxy","outbounds":["a","ghost"]}
    ]}`))
	if err != nil {
		t.Fatalf("dangling member must not fail the whole list: %v", err)
	}
	if len(groups) != 1 {
		t.Fatalf("groups=%+v", groups)
	}
	if got := groups[0].LeafTags; len(got) != 1 || got[0] != "a" {
		t.Fatalf("leaves=%v", got)
	}
}

func TestGroupsJSONUsesEmptyArraysNotNull(t *testing.T) {
	groups, err := Groups([]byte(`{"outbounds":[{"type":"selector","tag":"proxy"},{"type":"direct","tag":"direct"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(groups)
	if err != nil {
		t.Fatal(err)
	}
	encoded := string(raw)
	if strings.Contains(encoded, `"members":null`) || strings.Contains(encoded, `"leafTags":null`) {
		t.Fatalf("Swift [String] cannot decode null arrays: %s", encoded)
	}
}

func TestGroupsEmptyConfigMarshalsAsArray(t *testing.T) {
	groups, err := Groups([]byte(`{"outbounds":[{"type":"direct","tag":"direct"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(groups)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != "[]" {
		t.Fatalf("empty groups must be [] not null: %s", raw)
	}
}

func TestGroupsSynthesizesMainSelectorFromLeaves(t *testing.T) {
	groups, err := Groups([]byte(`{"outbounds":[
        {"type":"direct","tag":"direct"},
        {"type":"vless","tag":"jp-01"},
        {"type":"trojan","tag":"hk-01"}
    ]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 1 {
		t.Fatalf("groups=%+v", groups)
	}
	g := groups[0]
	if g.Tag != "proxy" || g.Name != "节点选择" || g.Type != "selector" {
		t.Fatalf("group=%+v", g)
	}
	if len(g.Members) != 3 || g.Members[0] != "direct" || g.Members[1] != "jp-01" || g.Members[2] != "hk-01" {
		t.Fatalf("members=%v", g.Members)
	}
	if len(g.LeafTags) != 2 || g.LeafTags[0] != "jp-01" || g.LeafTags[1] != "hk-01" {
		t.Fatalf("leaves=%v", g.LeafTags)
	}
}

func TestProbeTagsSkipsNestedGroupsAndDirect(t *testing.T) {
	hk := Group{
		Tag:      "香港",
		Members:  []string{"proxy", "hk-01", "direct"},
		LeafTags: []string{"hk-01", "jp-01"},
	}
	all := Group{
		Tag:      "proxy",
		Members:  []string{"香港", "direct", "hk-01", "jp-01"},
		LeafTags: []string{"hk-01", "jp-01"},
	}
	strategy := map[string]bool{"proxy": true, "香港": true}
	gotHK := ProbeTags(hk, strategy)
	if len(gotHK) != 2 || gotHK[0] != "hk-01" || gotHK[1] != "jp-01" {
		t.Fatalf("hongkong probe=%v", gotHK)
	}
	// Even if LeafTags is empty, nested strategy members must not be probed.
	hk.LeafTags = nil
	gotHK = ProbeTags(hk, strategy)
	if len(gotHK) != 1 || gotHK[0] != "hk-01" {
		t.Fatalf("hongkong members probe=%v", gotHK)
	}
	gotAll := ProbeTags(all, strategy)
	if len(gotAll) != 2 || gotAll[0] != "hk-01" || gotAll[1] != "jp-01" {
		t.Fatalf("proxy probe=%v", gotAll)
	}
}
