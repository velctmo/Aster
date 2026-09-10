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
