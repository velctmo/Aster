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

func TestParseWireGuard_ClashYAML(t *testing.T) {
	t.Run("regular wireguard", func(t *testing.T) {
		raw := `
proxies:
  - name: wg-node
    type: wireguard
    server: 198.51.100.1
    port: 51820
    ip: 172.16.0.2
    public-key: peer-pub-key-123
    private-key: priv-key-456
    preshared-key: psk-789
    mtu: 1420
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(r.Nodes) != 1 {
			t.Fatalf("expected 1 node, got %d", len(r.Nodes))
		}
		node := r.Nodes[0]
		if node.Protocol != "wireguard" {
			t.Fatalf("expected protocol wireguard, got %s", node.Protocol)
		}
		if node.Name != "wg-node" {
			t.Fatalf("expected name wg-node, got %s", node.Name)
		}

		var m map[string]any
		if err := json.Unmarshal(node.Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		if m["type"] != "wireguard" {
			t.Fatalf("expected type wireguard, got %v", m["type"])
		}
		if m["tag"] != "wg-node" {
			t.Fatalf("expected tag wg-node, got %v", m["tag"])
		}
		if m["server"] != "198.51.100.1" {
			t.Fatalf("expected server 198.51.100.1, got %v", m["server"])
		}
		if m["server_port"] != float64(51820) {
			t.Fatalf("expected server_port 51820, got %v", m["server_port"])
		}
		addrs, ok := m["local_address"].([]any)
		if !ok || len(addrs) != 1 || addrs[0] != "172.16.0.2/32" {
			t.Fatalf("expected local_address [\"172.16.0.2/32\"], got %v", m["local_address"])
		}
		if m["private_key"] != "priv-key-456" {
			t.Fatalf("expected private_key priv-key-456, got %v", m["private_key"])
		}
		if m["peer_public_key"] != "peer-pub-key-123" {
			t.Fatalf("expected peer_public_key peer-pub-key-123, got %v", m["peer_public_key"])
		}
		if m["pre_shared_key"] != "psk-789" {
			t.Fatalf("expected pre_shared_key psk-789, got %v", m["pre_shared_key"])
		}
		if m["mtu"] != float64(1420) {
			t.Fatalf("expected mtu 1420, got %v", m["mtu"])
		}
		if _, ok := m["reserved"]; ok {
			t.Fatalf("expected no reserved field, got %v", m["reserved"])
		}
	})

	t.Run("warp wireguard with reserved slice and dual-stack ips", func(t *testing.T) {
		raw := `
proxies:
  - name: warp-slice
    type: wg
    server: 162.159.192.1
    port: 2408
    ips:
      - "172.16.0.2"
      - "2606:4700:110:8f81:85e8:5350:2ff1:d0cf"
    public-key: warp-pub-key
    private-key: warp-priv-key
    reserved: [0, 0, 0]
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(r.Nodes) != 1 {
			t.Fatalf("expected 1 node, got %d", len(r.Nodes))
		}
		node := r.Nodes[0]
		if node.Protocol != "wireguard" {
			t.Fatalf("expected protocol wireguard, got %s", node.Protocol)
		}

		var m map[string]any
		if err := json.Unmarshal(node.Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		addrs, ok := m["local_address"].([]any)
		if !ok || len(addrs) != 2 || addrs[0] != "172.16.0.2/32" || addrs[1] != "2606:4700:110:8f81:85e8:5350:2ff1:d0cf/128" {
			t.Fatalf("expected dual-stack normalized addresses, got %v", m["local_address"])
		}
		res, ok := m["reserved"].([]any)
		if !ok || len(res) != 3 || res[0] != float64(0) || res[1] != float64(0) || res[2] != float64(0) {
			t.Fatalf("expected reserved [0, 0, 0], got %v", m["reserved"])
		}
		if m["mtu"] != float64(1420) {
			t.Fatalf("expected default mtu 1420, got %v", m["mtu"])
		}
	})

	t.Run("warp wireguard with string reserved and custom mtu", func(t *testing.T) {
		raw := `
proxies:
  - name: warp-str
    type: wireguard
    server: 162.159.192.1
    port: 2408
    ip: "172.16.0.2/32"
    public-key: warp-pub-key
    private-key: warp-priv-key
    reserved: "0,0,0"
    mtu: 1280
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(r.Nodes) != 1 {
			t.Fatalf("expected 1 node, got %d", len(r.Nodes))
		}
		node := r.Nodes[0]

		var m map[string]any
		if err := json.Unmarshal(node.Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		res, ok := m["reserved"].([]any)
		if !ok || len(res) != 3 || res[0] != float64(0) || res[1] != float64(0) || res[2] != float64(0) {
			t.Fatalf("expected reserved [0, 0, 0], got %v", m["reserved"])
		}
		if m["mtu"] != float64(1280) {
			t.Fatalf("expected mtu 1280, got %v", m["mtu"])
		}
	})
}

func TestParseWireGuard_URI(t *testing.T) {
	t.Run("standard wireguard scheme", func(t *testing.T) {
		raw := "wireguard://priv-key-123@198.51.100.1:51820?public_key=peer-pub-123&address=172.16.0.2&reserved=0,0,0&mtu=1420#wg-node"
		r, err := Parse(raw)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(r.Nodes) != 1 {
			t.Fatalf("expected 1 node, got %d", len(r.Nodes))
		}
		node := r.Nodes[0]
		if node.Protocol != "wireguard" {
			t.Fatalf("expected protocol wireguard, got %s", node.Protocol)
		}
		if node.Name != "wg-node" {
			t.Fatalf("expected name wg-node, got %s", node.Name)
		}

		var m map[string]any
		if err := json.Unmarshal(node.Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		if m["type"] != "wireguard" {
			t.Fatalf("expected type wireguard, got %v", m["type"])
		}
		if m["server"] != "198.51.100.1" {
			t.Fatalf("expected server 198.51.100.1, got %v", m["server"])
		}
		if m["server_port"] != float64(51820) {
			t.Fatalf("expected server_port 51820, got %v", m["server_port"])
		}
		if m["private_key"] != "priv-key-123" {
			t.Fatalf("expected private_key priv-key-123, got %v", m["private_key"])
		}
		if m["peer_public_key"] != "peer-pub-123" {
			t.Fatalf("expected peer_public_key peer-pub-123, got %v", m["peer_public_key"])
		}
		addrs, ok := m["local_address"].([]any)
		if !ok || len(addrs) != 1 || addrs[0] != "172.16.0.2/32" {
			t.Fatalf("expected local_address [\"172.16.0.2/32\"], got %v", m["local_address"])
		}
		res, ok := m["reserved"].([]any)
		if !ok || len(res) != 3 || res[0] != float64(0) || res[1] != float64(0) || res[2] != float64(0) {
			t.Fatalf("expected reserved [0, 0, 0], got %v", m["reserved"])
		}
		if m["mtu"] != float64(1420) {
			t.Fatalf("expected mtu 1420, got %v", m["mtu"])
		}
	})

	t.Run("wg scheme alias with preshared_key and dual-stack addresses", func(t *testing.T) {
		raw := "wg://priv-key-456@198.51.100.2:51820?public_key=peer-pub-456&address=172.16.0.2/32,2606:4700:110:8f81:85e8:5350:2ff1:d0cf/128&preshared_key=psk-456#wg-warp"
		n, err := ParseURI(raw)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if n.Protocol != "wireguard" {
			t.Fatalf("expected protocol wireguard, got %s", n.Protocol)
		}
		if n.Name != "wg-warp" {
			t.Fatalf("expected name wg-warp, got %s", n.Name)
		}

		var m map[string]any
		if err := json.Unmarshal(n.Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		if m["type"] != "wireguard" {
			t.Fatalf("expected type wireguard, got %v", m["type"])
		}
		if m["server"] != "198.51.100.2" {
			t.Fatalf("expected server 198.51.100.2, got %v", m["server"])
		}
		if m["server_port"] != float64(51820) {
			t.Fatalf("expected server_port 51820, got %v", m["server_port"])
		}
		if m["private_key"] != "priv-key-456" {
			t.Fatalf("expected private_key priv-key-456, got %v", m["private_key"])
		}
		if m["peer_public_key"] != "peer-pub-456" {
			t.Fatalf("expected peer_public_key peer-pub-456, got %v", m["peer_public_key"])
		}
		if m["pre_shared_key"] != "psk-456" {
			t.Fatalf("expected pre_shared_key psk-456, got %v", m["pre_shared_key"])
		}
		addrs, ok := m["local_address"].([]any)
		if !ok || len(addrs) != 2 || addrs[0] != "172.16.0.2/32" || addrs[1] != "2606:4700:110:8f81:85e8:5350:2ff1:d0cf/128" {
			t.Fatalf("expected dual-stack addresses, got %v", m["local_address"])
		}
		if _, ok := m["reserved"]; ok {
			t.Fatalf("expected no reserved field, got %v", m["reserved"])
		}
		if m["mtu"] != float64(1420) {
			t.Fatalf("expected default mtu 1420, got %v", m["mtu"])
		}
	})
}

