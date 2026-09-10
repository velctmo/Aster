package api

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"

	"aster/internal/app"
	"aster/internal/clash"
	"aster/internal/core"
	"aster/internal/logstore"
	"aster/internal/macos"
	"aster/internal/state"
)

type Server struct {
	App *app.App
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		rawOrigin := r.Header.Get("Origin")
		if rawOrigin == "" {
			return true
		}
		origin, err := url.Parse(rawOrigin)
		if err != nil {
			return false
		}
		if origin.Scheme == "file" {
			return origin.Host == ""
		}
		if origin.Scheme != "http" && origin.Scheme != "https" {
			return false
		}
		switch origin.Hostname() {
		case "127.0.0.1", "::1", "localhost":
			return true
		default:
			return false
		}
	},
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/status", s.getStatus)
	mux.HandleFunc("GET /api/v1/ip", s.getIPInfo)
	mux.HandleFunc("POST /api/v1/power", s.postPower)
	mux.HandleFunc("PATCH /api/v1/capture", s.patchCapture)
	mux.HandleFunc("PATCH /api/v1/mode", s.patchMode)
	mux.HandleFunc("GET /api/v1/configs", s.getConfigs)
	mux.HandleFunc("POST /api/v1/configs", s.postConfig)
	mux.HandleFunc("POST /api/v1/configs/refresh-all", s.refreshAllConfigs)
	mux.HandleFunc("POST /api/v1/configs/{id}/activate", s.activateConfig)
	mux.HandleFunc("POST /api/v1/configs/{id}/refresh", s.refreshConfig)
	mux.HandleFunc("PUT /api/v1/configs/{id}/script", s.putConfigScript)
	mux.HandleFunc("POST /api/v1/configs/{id}/bind-script", s.bindConfigScript)
	mux.HandleFunc("GET /api/v1/scripts", s.getScripts)
	mux.HandleFunc("POST /api/v1/scripts", s.postScript)
	mux.HandleFunc("PUT /api/v1/scripts/{id}", s.putScript)
	mux.HandleFunc("DELETE /api/v1/scripts/{id}", s.deleteScript)
	mux.HandleFunc("DELETE /api/v1/configs/{id}", s.deleteConfig)
	mux.HandleFunc("GET /api/v1/nodes", s.getNodes)
	mux.HandleFunc("GET /api/v1/strategy-groups", s.getStrategyGroups)
	mux.HandleFunc("POST /api/v1/strategy-groups/{tag}/delay", s.delayStrategyGroup)
	mux.HandleFunc("POST /api/v1/strategy-groups/{tag}/select", s.selectStrategyGroup)
	mux.HandleFunc("POST /api/v1/nodes", s.postNode)
	mux.HandleFunc("POST /api/v1/nodes/select", s.selectNode)
	mux.HandleFunc("POST /api/v1/nodes/{id}/disable", s.disableNode)
	mux.HandleFunc("POST /api/v1/nodes/delay", s.delay)
	mux.HandleFunc("POST /api/v1/nodes/speedtest", s.speedtest)
	mux.HandleFunc("GET /api/v1/rules", s.getRules)
	mux.HandleFunc("POST /api/v1/rules", s.postRule)
	mux.HandleFunc("POST /api/v1/rules/from-log", s.ruleFromLog)
	mux.HandleFunc("POST /api/v1/rules/reorder", s.reorderRules)
	mux.HandleFunc("DELETE /api/v1/rules/{id}", s.deleteRule)
	mux.HandleFunc("GET /api/v1/logs", s.getLogs)
	mux.HandleFunc("GET /api/v1/connections", s.getConnections)
	mux.HandleFunc("DELETE /api/v1/connections", s.closeAll)
	mux.HandleFunc("DELETE /api/v1/connections/{id}", s.closeOne)
	mux.HandleFunc("GET /api/v1/settings", s.getSettings)
	mux.HandleFunc("PUT /api/v1/settings", s.putSettings)
	mux.HandleFunc("PATCH /api/v1/settings", s.patchSettings)
	mux.HandleFunc("GET /api/v1/backup/export", s.export)
	mux.HandleFunc("POST /api/v1/backup/import", s.importZip)
	mux.HandleFunc("GET /api/v1/backup/icloud", s.getICloudStatus)
	mux.HandleFunc("POST /api/v1/backup/icloud/export", s.postICloudExport)
	mux.HandleFunc("POST /api/v1/backup/icloud/import", s.postICloudImport)
	mux.HandleFunc("GET /api/v1/lan", s.lan)
	mux.HandleFunc("GET /api/v1/proxy-env", s.proxyEnv)
	mux.HandleFunc("GET /api/v1/core", s.getCore)
	mux.HandleFunc("GET /api/v1/core/releases", s.getCoreReleases)
	mux.HandleFunc("POST /api/v1/core/download", s.postCoreDownload)
	mux.HandleFunc("POST /api/v1/core/import", s.postCoreImport)
	mux.HandleFunc("POST /api/v1/open-data-dir", s.openDir)
	mux.HandleFunc("POST /api/v1/clear-proxy", s.clearProxy)
	mux.HandleFunc("POST /api/v1/window/open", s.openWindow)
	mux.HandleFunc("POST /api/v1/restart", s.postRestart)
	mux.HandleFunc("GET /api/v1/network/diagnostics", s.getDiagnostics)
	mux.HandleFunc("GET /api/v1/diagnostics/report", s.getDiagnosticsReport)
	mux.HandleFunc("GET /api/v1/traffic/processes", s.getProcesses)
	mux.HandleFunc("GET /api/v1/ws/logs", s.wsKind("log"))
	mux.HandleFunc("GET /api/v1/ws/connections", s.wsKind("connections"))
	mux.HandleFunc("GET /api/v1/ws/traffic", s.wsKind("traffic"))
	mux.HandleFunc("GET /api/v1/ws/processes", s.wsKind("process_traffic"))
	mux.HandleFunc("GET /api/v1/ws/status", s.wsKind("status"))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/status" && r.Method == http.MethodGet {
			mux.ServeHTTP(w, r)
			return
		}
		if !s.authorized(r) {
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.WriteHeader(http.StatusUnauthorized)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"})
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func (s *Server) authorized(r *http.Request) bool {
	token := s.App.APIToken()
	if token == "" {
		return true
	}
	auth := r.Header.Get("Authorization")
	if strings.HasPrefix(auth, "Bearer ") && subtle.ConstantTimeCompare([]byte(strings.TrimPrefix(auth, "Bearer ")), []byte(token)) == 1 {
		return true
	}
	q := r.URL.Query().Get("token")
	return subtle.ConstantTimeCompare([]byte(q), []byte(token)) == 1
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, err error) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(400)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

// decodeJSON accepts exactly one JSON object. Side-effecting endpoints must
// reject trailing documents instead of silently applying the first one.
func decodeJSON(r *http.Request, dst any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		if err == nil {
			return fmt.Errorf("请求体只能包含一个 JSON 对象")
		}
		return err
	}
	return nil
}

func (s *Server) getStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.App.Status())
}

func (s *Server) getIPInfo(w http.ResponseWriter, r *http.Request) {
	force := r.URL.Query().Get("force") == "1" || r.URL.Query().Get("force") == "true"
	writeJSON(w, s.App.GetIPInfo(force))
}

func (s *Server) postPower(w http.ResponseWriter, r *http.Request) {
	var body struct {
		On *bool `json:"on"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if body.On == nil {
		writeErr(w, fmt.Errorf("缺少 on"))
		return
	}
	if err := s.App.SetPower(*body.On); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Status())
}

func (s *Server) patchCapture(w http.ResponseWriter, r *http.Request) {
	var body struct {
		SystemProxy *bool `json:"systemProxy"`
		Tun         *bool `json:"tun"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if body.SystemProxy == nil || body.Tun == nil {
		writeErr(w, fmt.Errorf("必须同时提供 systemProxy 和 tun"))
		return
	}
	c := state.Capture{SystemProxy: *body.SystemProxy, Tun: *body.Tun}
	if err := s.App.SetCapture(c); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Status())
}

func (s *Server) patchMode(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Mode string `json:"mode"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if err := s.App.SetMode(body.Mode); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Status())
}

func (s *Server) getConfigs(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.App.Profiles())
}

func (s *Server) postConfig(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name     string   `json:"name"`
		Kind     string   `json:"kind"`
		URL      string   `json:"url"`
		Content  string   `json:"content"`
		URLs     []string `json:"urls"`
		Activate bool     `json:"activate"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	var err error
	switch body.Kind {
	case state.ProfileKindSubscription:
		if len(body.URLs) != 0 {
			err = fmt.Errorf("订阅模式不接受节点订阅 URL 列表")
			break
		}
		err = s.App.CreateSubscriptionProfile(body.Name, body.URL, body.Content)
	case state.ProfileKindNodes:
		if strings.TrimSpace(body.URL) != "" || strings.TrimSpace(body.Content) != "" {
			err = fmt.Errorf("节点模式只接受多行订阅 URL")
			break
		}
		err = s.App.CreateNodeProfile(body.Name, body.URLs)
	default:
		err = fmt.Errorf("未知配置类型: %s", body.Kind)
	}
	if err != nil {
		writeErr(w, err)
		return
	}
	all := s.App.Profiles()
	if body.Activate && len(all) > 0 {
		newID := all[len(all)-1].ID
		_ = s.App.ActivateProfile(newID)
	}
	writeJSON(w, s.App.Profiles())
}

func (s *Server) activateConfig(w http.ResponseWriter, r *http.Request) {
	if err := s.App.ActivateProfile(r.PathValue("id")); err != nil {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]string{
			"error":          err.Error(),
			"activeConfigId": s.App.Store().Get().ActiveConfigID,
		})
		return
	}
	writeJSON(w, s.App.Status())
}

func (s *Server) refreshConfig(w http.ResponseWriter, r *http.Request) {
	updated, err := s.App.RefreshProfile(r.PathValue("id"))
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, map[string]any{"updated": updated, "configs": s.App.Profiles()})
}

func (s *Server) refreshAllConfigs(w http.ResponseWriter, r *http.Request) {
	updated, err := s.App.RefreshAllProfiles()
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, map[string]any{"updated": updated, "configs": s.App.Profiles()})
}

func (s *Server) deleteConfig(w http.ResponseWriter, r *http.Request) {
	if err := s.App.DeleteProfile(r.PathValue("id")); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Profiles())
}

func (s *Server) putConfigScript(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Script *string `json:"script"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if body.Script == nil {
		writeErr(w, fmt.Errorf("缺少 script"))
		return
	}
	if err := s.App.SetProfileScript(r.PathValue("id"), *body.Script); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Profiles())
}

func (s *Server) bindConfigScript(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ScriptID string `json:"scriptId"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if err := s.App.BindProfileScript(r.PathValue("id"), body.ScriptID); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Profiles())
}

func (s *Server) getScripts(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.App.Scripts())
}

func (s *Server) postScript(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name    string `json:"name"`
		Kind    string `json:"kind"`
		Content string `json:"content"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	item, err := s.App.CreateScript(body.Name, body.Kind, body.Content)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, item)
}

func (s *Server) putScript(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name    string `json:"name"`
		Content string `json:"content"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if err := s.App.UpdateScript(r.PathValue("id"), body.Name, body.Content); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Scripts())
}

func (s *Server) deleteScript(w http.ResponseWriter, r *http.Request) {
	if err := s.App.DeleteScript(r.PathValue("id")); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Scripts())
}

func (s *Server) getNodes(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.App.Nodes())
}

func (s *Server) getStrategyGroups(w http.ResponseWriter, r *http.Request) {
	groups, err := s.App.StrategyGroups()
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, groups)
}

func (s *Server) delayStrategyGroup(w http.ResponseWriter, r *http.Request) {
	results, err := s.App.DelayGroup(r.PathValue("tag"))
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, results)
}

func (s *Server) selectStrategyGroup(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Tag string `json:"tag"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if body.Tag == "" {
		writeErr(w, fmt.Errorf("缺少 tag"))
		return
	}
	if err := s.App.SelectGroupNode(r.PathValue("tag"), body.Tag); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Status())
}

func (s *Server) postNode(w http.ResponseWriter, r *http.Request) {
	var body struct {
		URI string `json:"uri"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if err := s.App.AddNode(body.URI); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Nodes())
}

func (s *Server) selectNode(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Tag string `json:"tag"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if err := s.App.SelectNode(body.Tag); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Status())
}

func (s *Server) disableNode(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Disabled *bool `json:"disabled"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if body.Disabled == nil {
		writeErr(w, fmt.Errorf("缺少 disabled"))
		return
	}
	if err := s.App.DisableNode(r.PathValue("id"), *body.Disabled); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Nodes())
}

func (s *Server) delay(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Tag  string   `json:"tag"`
		Tags []string `json:"tags"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if len(body.Tags) > 0 || body.Tag == "" {
		writeJSON(w, s.App.DelayMany(body.Tags))
		return
	}
	d, err := s.App.Delay(body.Tag)
	if err != nil {
		writeJSON(w, map[string]any{"tag": body.Tag, "delay": 0, "error": err.Error()})
		return
	}
	writeJSON(w, map[string]any{"tag": body.Tag, "delay": d})
}

func (s *Server) speedtest(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Tag string `json:"tag"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if body.Tag == "" {
		body.Tag = s.App.Store().Get().Selected
	}
	mbps, err := s.App.SpeedtestNode(body.Tag)
	if err != nil {
		writeJSON(w, map[string]any{"tag": body.Tag, "bandwidthMbps": 0.0, "error": err.Error()})
		return
	}
	writeJSON(w, map[string]any{"tag": body.Tag, "bandwidthMbps": mbps})
}

func (s *Server) getRules(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.App.LiveRules())
}

func (s *Server) postRule(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Match  string `json:"match"`
		Value  string `json:"value"`
		Action string `json:"action"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if err := s.App.AddRule(body.Match, body.Value, body.Action); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Store().Get().Rules)
}

func (s *Server) ruleFromLog(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Host   string `json:"host"`
		Match  string `json:"match"`
		Action string `json:"action"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if err := s.App.RuleFromLog(body.Host, body.Match, body.Action); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Store().Get().Rules)
}

func (s *Server) reorderRules(w http.ResponseWriter, r *http.Request) {
	var body struct {
		IDs []string `json:"ids"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if err := s.App.ReorderRules(body.IDs); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Store().Get().Rules)
}

func (s *Server) deleteRule(w http.ResponseWriter, r *http.Request) {
	if err := s.App.DeleteRule(r.PathValue("id")); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Store().Get().Rules)
}

func (s *Server) getLogs(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	since, _ := strconv.ParseInt(q.Get("since"), 10, 64)
	rows, err := s.App.Logs(q.Get("kind"), limit, since)
	if err != nil {
		writeErr(w, err)
		return
	}
	if rows == nil {
		rows = []logstore.Row{}
	}
	writeJSON(w, rows)
}

func (s *Server) getConnections(w http.ResponseWriter, r *http.Request) {
	snap, err := s.App.ClashConnections()
	if err != nil || snap == nil {
		writeJSON(w, map[string]any{"snapshotVersion": s.App.Hub().Sequence(), "downloadTotal": 0, "uploadTotal": 0, "connections": []any{}})
		return
	}
	writeJSON(w, map[string]any{"snapshotVersion": s.App.Hub().Sequence(), "downloadTotal": snap.DownloadTotal, "uploadTotal": snap.UploadTotal, "connections": snap.Connections})
}

func (s *Server) closeAll(w http.ResponseWriter, r *http.Request) {
	_ = s.App.ClashCloseAll()
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) closeOne(w http.ResponseWriter, r *http.Request) {
	_ = s.App.ClashCloseOne(r.PathValue("id"))
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) getSettings(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.App.Store().Get().Settings)
}

func (s *Server) putSettings(w http.ResponseWriter, r *http.Request) {
	var set state.Settings
	if err := decodeJSON(r, &set); err != nil {
		writeErr(w, err)
		return
	}
	if err := s.App.PutSettings(set); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Store().Get().Settings)
}

func (s *Server) patchSettings(w http.ResponseWriter, r *http.Request) {
	var body struct {
		DelayURL         *string `json:"delayURL"`
		MixedPort        *int    `json:"mixedPort"`
		ClashPort        *int    `json:"clashPort"`
		AllowLan         *bool   `json:"allowLan"`
		DirectCN         *bool   `json:"directCN"`
		Autostart        *bool   `json:"autostart"`
		AutoConnect      *bool   `json:"autoConnect"`
		PassiveSampling  *bool   `json:"passiveSampling"`
		DNSMode          *string `json:"dnsMode"`
		StrictRoute      *bool   `json:"strictRoute"`
		DelayTimeoutMs   *int    `json:"delayTimeoutMs"`
		DelayConcurrency *int    `json:"delayConcurrency"`
		ControlPort      *int    `json:"controlPort"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	cur := s.App.Store().Get().Settings
	changed := false
	if body.DelayURL != nil {
		if strings.TrimSpace(*body.DelayURL) == "" {
			writeErr(w, fmt.Errorf("测速 URL 不能为空"))
			return
		}
		cur.DelayURL, changed = *body.DelayURL, true
	}
	for _, patch := range []struct {
		value *int
		name  string
		set   func(int)
	}{
		{body.MixedPort, "mixedPort", func(v int) { cur.MixedPort = v }},
		{body.ClashPort, "clashPort", func(v int) { cur.ClashPort = v }},
		{body.ControlPort, "controlPort", func(v int) { cur.ControlPort = v }},
		{body.DelayTimeoutMs, "delayTimeoutMs", func(v int) { cur.DelayTimeoutMs = v }},
		{body.DelayConcurrency, "delayConcurrency", func(v int) { cur.DelayConcurrency = v }},
	} {
		if patch.value == nil {
			continue
		}
		if *patch.value <= 0 {
			writeErr(w, fmt.Errorf("%s 必须大于 0", patch.name))
			return
		}
		if (patch.name == "mixedPort" || patch.name == "clashPort" || patch.name == "controlPort") && *patch.value > 65535 {
			writeErr(w, fmt.Errorf("%s 必须小于等于 65535", patch.name))
			return
		}
		patch.set(*patch.value)
		changed = true
	}
	if body.AllowLan != nil {
		cur.AllowLan, changed = *body.AllowLan, true
	}
	if body.DirectCN != nil {
		cur.DirectCN, changed = *body.DirectCN, true
	}
	if body.Autostart != nil {
		cur.Autostart, changed = *body.Autostart, true
	}
	if body.AutoConnect != nil {
		cur.AutoConnect, changed = *body.AutoConnect, true
	}
	if body.PassiveSampling != nil {
		cur.PassiveSampling, changed = *body.PassiveSampling, true
	}
	if body.DNSMode != nil {
		if *body.DNSMode != "fake-ip" && *body.DNSMode != "redir-host" {
			writeErr(w, fmt.Errorf("不支持的 DNS 模式: %s", *body.DNSMode))
			return
		}
		cur.DNSMode, changed = *body.DNSMode, true
	}
	if body.StrictRoute != nil {
		cur.StrictRoute, changed = *body.StrictRoute, true
	}
	if !changed {
		writeErr(w, fmt.Errorf("至少提供一个设置字段"))
		return
	}
	if err := s.App.PutSettings(cur); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.Store().Get().Settings)
}

func (s *Server) export(w http.ResponseWriter, r *http.Request) {
	b, err := s.App.ExportZip()
	if err != nil {
		writeErr(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="aster-backup.zip"`)
	_, _ = w.Write(b)
}

func (s *Server) importZip(w http.ResponseWriter, r *http.Request) {
	if err := s.App.ImportZip(r.Body); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) getICloudStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.App.ICloudStatus())
}

func (s *Server) postICloudExport(w http.ResponseWriter, r *http.Request) {
	if err := s.App.ExportToICloud(); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.ICloudStatus())
}

func (s *Server) postICloudImport(w http.ResponseWriter, r *http.Request) {
	if err := s.App.ImportFromICloud(); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, s.App.ICloudStatus())
}

func (s *Server) lan(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.App.LAN())
}

func (s *Server) proxyEnv(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{"env": s.App.ProxyEnv()})
}

func (s *Server) openDir(w http.ResponseWriter, r *http.Request) {
	macos.OpenURL(s.App.Store().Dir())
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) clearProxy(w http.ResponseWriter, r *http.Request) {
	if err := s.App.ClearProxyResidue(); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) wsKind(kind string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		ch := s.App.Hub().Add(c, kind)
		defer func() {
			s.App.Hub().Remove(c)
			_ = c.Close()
		}()

		// Every stream gets an initial event in its own contract. In particular,
		// a connection stream must be able to discard stale rows after a socket
		// reconnect rather than relying on a racing REST fetch.
		switch kind {
		case "status":
			_ = c.WriteJSON(s.App.Hub().Event("status", s.App.Status()))
		case "connections":
			snap, err := s.App.ClashConnections()
			delta := app.ConnectionsDelta{Snapshot: true, Upserts: []clash.Connection{}, Closed: []string{}}
			if err == nil && snap != nil {
				delta.DownloadTotal = snap.DownloadTotal
				delta.UploadTotal = snap.UploadTotal
				delta.Upserts = snap.Connections
			}
			_ = c.WriteJSON(s.App.Hub().Event("connections", delta))
		case "process_traffic":
			_ = c.WriteJSON(s.App.Hub().Event("process_traffic", s.App.GetTopProcesses()))
		}

		stopCh := make(chan struct{})
		// ReadPump: 持续读取客户端控制帧 (Ping/Pong/Close) 并感知断开
		go func() {
			defer close(stopCh)
			c.SetReadLimit(4096)
			_ = c.SetReadDeadline(time.Now().Add(60 * time.Second))
			c.SetPongHandler(func(string) error {
				_ = c.SetReadDeadline(time.Now().Add(60 * time.Second))
				return nil
			})
			for {
				if _, _, err := c.ReadMessage(); err != nil {
					return
				}
			}
		}()

		pingTicker := time.NewTicker(25 * time.Second)
		defer pingTicker.Stop()

		for {
			select {
			case <-stopCh:
				return
			case <-pingTicker.C:
				_ = c.SetWriteDeadline(time.Now().Add(5 * time.Second))
				if err := c.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}
			case msg, ok := <-ch:
				if !ok {
					return
				}
				_ = c.SetWriteDeadline(time.Now().Add(5 * time.Second))
				if err := c.WriteMessage(websocket.TextMessage, msg); err != nil {
					return
				}
			}
		}
	}
}

func (s *Server) getCore(w http.ResponseWriter, r *http.Request) {
	st := s.App.Store().Get()
	writeJSON(w, core.Info(st.Settings.CorePath))
}

func (s *Server) getCoreReleases(w http.ResponseWriter, r *http.Request) {
	list, err := core.ListReleases()
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, list)
}

func (s *Server) postCoreDownload(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Tag    *string `json:"tag"`
		SHA256 *string `json:"sha256"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if body.Tag == nil || strings.TrimSpace(*body.Tag) == "" {
		writeErr(w, fmt.Errorf("缺少内核版本 tag"))
		return
	}
	if body.SHA256 == nil || strings.TrimSpace(*body.SHA256) == "" {
		writeErr(w, fmt.Errorf("缺少内核 SHA-256 校验值"))
		return
	}
	path, err := core.Download(strings.TrimSpace(*body.Tag), strings.TrimSpace(*body.SHA256), s.App.Store().CoresDir())
	if err != nil {
		writeErr(w, err)
		return
	}
	settings := s.App.Store().Get().Settings
	settings.CorePath = path
	if err := s.App.PutSettings(settings); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, core.Info(path))
}

func (s *Server) postCoreImport(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(64 << 20); err != nil {
		writeErr(w, err)
		return
	}
	file, _, err := r.FormFile("file")
	if err != nil {
		writeErr(w, fmt.Errorf("请选择内核文件"))
		return
	}
	defer file.Close()
	path, err := core.Import(file, s.App.Store().CoresDir())
	if err != nil {
		writeErr(w, err)
		return
	}
	settings := s.App.Store().Get().Settings
	settings.CorePath = path
	if err := s.App.PutSettings(settings); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, core.Info(path))
}

func (s *Server) openWindow(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{"status": "ok"})
}

func (s *Server) postRestart(w http.ResponseWriter, r *http.Request) {
	if err := s.App.Restart(); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) getDiagnostics(w http.ResponseWriter, r *http.Request) {
	force := r.URL.Query().Get("force") == "true"
	writeJSON(w, s.App.GetNetworkDiagnostics(force))
}

func (s *Server) getDiagnosticsReport(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Disposition", `attachment; filename="aster-diagnostics.json"`)
	writeJSON(w, s.App.DiagnosticsReport())
}

func (s *Server) getProcesses(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.App.GetTopProcesses())
}

func Serve(ln net.Listener, h http.Handler) error {
	return http.Serve(ln, h)
}
