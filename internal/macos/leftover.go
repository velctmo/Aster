package macos

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

type ProxyOwnership struct {
	Host string `json:"host"`
	Port int    `json:"port"`
	PID  int    `json:"pid"`
}

type proxyKind struct {
	get string
	set string
}

var managedProxyKinds = []proxyKind{
	{"-getwebproxy", "-setwebproxystate"},
	{"-getsecurewebproxy", "-setsecurewebproxystate"},
	{"-getsocksfirewallproxy", "-setsocksfirewallproxystate"},
}

type serviceProxyInspection struct {
	Owned   bool
	Foreign bool
}

// DetectOwned reports whether at least one enabled network service is
// exclusively pointing at this Aster mixed endpoint. A service that also has
// a third-party proxy is not claimed.
func DetectOwned(host string, port int) bool {
	for _, svc := range leftoverServices() {
		ins := inspectService(svc, host, port)
		if ins.Owned && !ins.Foreign {
			return true
		}
	}
	return false
}

// ClearLeftover turns off Aster-owned proxies on services that have no foreign
// proxy mixed in. Corporate or VPN endpoints are left alone.
func ClearLeftover(host string, port int) error {
	if host == "" || port <= 0 {
		return nil
	}
	var first error
	for _, svc := range leftoverServices() {
		ins := inspectService(svc, host, port)
		if !ins.Owned || ins.Foreign {
			continue
		}
		for _, proxy := range managedProxyKinds {
			output, err := exec.Command("networksetup", proxy.get, svc).Output()
			if err != nil {
				continue
			}
			if proxyOutputMatches(output, host, port) {
				if err := runNetworksetup([]string{proxy.set, svc, "off"}); err != nil && first == nil {
					first = err
				}
			}
		}
	}
	return first
}

func leftoverServices() []string {
	services := listEnabledServices()
	if len(services) > 0 {
		return services
	}
	if svc, err := ActiveService(); err == nil && svc != "" {
		return []string{svc}
	}
	return nil
}

func inspectService(svc, host string, port int) serviceProxyInspection {
	var ins serviceProxyInspection
	for _, proxy := range managedProxyKinds {
		output, err := exec.Command("networksetup", proxy.get, svc).Output()
		if err != nil {
			continue
		}
		enabled, server, actualPort, ok := parseNetworksetupProxy(output)
		if !ok || !enabled {
			continue
		}
		if proxyEndpointMatches(server, actualPort, host, port) {
			ins.Owned = true
			continue
		}
		ins.Foreign = true
	}
	return ins
}

func parseNetworksetupProxy(output []byte) (enabled bool, server string, port int, ok bool) {
	values := map[string]string{}
	for _, line := range strings.Split(string(output), "\n") {
		key, value, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		values[strings.ToLower(strings.TrimSpace(key))] = strings.TrimSpace(value)
	}
	if _, exists := values["enabled"]; !exists {
		return false, "", 0, false
	}
	enabled = strings.EqualFold(values["enabled"], "yes")
	server = values["server"]
	if raw, exists := values["port"]; exists && raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			return enabled, server, 0, false
		}
		port = parsed
	}
	return enabled, server, port, true
}

func inspectServiceFromOutputs(host string, port int, outputs [][]byte) serviceProxyInspection {
	var ins serviceProxyInspection
	for _, output := range outputs {
		enabled, server, actualPort, ok := parseNetworksetupProxy(output)
		if !ok || !enabled {
			continue
		}
		if proxyEndpointMatches(server, actualPort, host, port) {
			ins.Owned = true
			continue
		}
		ins.Foreign = true
	}
	return ins
}

func proxyEndpointMatches(server string, actualPort int, host string, port int) bool {
	if actualPort != port {
		return false
	}
	normalize := func(value string) string {
		return strings.Trim(strings.TrimSpace(value), "[]")
	}
	return strings.EqualFold(normalize(server), normalize(host))
}

// SystemProxyPointsTo reports whether macOS currently has HTTP, HTTPS or SOCKS
// pointing at this Aster mixed endpoint.
func SystemProxyPointsTo(host string, port int) bool {
	if host == "" || port <= 0 {
		return false
	}
	if out, err := exec.Command("scutil", "--proxy").Output(); err == nil {
		return scutilPointsTo(out, host, port)
	}
	svc, err := ActiveService()
	if err != nil {
		return false
	}
	for _, proxy := range managedProxyKinds {
		output, err := exec.Command("networksetup", proxy.get, svc).Output()
		if err != nil {
			continue
		}
		if proxyOutputMatches(output, host, port) {
			return true
		}
	}
	return false
}

func scutilPointsTo(output []byte, host string, port int) bool {
	values := parseScutilProxy(output)
	pairs := [][2]string{
		{"HTTPEnable", "HTTPProxy"},
		{"HTTPSEnable", "HTTPSProxy"},
		{"SOCKSEnable", "SOCKSProxy"},
	}
	ports := map[string]string{
		"HTTPEnable":  "HTTPPort",
		"HTTPSEnable": "HTTPSPort",
		"SOCKSEnable": "SOCKSPort",
	}
	for _, pair := range pairs {
		if values[pair[0]] != "1" {
			continue
		}
		actualPort, err := strconv.Atoi(values[ports[pair[0]]])
		if err != nil {
			continue
		}
		if proxyEndpointMatches(values[pair[1]], actualPort, host, port) {
			return true
		}
	}
	return false
}

func parseScutilProxy(output []byte) map[string]string {
	values := map[string]string{}
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		values[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}
	return values
}

func ReadOwnership(dir string) (ProxyOwnership, bool) {
	raw, err := os.ReadFile(ownershipPath(dir))
	if err != nil {
		return ProxyOwnership{}, false
	}
	var owner ProxyOwnership
	if json.Unmarshal(raw, &owner) != nil || owner.Port <= 0 {
		return ProxyOwnership{}, false
	}
	if owner.Host == "" {
		owner.Host = "127.0.0.1"
	}
	return owner, true
}

func WriteOwnership(dir, host string, port, pid int) error {
	if host == "" {
		host = "127.0.0.1"
	}
	body, err := json.MarshalIndent(ProxyOwnership{Host: host, Port: port, PID: pid}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(ownershipPath(dir), body, 0o600)
}

func ClearOwnership(dir string) {
	_ = os.Remove(ownershipPath(dir))
}

func ownershipPath(dir string) string {
	return filepath.Join(dir, "system-proxy-owner.json")
}
