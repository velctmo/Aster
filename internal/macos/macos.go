package macos

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"aster/internal/helper"
)

func ActiveService() (string, error) {
	// 1. Try to get default route interface (e.g. en0)
	dev := defaultRouteInterface()
	if dev != "" {
		if svc := serviceForDevice(dev); svc != "" {
			return svc, nil
		}
	}

	// 2. Fallback: Parse active network services from service order
	orderOut, err := exec.Command("networksetup", "-listnetworkserviceorder").Output()
	if err == nil {
		lines := strings.Split(string(orderOut), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "(") && strings.Contains(line, ") ") && !strings.Contains(line, "Hardware Port:") {
				if idx := strings.Index(line, ") "); idx != -1 {
					svc := strings.TrimSpace(line[idx+2:])
					if svc != "" && !strings.HasPrefix(svc, "*") {
						return svc, nil
					}
				}
			}
		}
	}

	// 3. Fallback: List all services
	out, err := exec.Command("networksetup", "-listallnetworkservices").Output()
	if err != nil {
		return "", err
	}
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "An asterisk") || strings.HasPrefix(line, "*") {
			continue
		}
		if line == "Wi-Fi" || line == "Ethernet" || strings.Contains(line, "以太网") || strings.Contains(line, "LAN") || strings.Contains(line, "USB") {
			return line, nil
		}
	}
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "An asterisk") && !strings.HasPrefix(line, "*") {
			return line, nil
		}
	}
	return "", fmt.Errorf("找不到网络服务")
}

func defaultRouteInterface() string {
	out, err := exec.Command("route", "-n", "get", "default").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "interface:") {
			return strings.TrimSpace(strings.TrimPrefix(line, "interface:"))
		}
	}
	return ""
}

func serviceForDevice(device string) string {
	out, err := exec.Command("networksetup", "-listnetworkserviceorder").Output()
	if err != nil {
		return ""
	}
	lines := strings.Split(string(out), "\n")
	curSvc := ""
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "(") && strings.Contains(line, ") ") && !strings.Contains(line, "Hardware Port:") {
			if idx := strings.Index(line, ") "); idx != -1 {
				curSvc = strings.TrimSpace(line[idx+2:])
			}
		} else if strings.Contains(line, "Device: "+device) && curSvc != "" {
			if !strings.HasPrefix(curSvc, "*") {
				return curSvc
			}
		}
	}
	return ""
}

func listEnabledServices() []string {
	out, err := exec.Command("networksetup", "-listallnetworkservices").Output()
	if err != nil {
		return nil
	}
	var res []string
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "An asterisk") || strings.HasPrefix(line, "*") {
			continue
		}
		res = append(res, line)
	}
	return res
}

func sanitizeBypass(bypass []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, d := range bypass {
		d = strings.TrimSpace(d)
		if d == "" {
			continue
		}
		// Convert CIDR to macOS networksetup wildcard if applicable
		if d == "10.0.0.0/8" {
			d = "10.*"
		} else if d == "172.16.0.0/12" {
			d = "172.16.*"
		} else if d == "192.168.0.0/16" {
			d = "192.168.*"
		}
		if !seen[d] {
			seen[d] = true
			out = append(out, d)
		}
	}
	return out
}

// SetProxy applies a macOS proxy endpoint. Host is supplied only after Aster
// has verified that it is a loopback mixed inbound; callers pass 127.0.0.1
// for Aster-owned node profiles.
func SetProxy(on bool, host string, port int, bypass []string) error {
	svc, err := ActiveService()
	if err != nil {
		return err
	}
	if host == "" {
		host = "127.0.0.1"
	}
	// Once installed, the root launchd helper owns system-level mutations.  This
	// removes the osascript authorization fallback from the regular daemon.
	if host == "127.0.0.1" && helper.NewClient().Installed() {
		if on {
			_, err := helper.NewClient().SetProxy(svc, port, sanitizeBypass(bypass))
			return err
		}
		_, err := helper.NewClient().ClearProxy(svc, port)
		return err
	}
	if on {
		cleanBypass := sanitizeBypass(bypass)
		cmds := [][]string{
			{"-setwebproxy", svc, host, fmt.Sprintf("%d", port)},
			{"-setsecurewebproxy", svc, host, fmt.Sprintf("%d", port)},
			{"-setsocksfirewallproxy", svc, host, fmt.Sprintf("%d", port)},
			{"-setwebproxystate", svc, "on"},
			{"-setsecurewebproxystate", svc, "on"},
			{"-setsocksfirewallproxystate", svc, "on"},
		}
		if len(cleanBypass) > 0 {
			args := append([]string{"-setproxybypassdomains", svc}, cleanBypass...)
			cmds = append(cmds, args)
		}
		for _, c := range cmds {
			if err := runNetworksetup(c); err != nil {
				return err
			}
		}
		return nil
	}

	// Remove only endpoints that still point at this Aster instance. Turning
	// every service's proxies off would destroy an unrelated VPN or corporate
	// proxy configuration whenever Aster stops.
	services := listEnabledServices()
	if len(services) == 0 {
		services = []string{svc}
	}
	for _, s := range services {
		for _, proxy := range []struct {
			get string
			set string
		}{
			{"-getwebproxy", "-setwebproxystate"},
			{"-getsecurewebproxy", "-setsecurewebproxystate"},
			{"-getsocksfirewallproxy", "-setsocksfirewallproxystate"},
		} {
			output, err := exec.Command("networksetup", proxy.get, s).Output()
			if err == nil && proxyOutputMatches(output, host, port) {
				_ = runNetworksetup([]string{proxy.set, s, "off"})
			}
		}
	}
	return nil
}

func proxyOutputMatches(output []byte, host string, port int) bool {
	values := map[string]string{}
	for _, line := range strings.Split(string(output), "\n") {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		values[strings.ToLower(strings.TrimSpace(key))] = strings.TrimSpace(value)
	}
	if !strings.EqualFold(values["enabled"], "yes") {
		return false
	}
	actualPort, err := strconv.Atoi(values["port"])
	if err != nil || actualPort != port {
		return false
	}
	normalizeHost := func(value string) string {
		return strings.Trim(strings.TrimSpace(value), "[]")
	}
	return strings.EqualFold(normalizeHost(values["server"]), normalizeHost(host))
}

func runNetworksetup(args []string) error {
	cmd := exec.Command("networksetup", args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("networksetup %v: %s", args, out)
	}
	return nil
}

func LANIP() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok || ipnet.IP.To4() == nil {
				continue
			}
			ip := ipnet.IP.To4()
			if ip[0] == 127 {
				continue
			}
			return ip.String()
		}
	}
	return ""
}

func OpenURL(u string) {
	_ = exec.Command("open", u).Start()
}

func ShowNotification(title, message string) {
	script := fmt.Sprintf(`display notification %s with title %s`, appleString(message), appleString(title))
	_ = exec.Command("osascript", "-e", script).Run()
}

func NotifyIfHidden(title, message string) {
	ShowNotification(title, message)
}

func GetActiveBrowserDomain() (string, error) {
	script := `
tell application "System Events"
    set frontApp to name of first application process whose frontmost is true
end tell

if frontApp is in {"Google Chrome", "Google Chrome Canary", "Chromium", "Brave Browser", "Microsoft Edge"} then
    tell application frontApp to return URL of active tab of front window
else if frontApp is "Safari" then
    tell application "Safari" to return URL of front document
else if frontApp is "Arc" then
    tell application "Arc" to return URL of active tab of front window
else
    return ""
end if
`
	cmd := exec.Command("osascript", "-e", script)
	out, err := cmd.Output()
	rawURL := strings.TrimSpace(string(out))

	// Fallback to clipboard if no browser active URL
	if rawURL == "" || err != nil {
		clipCmd := exec.Command("pbpaste")
		clipOut, _ := clipCmd.Output()
		rawURL = strings.TrimSpace(string(clipOut))
	}

	if rawURL == "" {
		return "", fmt.Errorf("未检测到有效网页或剪贴板内容")
	}

	return extractDomainFromURL(rawURL)
}

func extractDomainFromURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if strings.Contains(raw, "://") {
		parts := strings.Split(raw, "://")
		if len(parts) > 1 {
			raw = parts[1]
		}
	}
	if idx := strings.Index(raw, "/"); idx != -1 {
		raw = raw[:idx]
	}
	if idx := strings.Index(raw, ":"); idx != -1 {
		raw = raw[:idx]
	}
	raw = strings.TrimSpace(strings.ToLower(raw))
	if raw == "" || strings.Contains(raw, " ") || !strings.Contains(raw, ".") {
		return "", fmt.Errorf("非有效域名: %s", raw)
	}
	return raw, nil
}

func SetAutostart(on bool, exe string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(home, "Library", "LaunchAgents")
	plist := filepath.Join(dir, "app.aster.ctl.plist")
	if !on {
		_ = exec.Command("launchctl", "unload", plist).Run()
		_ = os.Remove(plist)
		return nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	body := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>app.aster.ctl</string>
  <key>ProgramArguments</key>
  <array><string>%s</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
`, xmlEscape(exe))
	if err := os.WriteFile(plist, []byte(body), 0o644); err != nil {
		return err
	}
	_ = exec.Command("launchctl", "unload", plist).Run()
	return exec.Command("launchctl", "load", plist).Run()
}

func xmlEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	return s
}

func shellQuote(s string) string {
	return `'` + strings.ReplaceAll(s, `'`, `'"'"'`) + `'`
}

func appleString(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return `"` + s + `"`
}

func shellJoin(args []string) string {
	var b []string
	for _, a := range args {
		b = append(b, shellQuote(a))
	}
	return strings.Join(b, " ")
}
