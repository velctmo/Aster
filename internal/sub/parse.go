package sub

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"aster/internal/state"

	"gopkg.in/yaml.v3"
)

type ParseResult struct {
	Nodes   []state.Node
	Skipped int
	Warning []string
}

func Parse(raw string) (ParseResult, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ParseResult{}, fmt.Errorf("内容为空")
	}
	if looksJSON(raw) {
		if r, err := parseSingBox(raw); err == nil && len(r.Nodes) > 0 {
			return r, nil
		}
	}
	if r, err := parseClashYAML(raw); err == nil && len(r.Nodes) > 0 {
		return r, nil
	}
	decoded := decodeMaybeBase64(raw)
	if r, err := parseURIList(decoded); err == nil && len(r.Nodes) > 0 {
		return r, nil
	}
	if decoded != raw {
		if r, err := parseClashYAML(decoded); err == nil && len(r.Nodes) > 0 {
			return r, nil
		}
		if looksJSON(decoded) {
			if r, err := parseSingBox(decoded); err == nil && len(r.Nodes) > 0 {
				return r, nil
			}
		}
	}
	return ParseResult{}, fmt.Errorf("无法识别这份订阅。请改用 Clash YAML、sing-box JSON 或 vless:// 链接")
}

func FilterNodes(nodes []state.Node, exclude string) []state.Node {
	exclude = strings.TrimSpace(exclude)
	if exclude == "" {
		return nodes
	}
	re, err := regexp.Compile(exclude)
	if err != nil {
		return nodes
	}
	out := make([]state.Node, 0, len(nodes))
	for _, n := range nodes {
		if re.MatchString(n.Name) {
			continue
		}
		out = append(out, n)
	}
	return out
}

func looksJSON(s string) bool {
	s = strings.TrimSpace(s)
	return strings.HasPrefix(s, "{") || strings.HasPrefix(s, "[")
}

func decodeMaybeBase64(s string) string {
	compact := strings.ReplaceAll(strings.TrimSpace(s), "\n", "")
	compact = strings.ReplaceAll(compact, "\r", "")
	if compact == "" || strings.Contains(compact, "://") || strings.Contains(compact, "proxies:") {
		return s
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.URLEncoding, base64.RawStdEncoding, base64.RawURLEncoding} {
		b, err := enc.DecodeString(compact)
		if err == nil && looksLikeSub(string(b)) {
			return string(b)
		}
	}
	return s
}

func looksLikeSub(s string) bool {
	t := strings.TrimSpace(s)
	return strings.Contains(t, "://") || strings.Contains(t, "proxies:") || strings.Contains(t, "outbounds") || strings.HasPrefix(t, "{") || strings.HasPrefix(t, "[")
}

func parseSingBox(raw string) (ParseResult, error) {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &obj); err != nil {
		var arr []json.RawMessage
		if err2 := json.Unmarshal([]byte(raw), &arr); err2 != nil {
			return ParseResult{}, err
		}
		return nodesFromOutbounds(arr)
	}
	if ob, ok := obj["outbounds"]; ok {
		var arr []json.RawMessage
		if err := json.Unmarshal(ob, &arr); err != nil {
			return ParseResult{}, err
		}
		return nodesFromOutbounds(arr)
	}
	return ParseResult{}, fmt.Errorf("no outbounds")
}

func nodesFromOutbounds(arr []json.RawMessage) (ParseResult, error) {
	var r ParseResult
	skip := map[string]bool{"direct": true, "block": true, "dns": true, "selector": true, "urltest": true, "reject": true}
	for _, raw := range arr {
		var meta struct {
			Type string `json:"type"`
			Tag  string `json:"tag"`
		}
		if err := json.Unmarshal(raw, &meta); err != nil {
			r.Skipped++
			continue
		}
		if skip[meta.Type] || meta.Type == "" {
			continue
		}
		if meta.Type == "anytls" {
			raw = stripTFO(raw, &r)
		}
		name := meta.Tag
		if name == "" {
			name = meta.Type + "-" + state.NewID()[:6]
		}
		r.Nodes = append(r.Nodes, state.Node{
			ID:       state.NewID(),
			Name:     name,
			Protocol: meta.Type,
			Outbound: raw,
		})
	}
	if len(r.Nodes) == 0 {
		return r, fmt.Errorf("no nodes")
	}
	return r, nil
}

func stripTFO(raw json.RawMessage, r *ParseResult) json.RawMessage {
	var m map[string]any
	if json.Unmarshal(raw, &m) != nil {
		return raw
	}
	if v, ok := m["tcp_fast_open"].(bool); ok && v {
		delete(m, "tcp_fast_open")
		r.Warning = append(r.Warning, "anytls 不支持 TFO，已忽略")
		b, _ := json.Marshal(m)
		return b
	}
	return raw
}

type clashFile struct {
	Proxies []map[string]any `yaml:"proxies"`
}

func parseClashYAML(raw string) (ParseResult, error) {
	var f clashFile
	if err := yaml.Unmarshal([]byte(raw), &f); err != nil {
		return ParseResult{}, err
	}
	if len(f.Proxies) == 0 {
		return ParseResult{}, fmt.Errorf("no proxies")
	}
	var r ParseResult
	for _, p := range f.Proxies {
		n, err := clashProxy(p)
		if err != nil {
			r.Skipped++
			r.Warning = append(r.Warning, err.Error())
			continue
		}
		r.Nodes = append(r.Nodes, n)
	}
	if len(r.Nodes) == 0 {
		return r, fmt.Errorf("no nodes")
	}
	return r, nil
}

func clashProxy(p map[string]any) (state.Node, error) {
	typ := strings.ToLower(str(p["type"]))
	name := str(p["name"])
	if name == "" {
		name = typ
	}
	ob, err := clashToOutbound(p, typ, name)
	if err != nil {
		return state.Node{}, err
	}
	if typ == "ss" {
		typ = "shadowsocks"
	}
	if typ == "wg" {
		typ = "wireguard"
	}
	return state.Node{ID: state.NewID(), Name: name, Protocol: typ, Outbound: ob}, nil
}

func clashToOutbound(p map[string]any, typ, tag string) (json.RawMessage, error) {
	server := str(p["server"])
	port := intVal(p["port"])
	if server == "" || port == 0 {
		return nil, fmt.Errorf("节点 %s 缺 server/port", tag)
	}
	m := map[string]any{
		"type":        mapType(typ),
		"tag":         tag,
		"server":      server,
		"server_port": port,
	}
	if boolVal(p["tfo"]) || boolVal(p["tcp-fast-open"]) {
		if mapType(typ) != "anytls" {
			m["tcp_fast_open"] = true
		}
	}
	if boolVal(p["tcp-multi-path"]) || boolVal(p["tcp_multi_path"]) {
		m["tcp_multi_path"] = true
	}
	if boolVal(p["udp-fragment"]) || boolVal(p["udp_fragment"]) {
		m["udp_fragment"] = true
	}
	switch mapType(typ) {
	case "wireguard":
		privKey := first(str(p["private-key"]), str(p["private_key"]))
		peerPubKey := first(str(p["public-key"]), str(p["public_key"]), str(p["peer-public-key"]), str(p["peer_public_key"]))
		m["private_key"] = privKey
		m["peer_public_key"] = peerPubKey
		if psk := first(str(p["preshared-key"]), str(p["preshared_key"]), str(p["pre-shared-key"]), str(p["pre_shared_key"])); psk != "" {
			m["pre_shared_key"] = psk
		}
		localAddrs := parseWireGuardAddresses(p["ip"], p["ips"], p["local-address"], p["local_address"], p["address"])
		if localAddrs == nil {
			localAddrs = []string{}
		}
		m["local_address"] = localAddrs
		reserved := parseWireGuardReserved(p["reserved"])
		if len(reserved) > 0 {
			m["reserved"] = reserved
		}
		mtu := intVal(p["mtu"])
		if mtu == 0 {
			mtu = 1420
		}
		m["mtu"] = mtu
	case "shadowsocks":
		m["method"] = str(p["cipher"])
		m["password"] = str(p["password"])
		if plugin := str(p["plugin"]); plugin != "" {
			m["plugin"] = plugin
			m["plugin_opts"] = pluginOpts(p["plugin-opts"])
		}
	case "trojan":
		m["password"] = str(p["password"])
		applyTLS(m, p, true)
		applyTransport(m, p)
	case "vmess":
		m["uuid"] = str(p["uuid"])
		if alter := intVal(p["alterId"]); alter != 0 {
			m["alter_id"] = alter
		}
		if sec := str(p["cipher"]); sec != "" {
			m["security"] = sec
		}
		applyTLS(m, p, boolVal(p["tls"]))
		applyTransport(m, p)
	case "vless":
		m["uuid"] = str(p["uuid"])
		if flow := str(p["flow"]); flow != "" {
			m["flow"] = flow
		}
		tlsOn := boolVal(p["tls"]) || str(p["security"]) == "tls" || str(p["security"]) == "reality"
		applyTLS(m, p, tlsOn)
		applyTransport(m, p)
	case "hysteria2", "hysteria":
		if pw := str(p["password"]); pw != "" {
			m["password"] = pw
		} else if auth := str(p["auth"]); auth != "" {
			m["password"] = auth
		}
		applyTLS(m, p, true)
		if obfs := parseHysteria2Obfs(p); obfs != nil {
			m["obfs"] = obfs
		}
		if up := parseBandwidthMbps(getFirst(p, "up_mbps", "up-mbps", "up")); up > 0 {
			m["up_mbps"] = up
		}
		if down := parseBandwidthMbps(getFirst(p, "down_mbps", "down-mbps", "down")); down > 0 {
			m["down_mbps"] = down
		}
	case "tuic":
		m["uuid"] = first(str(p["uuid"]), str(p["token"]))
		m["password"] = str(p["password"])
		if cc := strings.ToLower(str(getFirst(p, "congestion-controller", "congestion_controller"))); cc != "" {
			m["congestion_controller"] = cc
		}
		if urm := strings.ToLower(str(getFirst(p, "udp-relay-mode", "udp_relay_mode"))); urm != "" {
			m["udp_relay_mode"] = urm
		}
		if v := getFirst(p, "zero-rtt-handshake", "zero_rtt_handshake", "reduce-rtt", "reduce_rtt"); v != nil {
			m["zero_rtt_handshake"] = boolVal(v)
		} else {
			m["zero_rtt_handshake"] = true
		}
		if hb := str(getFirst(p, "heartbeat", "heartbeat-interval", "heartbeat_interval")); hb != "" {
			if _, err := strconv.Atoi(hb); err == nil {
				hb = hb + "s"
			}
			m["heartbeat"] = hb
		}
		applyTLS(m, p, true)
	case "anytls":
		m["password"] = str(p["password"])
		applyTLS(m, p, true)
	case "http", "socks", "socks5":
		if mapType(typ) == "socks5" {
			m["type"] = "socks"
		}
		if u := str(p["username"]); u != "" {
			m["username"] = u
			m["password"] = str(p["password"])
		}
	default:
		return nil, fmt.Errorf("不支持协议 %s", typ)
	}
	b, err := json.Marshal(m)
	return b, err
}

func mapType(t string) string {
	switch strings.ToLower(t) {
	case "ss":
		return "shadowsocks"
	case "socks5":
		return "socks"
	case "hysteria2", "hy2":
		return "hysteria2"
	case "wg", "wireguard":
		return "wireguard"
	default:
		return strings.ToLower(t)
	}
}

func applyTLS(m map[string]any, p map[string]any, enabled bool) {
	if !enabled && str(p["sni"]) == "" && !boolVal(p["skip-cert-verify"]) {
		if _, ok := p["reality-opts"]; !ok {
			return
		}
	}
	tls := map[string]any{"enabled": true}
	if sni := first(str(p["sni"]), str(p["servername"])); sni != "" {
		tls["server_name"] = sni
	}
	if boolVal(p["skip-cert-verify"]) {
		tls["insecure"] = true
	}
	if fp := str(p["client-fingerprint"]); fp != "" {
		tls["utls"] = map[string]any{"enabled": true, "fingerprint": fp}
	}
	if alpn := p["alpn"]; alpn != nil {
		switch v := alpn.(type) {
		case string:
			if v != "" {
				tls["alpn"] = strings.Split(v, ",")
			}
		default:
			tls["alpn"] = alpn
		}
	}
	if ro, ok := p["reality-opts"].(map[string]any); ok {
		tls["reality"] = map[string]any{
			"enabled":    true,
			"public_key": str(ro["public-key"]),
			"short_id":   str(ro["short-id"]),
		}
	}
	m["tls"] = tls
}

func applyTransport(m map[string]any, p map[string]any) {
	netw := strings.ToLower(first(str(p["network"]), str(p["net"])))
	switch netw {
	case "", "tcp":
		return
	case "ws":
		t := map[string]any{"type": "ws"}
		opts, _ := p["ws-opts"].(map[string]any)
		if opts == nil {
			opts, _ = p["ws_opts"].(map[string]any)
		}
		if opts != nil {
			if path := str(opts["path"]); path != "" {
				t["path"] = path
			}
			if h, ok := opts["headers"].(map[string]any); ok {
				t["headers"] = h
			}
		} else if path := str(p["ws-path"]); path != "" {
			t["path"] = path
		}
		m["transport"] = t
	case "grpc":
		t := map[string]any{"type": "grpc"}
		opts, _ := p["grpc-opts"].(map[string]any)
		if opts != nil {
			if sn := str(opts["grpc-service-name"]); sn != "" {
				t["service_name"] = sn
			}
		}
		m["transport"] = t
	case "http", "h2":
		m["transport"] = map[string]any{"type": "http"}
	case "httpupgrade":
		m["transport"] = map[string]any{"type": "httpupgrade"}
	}
}

func parseURIList(raw string) (ParseResult, error) {
	var r ParseResult
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		n, err := ParseURI(line)
		if err != nil {
			r.Skipped++
			continue
		}
		r.Nodes = append(r.Nodes, n)
	}
	if len(r.Nodes) == 0 {
		return r, fmt.Errorf("no uris")
	}
	return r, nil
}

func ParseURI(line string) (state.Node, error) {
	u, err := url.Parse(strings.TrimSpace(line))
	if err != nil {
		return state.Node{}, err
	}
	switch strings.ToLower(u.Scheme) {
	case "vless":
		return vlessURI(u)
	case "trojan":
		return trojanURI(u)
	case "ss":
		return ssURI(line)
	case "vmess":
		return vmessURI(line)
	case "hysteria2", "hy2":
		return hy2URI(u)
	case "tuic":
		return tuicURI(u)
	case "wireguard", "wg":
		return wireguardURI(line, u)
	default:
		return state.Node{}, fmt.Errorf("unknown scheme")
	}
}

func vlessURI(u *url.URL) (state.Node, error) {
	q := u.Query()
	uuid := u.User.Username()
	host := u.Hostname()
	port := intVal(u.Port())
	if port == 0 {
		port = 443
	}
	name := first(u.Fragment, host)
	m := map[string]any{
		"type":        "vless",
		"tag":         name,
		"server":      host,
		"server_port": port,
		"uuid":        uuid,
	}
	if flow := q.Get("flow"); flow != "" {
		m["flow"] = flow
	}
	sec := strings.ToLower(q.Get("security"))
	if sec == "tls" || sec == "reality" || q.Get("sni") != "" {
		tls := map[string]any{"enabled": true}
		if sni := first(q.Get("sni"), q.Get("servername")); sni != "" {
			tls["server_name"] = sni
		}
		if q.Get("allowInsecure") == "1" {
			tls["insecure"] = true
		}
		if fp := q.Get("fp"); fp != "" {
			tls["utls"] = map[string]any{"enabled": true, "fingerprint": fp}
		}
		if sec == "reality" {
			tls["reality"] = map[string]any{
				"enabled":    true,
				"public_key": q.Get("pbk"),
				"short_id":   q.Get("sid"),
			}
		}
		m["tls"] = tls
	}
	typ := strings.ToLower(first(q.Get("type"), q.Get("network")))
	switch typ {
	case "ws":
		t := map[string]any{"type": "ws", "path": first(q.Get("path"), "/")}
		if host := q.Get("host"); host != "" {
			t["headers"] = map[string]any{"Host": host}
		}
		m["transport"] = t
	case "grpc":
		m["transport"] = map[string]any{"type": "grpc", "service_name": q.Get("serviceName")}
	case "httpupgrade":
		m["transport"] = map[string]any{"type": "httpupgrade", "path": q.Get("path")}
	}
	b, _ := json.Marshal(m)
	return state.Node{ID: state.NewID(), Name: name, Protocol: "vless", Outbound: b}, nil
}

func trojanURI(u *url.URL) (state.Node, error) {
	q := u.Query()
	pw, _ := u.User.Password()
	if pw == "" {
		pw = u.User.Username()
	}
	name := first(u.Fragment, u.Hostname())
	m := map[string]any{
		"type":        "trojan",
		"tag":         name,
		"server":      u.Hostname(),
		"server_port": intVal(u.Port()),
		"password":    pw,
		"tls":         map[string]any{"enabled": true, "server_name": first(q.Get("sni"), u.Hostname())},
	}
	if u.Port() == "" {
		m["server_port"] = 443
	}
	b, _ := json.Marshal(m)
	return state.Node{ID: state.NewID(), Name: name, Protocol: "trojan", Outbound: b}, nil
}

func ssURI(line string) (state.Node, error) {
	u, err := url.Parse(line)
	if err != nil {
		return state.Node{}, err
	}
	name := first(u.Fragment, u.Host)
	userinfo := u.User.String()
	method, password := "", ""
	if decoded, err := base64.URLEncoding.DecodeString(userinfo); err == nil && strings.Contains(string(decoded), ":") {
		parts := strings.SplitN(string(decoded), ":", 2)
		method, password = parts[0], parts[1]
	} else if decoded, err := base64.StdEncoding.DecodeString(userinfo); err == nil && strings.Contains(string(decoded), ":") {
		parts := strings.SplitN(string(decoded), ":", 2)
		method, password = parts[0], parts[1]
	} else {
		method = u.User.Username()
		password, _ = u.User.Password()
	}
	port := intVal(u.Port())
	if port == 0 {
		port = 443
	}
	m := map[string]any{
		"type":        "shadowsocks",
		"tag":         name,
		"server":      u.Hostname(),
		"server_port": port,
		"method":      method,
		"password":    password,
	}
	if plugin := u.Query().Get("plugin"); plugin != "" {
		parts := strings.SplitN(plugin, ";", 2)
		m["plugin"] = parts[0]
		if len(parts) > 1 {
			m["plugin_opts"] = parts[1]
		}
	}
	b, _ := json.Marshal(m)
	return state.Node{ID: state.NewID(), Name: name, Protocol: "shadowsocks", Outbound: b}, nil
}

func tuicURI(u *url.URL) (state.Node, error) {
	q := u.Query()
	name := first(u.Fragment, u.Hostname())
	var uuid, pw string
	if u.User != nil {
		uuid = u.User.Username()
		pw, _ = u.User.Password()
	}
	port := intVal(u.Port())
	if port == 0 {
		port = 443
	}
	sni := first(q.Get("sni"), q.Get("peer"), u.Hostname())
	tlsMap := map[string]any{"enabled": true, "server_name": sni}
	if alpn := q.Get("alpn"); alpn != "" {
		tlsMap["alpn"] = strings.Split(alpn, ",")
	}
	if q.Get("allow_insecure") == "1" || q.Get("insecure") == "1" || strings.EqualFold(q.Get("allow_insecure"), "true") || strings.EqualFold(q.Get("insecure"), "true") {
		tlsMap["insecure"] = true
	}
	m := map[string]any{
		"type":        "tuic",
		"tag":         name,
		"server":      u.Hostname(),
		"server_port": port,
		"uuid":        uuid,
		"password":    pw,
		"tls":         tlsMap,
	}
	if cc := strings.ToLower(first(q.Get("congestion_controller"), q.Get("congestion-controller"), q.Get("congestion_control"), q.Get("congestion-control"))); cc != "" {
		m["congestion_controller"] = cc
	}
	if urm := strings.ToLower(first(q.Get("udp_relay_mode"), q.Get("udp-relay-mode"))); urm != "" {
		m["udp_relay_mode"] = urm
	}
	zrttStr := first(q.Get("zero_rtt_handshake"), q.Get("zero-rtt-handshake"), q.Get("reduce_rtt"), q.Get("reduce-rtt"))
	if zrttStr != "" && (zrttStr == "0" || strings.EqualFold(zrttStr, "false")) {
		m["zero_rtt_handshake"] = false
	} else {
		m["zero_rtt_handshake"] = true
	}
	if hb := first(q.Get("heartbeat"), q.Get("heartbeat-interval"), q.Get("heartbeat_interval")); hb != "" {
		if _, err := strconv.Atoi(hb); err == nil {
			hb = hb + "s"
		}
		m["heartbeat"] = hb
	}
	b, _ := json.Marshal(m)
	return state.Node{ID: state.NewID(), Name: name, Protocol: "tuic", Outbound: b}, nil
}

func vmessURI(line string) (state.Node, error) {
	payload := strings.TrimPrefix(line, "vmess://")
	b, err := base64.StdEncoding.DecodeString(payload)
	if err != nil {
		b, err = base64.RawStdEncoding.DecodeString(payload)
		if err != nil {
			b, err = base64.URLEncoding.DecodeString(payload)
		}
	}
	if err != nil {
		return state.Node{}, err
	}
	var v map[string]any
	if err := json.Unmarshal(b, &v); err != nil {
		return state.Node{}, err
	}
	name := first(str(v["ps"]), str(v["add"]))
	m := map[string]any{
		"type":        "vmess",
		"tag":         name,
		"server":      str(v["add"]),
		"server_port": intVal(v["port"]),
		"uuid":        str(v["id"]),
		"security":    first(str(v["scy"]), "auto"),
	}
	if tls := str(v["tls"]); tls == "tls" {
		applyTLS(m, map[string]any{"tls": true, "sni": first(str(v["sni"]), str(v["host"]))}, true)
	}
	if netw := str(v["net"]); netw != "" && netw != "tcp" {
		applyTransport(m, map[string]any{"network": netw, "ws-opts": map[string]any{"path": str(v["path"]), "headers": map[string]any{"Host": str(v["host"])}}})
	}
	raw, _ := json.Marshal(m)
	return state.Node{ID: state.NewID(), Name: name, Protocol: "vmess", Outbound: raw}, nil
}

var bandwidthRe = regexp.MustCompile(`(?i)^([0-9]+(?:\.[0-9]+)?)\s*([a-z/]*)$`)

func parseBandwidthMbps(v any) int {
	if v == nil {
		return 0
	}
	switch val := v.(type) {
	case int:
		if val > 0 {
			return val
		}
		return 0
	case int64:
		if val > 0 {
			return int(val)
		}
		return 0
	case float64:
		if val > 0 {
			return int(val)
		}
		return 0
	case string:
		s := strings.TrimSpace(val)
		if s == "" {
			return 0
		}
		matches := bandwidthRe.FindStringSubmatch(s)
		if len(matches) < 2 {
			return 0
		}
		num, err := strconv.ParseFloat(matches[1], 64)
		if err != nil || num <= 0 {
			return 0
		}
		unit := strings.ToLower(strings.TrimSpace(matches[2]))
		switch {
		case strings.HasPrefix(unit, "g"):
			return int(num * 1000)
		case strings.HasPrefix(unit, "k"):
			return int(num / 1000)
		default:
			return int(num)
		}
	default:
		return 0
	}
}

func getFirst(p map[string]any, keys ...string) any {
	for _, k := range keys {
		if v, ok := p[k]; ok && v != nil {
			return v
		}
	}
	return nil
}

func parseHysteria2Obfs(p map[string]any) map[string]any {
	obfsVal, ok := p["obfs"]
	if !ok || obfsVal == nil {
		return nil
	}
	switch v := obfsVal.(type) {
	case map[string]any:
		obfsType := str(v["type"])
		if obfsType == "" {
			obfsType = "salamander"
		}
		if strings.ToLower(obfsType) == "none" {
			return nil
		}
		obfsPass := first(str(v["password"]), str(v["obfs-password"]), str(v["obfs_password"]), str(p["obfs-password"]), str(p["obfs_password"]))
		return map[string]any{
			"type":     obfsType,
			"password": obfsPass,
		}
	case map[any]any:
		vMap := make(map[string]any)
		for k, val := range v {
			vMap[fmt.Sprint(k)] = val
		}
		obfsType := str(vMap["type"])
		if obfsType == "" {
			obfsType = "salamander"
		}
		if strings.ToLower(obfsType) == "none" {
			return nil
		}
		obfsPass := first(str(vMap["password"]), str(vMap["obfs-password"]), str(vMap["obfs_password"]), str(p["obfs-password"]), str(p["obfs_password"]))
		return map[string]any{
			"type":     obfsType,
			"password": obfsPass,
		}
	case string:
		obfsType := strings.TrimSpace(v)
		if obfsType == "" || strings.ToLower(obfsType) == "none" {
			return nil
		}
		obfsPass := first(str(p["obfs-password"]), str(p["obfs_password"]))
		return map[string]any{
			"type":     obfsType,
			"password": obfsPass,
		}
	case bool:
		if !v {
			return nil
		}
		obfsPass := first(str(p["obfs-password"]), str(p["obfs_password"]))
		return map[string]any{
			"type":     "salamander",
			"password": obfsPass,
		}
	default:
		return nil
	}
}

func hy2URI(u *url.URL) (state.Node, error) {
	q := u.Query()
	name := first(u.Fragment, u.Hostname())
	pw, _ := u.User.Password()
	if pw == "" {
		pw = u.User.Username()
	}
	port := intVal(u.Port())
	if port == 0 {
		port = 443
	}
	tlsMap := map[string]any{
		"enabled":     true,
		"server_name": first(q.Get("sni"), q.Get("peer"), q.Get("servername"), u.Hostname()),
	}
	if q.Get("insecure") == "1" || q.Get("insecure") == "true" || q.Get("allowInsecure") == "1" || q.Get("skip-cert-verify") == "1" || q.Get("skip-cert-verify") == "true" {
		tlsMap["insecure"] = true
	}
	if alpn := q.Get("alpn"); alpn != "" {
		tlsMap["alpn"] = strings.Split(alpn, ",")
	}
	m := map[string]any{
		"type":        "hysteria2",
		"tag":         name,
		"server":      u.Hostname(),
		"server_port": port,
		"password":    pw,
		"tls":         tlsMap,
	}
	obfsType := first(q.Get("obfs"), q.Get("obfs-type"), q.Get("obfs_type"))
	if obfsType != "" && strings.ToLower(obfsType) != "none" {
		obfsPass := first(q.Get("obfs-password"), q.Get("obfs_password"), q.Get("obfs-param"), q.Get("obfs_param"))
		m["obfs"] = map[string]any{
			"type":     obfsType,
			"password": obfsPass,
		}
	}
	if up := parseBandwidthMbps(first(q.Get("up_mbps"), q.Get("up-mbps"), q.Get("up"))); up > 0 {
		m["up_mbps"] = up
	}
	if down := parseBandwidthMbps(first(q.Get("down_mbps"), q.Get("down-mbps"), q.Get("down"))); down > 0 {
		m["down_mbps"] = down
	}
	b, _ := json.Marshal(m)
	return state.Node{ID: state.NewID(), Name: name, Protocol: "hysteria2", Outbound: b}, nil
}

func str(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case int:
		return strconv.Itoa(t)
	case int64:
		return strconv.FormatInt(t, 10)
	case float64:
		return strconv.FormatInt(int64(t), 10)
	case bool:
		if t {
			return "true"
		}
		return "false"
	default:
		return ""
	}
}

func intVal(v any) int {
	switch t := v.(type) {
	case int:
		return t
	case int64:
		return int(t)
	case float64:
		return int(t)
	case string:
		n, _ := strconv.Atoi(t)
		return n
	default:
		return 0
	}
}

func boolVal(v any) bool {
	switch t := v.(type) {
	case bool:
		return t
	case string:
		return t == "true" || t == "1"
	default:
		return false
	}
}

func pluginOpts(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case map[string]any:
		var parts []string
		for k, val := range t {
			if nested, ok := val.(map[string]any); ok {
				for nk, nv := range nested {
					parts = append(parts, fmt.Sprintf("%s=%v", nk, nv))
				}
				continue
			}
			parts = append(parts, fmt.Sprintf("%s=%v", k, val))
		}
		return strings.Join(parts, ";")
	default:
		return str(v)
	}
}

func first(a ...string) string {
	for _, s := range a {
		if s != "" {
			return s
		}
	}
	return ""
}

func wireguardURI(line string, u *url.URL) (state.Node, error) {
	name := ""
	if u != nil && u.Fragment != "" {
		name = u.Fragment
	} else if fIdx := strings.Index(line, "#"); fIdx != -1 {
		name, _ = url.QueryUnescape(line[fIdx+1:])
	}

	var privKey, hostPort string
	idx := strings.Index(line, "://")
	if idx != -1 {
		rest := line[idx+3:]
		if f := strings.Index(rest, "#"); f != -1 {
			rest = rest[:f]
		}
		if q := strings.Index(rest, "?"); q != -1 {
			rest = rest[:q]
		}
		if at := strings.LastIndex(rest, "@"); at != -1 {
			privKey, _ = url.QueryUnescape(rest[:at])
			hostPort = rest[at+1:]
		} else {
			hostPort = rest
		}
	} else if u != nil {
		if u.User != nil {
			privKey = u.User.Username()
		}
		hostPort = u.Host
	}

	var server string
	var port int
	if h, pStr, err := net.SplitHostPort(hostPort); err == nil {
		server = h
		port = intVal(pStr)
	} else {
		server = hostPort
		port = 51820
	}
	if port == 0 {
		port = 51820
	}
	if name == "" {
		name = server
	}

	var q url.Values
	if u != nil && len(u.Query()) > 0 {
		q = u.Query()
	} else if qIdx := strings.Index(line, "?"); qIdx != -1 {
		qPart := line[qIdx+1:]
		if fIdx := strings.Index(qPart, "#"); fIdx != -1 {
			qPart = qPart[:fIdx]
		}
		q, _ = url.ParseQuery(qPart)
	} else {
		q = make(url.Values)
	}

	peerPubKey := first(q.Get("public_key"), q.Get("public-key"), q.Get("peer_public_key"), q.Get("peer-public-key"), q.Get("pubkey"), q.Get("pbk"))
	if privKey == "" {
		privKey = first(q.Get("private_key"), q.Get("private-key"))
	}
	psk := first(q.Get("preshared_key"), q.Get("preshared-key"), q.Get("pre_shared_key"), q.Get("pre-shared-key"), q.Get("psk"))

	var addrVals []any
	for _, a := range q["address"] {
		addrVals = append(addrVals, a)
	}
	for _, a := range q["ip"] {
		addrVals = append(addrVals, a)
	}
	for _, a := range q["ips"] {
		addrVals = append(addrVals, a)
	}
	for _, a := range q["local_address"] {
		addrVals = append(addrVals, a)
	}
	localAddrs := parseWireGuardAddresses(addrVals...)
	if localAddrs == nil {
		localAddrs = []string{}
	}

	reserved := parseWireGuardReserved(first(q.Get("reserved"), q.Get("reserved_bytes")))
	mtu := intVal(q.Get("mtu"))
	if mtu == 0 {
		mtu = 1420
	}

	m := map[string]any{
		"type":            "wireguard",
		"tag":             name,
		"server":          server,
		"server_port":     port,
		"local_address":   localAddrs,
		"private_key":     privKey,
		"peer_public_key": peerPubKey,
		"mtu":             mtu,
	}
	if psk != "" {
		m["pre_shared_key"] = psk
	}
	if len(reserved) > 0 {
		m["reserved"] = reserved
	}

	b, _ := json.Marshal(m)
	return state.Node{ID: state.NewID(), Name: name, Protocol: "wireguard", Outbound: b}, nil
}

func parseWireGuardAddresses(vals ...any) []string {
	var addrs []string
	seen := make(map[string]bool)

	addOne := func(raw string) {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			return
		}
		raw = strings.TrimPrefix(raw, "[")
		raw = strings.TrimSuffix(raw, "]")
		var normalized string
		if strings.Contains(raw, "/") {
			normalized = raw
		} else {
			ip := net.ParseIP(raw)
			if ip != nil && ip.To4() == nil && strings.Contains(raw, ":") {
				normalized = raw + "/128"
			} else if ip != nil && ip.To4() != nil {
				normalized = raw + "/32"
			} else if strings.Contains(raw, ":") {
				normalized = raw + "/128"
			} else {
				normalized = raw + "/32"
			}
		}
		if !seen[normalized] {
			seen[normalized] = true
			addrs = append(addrs, normalized)
		}
	}

	for _, v := range vals {
		if v == nil {
			continue
		}
		switch val := v.(type) {
		case string:
			for _, part := range strings.Split(val, ",") {
				addOne(part)
			}
		case []string:
			for _, item := range val {
				for _, part := range strings.Split(item, ",") {
					addOne(part)
				}
			}
		case []any:
			for _, item := range val {
				if s := str(item); s != "" {
					for _, part := range strings.Split(s, ",") {
						addOne(part)
					}
				}
			}
		}
	}
	return addrs
}

func parseWireGuardReserved(v any) []int {
	if v == nil {
		return nil
	}
	switch val := v.(type) {
	case []int:
		return val
	case []any:
		res := make([]int, 0, len(val))
		for _, item := range val {
			res = append(res, intVal(item))
		}
		return res
	case string:
		s := strings.TrimSpace(val)
		s = strings.TrimPrefix(s, "[")
		s = strings.TrimSuffix(s, "]")
		if s == "" {
			return nil
		}
		parts := strings.Split(s, ",")
		res := make([]int, 0, len(parts))
		for _, p := range parts {
			p = strings.TrimSpace(p)
			if p != "" {
				res = append(res, intVal(p))
			}
		}
		return res
	default:
		return nil
	}
}

