package render

import "testing"

func TestGroupsExpandsNestedStrategyMembers(t *testing.T) {
	groups, err := Groups([]byte(`{"outbounds":[
        {"type":"vless","tag":"a"},{"type":"shadowsocks","tag":"b"},
        {"type":"selector","tag":"all","outbounds":["a","b"]},
        {"type":"urltest","tag":"auto","outbounds":["all"]},
        {"type":"fallback","tag":"service","outbounds":["auto","direct"]},
        {"type":"direct","tag":"direct"}
    ]}`))
	if err != nil { t.Fatal(err) }
	if len(groups) != 3 { t.Fatalf("groups=%+v", groups) }
	if got := groups[2].LeafTags; len(got) != 2 || got[0] != "a" || got[1] != "b" { t.Fatalf("leaves=%v", got) }
}
