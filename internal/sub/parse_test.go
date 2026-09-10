package sub

import (
	"encoding/base64"
	"encoding/json"
	"testing"

	"aster/internal/state"
)

func TestParseVLESS(t *testing.T) {
	raw := "vless://11111111-1111-1111-1111-111111111111@example.com:443?type=tcp&security=tls&sni=example.com#node1"
	r, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Nodes) != 1 {
		t.Fatalf("got %d", len(r.Nodes))
	}
	if r.Nodes[0].Protocol != "vless" {
		t.Fatalf("proto %s", r.Nodes[0].Protocol)
	}
	var m map[string]any
	if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
		t.Fatal(err)
	}
	if m["server"] != "example.com" {
		t.Fatalf("%v", m["server"])
	}
}

func TestParseClashYAML(t *testing.T) {
	raw := `
proxies:
  - name: hk
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-128-gcm
    password: pwd
`
	r, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Nodes) != 1 || r.Nodes[0].Protocol != "shadowsocks" {
		t.Fatalf("%+v", r.Nodes)
	}
}

func TestParseSingBox(t *testing.T) {
	raw := `{"outbounds":[{"type":"trojan","tag":"t1","server":"a.com","server_port":443,"password":"x","tls":{"enabled":true}}]}`
	r, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Nodes) != 1 || r.Nodes[0].Name != "t1" {
		t.Fatalf("%+v", r.Nodes)
	}
}

func TestParseBase64URIList(t *testing.T) {
	raw := base64.StdEncoding.EncodeToString([]byte("vless://11111111-1111-1111-1111-111111111111@a.com:443?security=tls#n1\nvless://11111111-1111-1111-1111-111111111111@b.com:443?security=tls#n2\n"))
	r, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Nodes) != 2 {
		t.Fatalf("got %d", len(r.Nodes))
	}
}

func TestParseAnyTLSStripsTFO(t *testing.T) {
	raw := `{"outbounds":[{"type":"anytls","tag":"a","server":"x.com","server_port":443,"password":"p","tcp_fast_open":true}]}`
	r, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
		t.Fatal(err)
	}
	if _, ok := m["tcp_fast_open"]; ok {
		t.Fatalf("tfo should be stripped: %v", m)
	}
	if len(r.Warning) == 0 {
		t.Fatal("expected warning")
	}
}

func TestFilterNodes(t *testing.T) {
	nodes := []state.Node{{Name: "香港01"}, {Name: "美国01"}}
	out := FilterNodes(nodes, "美国")
	if len(out) != 1 || out[0].Name != "香港01" {
		t.Fatalf("%+v", out)
	}
}

func TestParseTUIC(t *testing.T) {
	raw := "tuic://11111111-1111-1111-1111-111111111111:my-pass@example.com:8443?congestion_controller=bbr&alpn=h3&sni=example.com#tuic-node"
	r, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Nodes) != 1 || r.Nodes[0].Protocol != "tuic" {
		t.Fatalf("got %+v", r.Nodes)
	}
}

func TestParseSSWithPlugin(t *testing.T) {
	raw := "ss://YWVzLTEyOC1nY206cGFzc3dvcmQ@192.168.1.1:8388/?plugin=v2ray-plugin%3Bhost%3Dexample.com#ss-plugin-node"
	r, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Nodes) != 1 || r.Nodes[0].Protocol != "shadowsocks" {
		t.Fatalf("got %+v", r.Nodes)
	}
	var m map[string]any
	if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
		t.Fatal(err)
	}
	if m["plugin"] != "v2ray-plugin" {
		t.Fatalf("expected plugin v2ray-plugin, got %v", m["plugin"])
	}
}
