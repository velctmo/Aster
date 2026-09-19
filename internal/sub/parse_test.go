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
	t.Run("URI format with options", func(t *testing.T) {
		raw := "tuic://11111111-1111-1111-1111-111111111111:my-pass@example.com:8443?congestion_controller=bbr&udp_relay_mode=native&alpn=h3&sni=example.com#tuic-node"
		r, err := Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		if len(r.Nodes) != 1 || r.Nodes[0].Protocol != "tuic" {
			t.Fatalf("got %+v", r.Nodes)
		}
		var m map[string]any
		if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
			t.Fatal(err)
		}
		if m["congestion_controller"] != "bbr" || m["congestion_control"] != "bbr" {
			t.Fatalf("expected congestion_controller/control bbr, got %v / %v", m["congestion_controller"], m["congestion_control"])
		}
		if m["udp_relay_mode"] != "native" {
			t.Fatalf("expected udp_relay_mode native, got %v", m["udp_relay_mode"])
		}
		if m["zero_rtt_handshake"] != true {
			t.Fatalf("expected zero_rtt_handshake true, got %v", m["zero_rtt_handshake"])
		}
		tls, ok := m["tls"].(map[string]any)
		if !ok {
			t.Fatalf("expected tls map, got %v", m["tls"])
		}
		if tls["server_name"] != "example.com" {
			t.Fatalf("expected server_name example.com, got %v", tls["server_name"])
		}
	})

	t.Run("URI format with reduce_rtt disabled", func(t *testing.T) {
		raw := "tuic://11111111-1111-1111-1111-111111111111:my-pass@example.com:8443?congestion-controller=cubic&udp-relay-mode=quic&reduce_rtt=0"
		r, err := Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
			t.Fatal(err)
		}
		if m["congestion_controller"] != "cubic" || m["congestion_control"] != "cubic" {
			t.Fatalf("expected congestion_controller/control cubic, got %v / %v", m["congestion_controller"], m["congestion_control"])
		}
		if m["udp_relay_mode"] != "quic" {
			t.Fatalf("expected udp_relay_mode quic, got %v", m["udp_relay_mode"])
		}
		if m["zero_rtt_handshake"] != false {
			t.Fatalf("expected zero_rtt_handshake false, got %v", m["zero_rtt_handshake"])
		}
	})

	t.Run("Clash YAML format full options", func(t *testing.T) {
		raw := `
proxies:
  - name: tuic-clash
    type: tuic
    server: example.com
    port: 8443
    uuid: 11111111-1111-1111-1111-111111111111
    password: my-pass
    congestion-controller: bbr
    udp-relay-mode: native
    reduce-rtt: true
    heartbeat: 10s
    sni: example.com
    alpn: [h3]
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		if len(r.Nodes) != 1 || r.Nodes[0].Protocol != "tuic" {
			t.Fatalf("got %+v", r.Nodes)
		}
		var m map[string]any
		if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
			t.Fatal(err)
		}
		if m["congestion_controller"] != "bbr" || m["congestion_control"] != "bbr" {
			t.Fatalf("expected congestion_controller/control bbr, got %v / %v", m["congestion_controller"], m["congestion_control"])
		}
		if m["udp_relay_mode"] != "native" {
			t.Fatalf("expected udp_relay_mode native, got %v", m["udp_relay_mode"])
		}
		if m["zero_rtt_handshake"] != true {
			t.Fatalf("expected zero_rtt_handshake true, got %v", m["zero_rtt_handshake"])
		}
		if m["heartbeat"] != "10s" {
			t.Fatalf("expected heartbeat 10s, got %v", m["heartbeat"])
		}
		tls, ok := m["tls"].(map[string]any)
		if !ok {
			t.Fatalf("expected tls map, got %v", m["tls"])
		}
		if tls["server_name"] != "example.com" {
			t.Fatalf("expected server_name example.com, got %v", tls["server_name"])
		}
	})

	t.Run("Clash YAML format variations", func(t *testing.T) {
		raw := `
proxies:
  - name: tuic-clash-2
    type: tuic
    server: example.com
    port: 8443
    uuid: 11111111-1111-1111-1111-111111111111
    password: my-pass
    congestion_controller: CUBIC
    udp_relay_mode: QUIC
    zero_rtt_handshake: false
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
			t.Fatal(err)
		}
		if m["congestion_controller"] != "cubic" || m["congestion_control"] != "cubic" {
			t.Fatalf("expected congestion_controller/control cubic, got %v / %v", m["congestion_controller"], m["congestion_control"])
		}
		if m["udp_relay_mode"] != "quic" {
			t.Fatalf("expected udp_relay_mode quic, got %v", m["udp_relay_mode"])
		}
		if m["zero_rtt_handshake"] != false {
			t.Fatalf("expected zero_rtt_handshake false, got %v", m["zero_rtt_handshake"])
		}
	})

	t.Run("Clash YAML default zero_rtt_handshake", func(t *testing.T) {
		raw := `
proxies:
  - name: tuic-default-zrtt
    type: tuic
    server: example.com
    port: 8443
    uuid: 11111111-1111-1111-1111-111111111111
    password: my-pass
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
			t.Fatal(err)
		}
		if m["zero_rtt_handshake"] != true {
			t.Fatalf("expected zero_rtt_handshake true by default, got %v", m["zero_rtt_handshake"])
		}
	})
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

func TestParseHysteria2_FullOptions(t *testing.T) {
	t.Run("ClashYAML_FlatObfsAndBandwidth", func(t *testing.T) {
		raw := `
proxies:
  - name: hy2-clash-flat
    type: hysteria2
    server: hy2.example.com
    port: 8443
    password: mypassword
    obfs: salamander
    obfs-password: secret
    up: "100 Mbps"
    down: "500 Mbps"
    sni: example.com
    skip-cert-verify: true
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatalf("Parse error: %v", err)
		}
		if len(r.Nodes) != 1 {
			t.Fatalf("expected 1 node, got %d", len(r.Nodes))
		}
		n := r.Nodes[0]
		if n.Protocol != "hysteria2" {
			t.Fatalf("expected protocol hysteria2, got %s", n.Protocol)
		}
		if n.Name != "hy2-clash-flat" {
			t.Fatalf("expected name hy2-clash-flat, got %s", n.Name)
		}

		var m map[string]any
		if err := json.Unmarshal(n.Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		if m["type"] != "hysteria2" {
			t.Fatalf("expected type hysteria2, got %v", m["type"])
		}
		if m["server"] != "hy2.example.com" {
			t.Fatalf("expected server hy2.example.com, got %v", m["server"])
		}
		if m["server_port"] != float64(8443) {
			t.Fatalf("expected server_port 8443, got %v", m["server_port"])
		}
		if m["password"] != "mypassword" {
			t.Fatalf("expected password mypassword, got %v", m["password"])
		}
		if m["up_mbps"] != float64(100) {
			t.Fatalf("expected up_mbps 100, got %v", m["up_mbps"])
		}
		if m["down_mbps"] != float64(500) {
			t.Fatalf("expected down_mbps 500, got %v", m["down_mbps"])
		}
		obfs, ok := m["obfs"].(map[string]any)
		if !ok {
			t.Fatalf("expected obfs object, got %v", m["obfs"])
		}
		if obfs["type"] != "salamander" {
			t.Fatalf("expected obfs type salamander, got %v", obfs["type"])
		}
		if obfs["password"] != "secret" {
			t.Fatalf("expected obfs password secret, got %v", obfs["password"])
		}
		tls, ok := m["tls"].(map[string]any)
		if !ok {
			t.Fatalf("expected tls object, got %v", m["tls"])
		}
		if tls["server_name"] != "example.com" {
			t.Fatalf("expected tls server_name example.com, got %v", tls["server_name"])
		}
		if tls["insecure"] != true {
			t.Fatalf("expected tls insecure true, got %v", tls["insecure"])
		}
	})

	t.Run("ClashYAML_NestedObfs", func(t *testing.T) {
		raw := `
proxies:
  - name: hy2-clash-nested
    type: hysteria2
    server: hy2.example.com
    port: 8443
    password: mypassword
    obfs:
      type: salamander
      password: nestedsecret
    up_mbps: 100
    down_mbps: 500
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatalf("Parse error: %v", err)
		}
		if len(r.Nodes) != 1 {
			t.Fatalf("expected 1 node, got %d", len(r.Nodes))
		}
		var m map[string]any
		if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		obfs, ok := m["obfs"].(map[string]any)
		if !ok {
			t.Fatalf("expected obfs object, got %v", m["obfs"])
		}
		if obfs["type"] != "salamander" || obfs["password"] != "nestedsecret" {
			t.Fatalf("unexpected obfs: %v", obfs)
		}
		if m["up_mbps"] != float64(100) {
			t.Fatalf("expected up_mbps 100, got %v", m["up_mbps"])
		}
		if m["down_mbps"] != float64(500) {
			t.Fatalf("expected down_mbps 500, got %v", m["down_mbps"])
		}
	})

	t.Run("URI_FullOptions", func(t *testing.T) {
		raw := "hysteria2://password@example.com:443?obfs=salamander&obfs-password=secret&up_mbps=100&down_mbps=500&sni=example.com#hy2-node"
		r, err := Parse(raw)
		if err != nil {
			t.Fatalf("Parse error: %v", err)
		}
		if len(r.Nodes) != 1 {
			t.Fatalf("expected 1 node, got %d", len(r.Nodes))
		}
		n := r.Nodes[0]
		if n.Protocol != "hysteria2" {
			t.Fatalf("expected protocol hysteria2, got %s", n.Protocol)
		}
		if n.Name != "hy2-node" {
			t.Fatalf("expected name hy2-node, got %s", n.Name)
		}
		var m map[string]any
		if err := json.Unmarshal(n.Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		if m["type"] != "hysteria2" {
			t.Fatalf("expected type hysteria2, got %v", m["type"])
		}
		if m["server"] != "example.com" {
			t.Fatalf("expected server example.com, got %v", m["server"])
		}
		if m["server_port"] != float64(443) {
			t.Fatalf("expected server_port 443, got %v", m["server_port"])
		}
		if m["password"] != "password" {
			t.Fatalf("expected password password, got %v", m["password"])
		}
		if m["up_mbps"] != float64(100) {
			t.Fatalf("expected up_mbps 100, got %v", m["up_mbps"])
		}
		if m["down_mbps"] != float64(500) {
			t.Fatalf("expected down_mbps 500, got %v", m["down_mbps"])
		}
		obfs, ok := m["obfs"].(map[string]any)
		if !ok {
			t.Fatalf("expected obfs object, got %v", m["obfs"])
		}
		if obfs["type"] != "salamander" {
			t.Fatalf("expected obfs type salamander, got %v", obfs["type"])
		}
		if obfs["password"] != "secret" {
			t.Fatalf("expected obfs password secret, got %v", obfs["password"])
		}
		tls, ok := m["tls"].(map[string]any)
		if !ok {
			t.Fatalf("expected tls object, got %v", m["tls"])
		}
		if tls["server_name"] != "example.com" {
			t.Fatalf("expected tls server_name example.com, got %v", tls["server_name"])
		}
	})

	t.Run("OmitEmptyObfsAndBandwidth", func(t *testing.T) {
		raw := `
proxies:
  - name: hy2-simple
    type: hysteria2
    server: hy2.example.com
    port: 443
    password: mypassword
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatalf("Parse error: %v", err)
		}
		var m map[string]any
		if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		if _, ok := m["obfs"]; ok {
			t.Fatalf("expected no obfs, got %v", m["obfs"])
		}
		if _, ok := m["up_mbps"]; ok {
			t.Fatalf("expected no up_mbps, got %v", m["up_mbps"])
		}
		if _, ok := m["down_mbps"]; ok {
			t.Fatalf("expected no down_mbps, got %v", m["down_mbps"])
		}
	})

	t.Run("BandwidthStringVariations", func(t *testing.T) {
		raw := `
proxies:
  - name: hy2-bw
    type: hysteria2
    server: hy2.example.com
    port: 443
    password: mypassword
    up: "100 mbps"
    down: "500MB/s"
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatalf("Parse error: %v", err)
		}
		var m map[string]any
		if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		if m["up_mbps"] != float64(100) {
			t.Fatalf("expected up_mbps 100, got %v", m["up_mbps"])
		}
		if m["down_mbps"] != float64(500) {
			t.Fatalf("expected down_mbps 500, got %v", m["down_mbps"])
		}
	})
}

func TestParseShadowTLS(t *testing.T) {
	t.Run("ClashYAML Standard", func(t *testing.T) {
		raw := `
proxies:
  - name: st-node
    type: shadowtls
    server: 1.2.3.4
    port: 443
    password: "secret"
    version: 3
    sni: gateway.icloud.com
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatalf("Parse error: %v", err)
		}
		if len(r.Nodes) != 1 {
			t.Fatalf("expected 1 node, got %d", len(r.Nodes))
		}
		node := r.Nodes[0]
		if node.Protocol != "shadowtls" {
			t.Fatalf("expected protocol shadowtls, got %s", node.Protocol)
		}
		if node.Name != "st-node" {
			t.Fatalf("expected name st-node, got %s", node.Name)
		}

		var m map[string]any
		if err := json.Unmarshal(node.Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		if m["type"] != "shadowtls" {
			t.Fatalf("expected type shadowtls, got %v", m["type"])
		}
		if m["tag"] != "st-node" {
			t.Fatalf("expected tag st-node, got %v", m["tag"])
		}
		if m["server"] != "1.2.3.4" {
			t.Fatalf("expected server 1.2.3.4, got %v", m["server"])
		}
		if m["server_port"] != float64(443) {
			t.Fatalf("expected server_port 443, got %v", m["server_port"])
		}
		if m["version"] != float64(3) {
			t.Fatalf("expected version 3, got %v", m["version"])
		}
		if m["password"] != "secret" {
			t.Fatalf("expected password secret, got %v", m["password"])
		}
		tls, ok := m["tls"].(map[string]any)
		if !ok {
			t.Fatalf("expected tls map, got %v", m["tls"])
		}
		if tls["enabled"] != true {
			t.Fatalf("expected tls enabled true, got %v", tls["enabled"])
		}
		if tls["server_name"] != "gateway.icloud.com" {
			t.Fatalf("expected tls server_name gateway.icloud.com, got %v", tls["server_name"])
		}
	})

	t.Run("ClashYAML Variations", func(t *testing.T) {
		raw := `
proxies:
  - name: st-opts
    type: shadowtls
    server: 2.3.4.5
    port: 8443
    password: "secret2"
    servername: server.apple.com
    strict-mode: true
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatalf("Parse error: %v", err)
		}
		if len(r.Nodes) != 1 {
			t.Fatalf("expected 1 node, got %d", len(r.Nodes))
		}
		var m map[string]any
		if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		if m["version"] != float64(3) {
			t.Fatalf("expected default version 3, got %v", m["version"])
		}
		if m["strict_mode"] != true {
			t.Fatalf("expected strict_mode true, got %v", m["strict_mode"])
		}
		tls := m["tls"].(map[string]any)
		if tls["server_name"] != "server.apple.com" {
			t.Fatalf("expected tls server_name server.apple.com, got %v", tls["server_name"])
		}
	})

	t.Run("ClashYAML Host Fallback and String Version", func(t *testing.T) {
		raw := `
proxies:
  - name: st-host
    type: shadowtls
    server: 3.4.5.6
    port: 443
    password: "pwd"
    version: "2"
    host: domain.example.com
`
		r, err := Parse(raw)
		if err != nil {
			t.Fatalf("Parse error: %v", err)
		}
		var m map[string]any
		if err := json.Unmarshal(r.Nodes[0].Outbound, &m); err != nil {
			t.Fatalf("unmarshal outbound: %v", err)
		}
		if m["version"] != float64(2) {
			t.Fatalf("expected version 2, got %v", m["version"])
		}
		tls := m["tls"].(map[string]any)
		if tls["server_name"] != "domain.example.com" {
			t.Fatalf("expected tls server_name domain.example.com, got %v", tls["server_name"])
		}
	})
}

