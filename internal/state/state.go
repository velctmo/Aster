package state

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	LocalSubID     = "local"
	AppSupportName = "Aster"
)

type Capture struct {
	SystemProxy bool `json:"systemProxy"`
	Tun         bool `json:"tun"`
}

type Settings struct {
	CorePath         string   `json:"corePath"`
	MixedPort        int      `json:"mixedPort"`
	ClashPort        int      `json:"clashPort"`
	ControlPort      int      `json:"controlPort"`
	AllowLan         bool     `json:"allowLan"`
	DirectCN         bool     `json:"directCN"`
	DNSMode          string   `json:"dnsMode"`
	ProxyBypass      []string `json:"proxyBypass"`
	DelayURL         string   `json:"delayURL"`
	DelayTimeoutMs   int      `json:"delayTimeoutMs"`
	DelayConcurrency int      `json:"delayConcurrency"`
	StrictRoute      bool     `json:"strictRoute"`
	PassiveSampling  bool     `json:"passiveSampling"`
	SubIntervalHours int      `json:"subIntervalHours"`
	LogRetention     string   `json:"logRetention"`
	Autostart        bool     `json:"autostart"`
	AutoConnect      bool     `json:"autoConnect"`
	LogLevel         string   `json:"logLevel"`
	NodeView         string   `json:"nodeView"`
	Theme            string   `json:"theme"`
}

type Node struct {
	ID       string          `json:"id"`
	Name     string          `json:"name"`
	Protocol string          `json:"protocol"`
	Disabled bool            `json:"disabled"`
	Outbound json.RawMessage `json:"outbound"`
}

const (
	ProfileKindSubscription = "subscription"
	ProfileKindNodes        = "nodes"
)

// ConfigSource is one remote node subscription in a node-mode profile.
// Nodes are retained after a failed refresh so a temporary provider failure
// never makes an otherwise working profile empty.
type ConfigSource struct {
	ID        string `json:"id"`
	URL       string `json:"url"`
	Nodes     []Node `json:"nodes"`
	UpdatedAt int64  `json:"updatedAt"`
	LastError string `json:"lastError"`
	Upload    int64  `json:"upload"`
	Download  int64  `json:"download"`
	Total     int64  `json:"total"`
	Expire    int64  `json:"expire"`
	Skipped   int    `json:"skipped"`
}

// ConfigProfile is the only unit that can be active at runtime. Subscription
// profiles keep a complete sing-box JSON document; node profiles keep several
// source URLs and let Aster build the sing-box configuration from their nodes.
type ConfigProfile struct {
	ID                  string          `json:"id"`
	Name                string          `json:"name"`
	Kind                string          `json:"kind"`
	Source              string          `json:"source,omitempty"`
	Config              json.RawMessage `json:"config,omitempty"`
	Sources             []ConfigSource  `json:"sources,omitempty"`
	ManualNodes         []Node          `json:"manualNodes,omitempty"`
	UpdatedAt           int64           `json:"updatedAt"`
	Revision            uint64          `json:"revision,omitempty"`
	LastError           string          `json:"lastError"`
	Script              string          `json:"script,omitempty"`
	ScriptID            string          `json:"scriptId,omitempty"`
	RefreshHistory      []RefreshEvent  `json:"refreshHistory,omitempty"`
	ImportedMixedListen string          `json:"importedMixedListen,omitempty"`
	ImportedMixedPort   int             `json:"importedMixedPort,omitempty"`
	ImportedTun         bool            `json:"importedTun,omitempty"`
}

type ScriptItem struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Kind      string `json:"kind"` // "config" | "nodes"
	Content   string `json:"content"`
	UpdatedAt int64  `json:"updatedAt"`
}

// RefreshEvent records one source-level refresh result. It deliberately holds
// an opaque source ID rather than a URL; callers redact Reason before sending
// it outside the local state file.
type RefreshEvent struct {
	At        int64  `json:"at"`
	SourceID  string `json:"sourceId"`
	Outcome   string `json:"outcome"`
	NodeCount int    `json:"nodeCount,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

type Rule struct {
	ID     string `json:"id"`
	Match  string `json:"match"`
	Value  string `json:"value"`
	Action string `json:"action"`
	Source string `json:"source,omitempty"`
}

type File struct {
	Settings       Settings        `json:"settings"`
	Wanted         bool            `json:"wanted"`
	Capture        Capture         `json:"capture"`
	Mode           string          `json:"mode"`
	Selected       string          `json:"selected"`
	ClashSecret    string          `json:"clashSecret"`
	APIToken       string          `json:"apiToken"`
	Rules          []Rule          `json:"rules"`
	RecentNodes    []string        `json:"recentNodes"`
	Profiles       []ConfigProfile `json:"profiles,omitempty"`
	Scripts        []ScriptItem    `json:"scripts,omitempty"`
	ActiveConfigID string          `json:"activeConfigId,omitempty"`
	Runtime        RuntimeState    `json:"runtime,omitempty"`
}

// RuntimeState is operational metadata, deliberately separate from user
// configuration.  It lets startup and diagnostics explain which profile was
// last known to run successfully without mutating the profile itself.
type RuntimeState struct {
	LastSuccessfulConfigID string     `json:"lastSuccessfulConfigId,omitempty"`
	LastSuccessfulAt       int64      `json:"lastSuccessfulAt,omitempty"`
	LastFailure            string     `json:"lastFailure,omitempty"`
	History                []RunEvent `json:"history,omitempty"`
}

type RunEvent struct {
	At         int64  `json:"at"`
	ConfigID   string `json:"configId,omitempty"`
	Outcome    string `json:"outcome"`
	Category   string `json:"category,omitempty"`
	DurationMs int64  `json:"durationMs,omitempty"`
	Reason     string `json:"reason,omitempty"`
}

type Store struct {
	mu           sync.RWMutex
	dir          string
	settingsPath string
	rulesPath    string
	machinePath  string
	profilesDir  string
	scriptsDir   string
	cur          File
}

func Dir() (string, error) {
	if override := os.Getenv("ASTER_DATA_DIR"); override != "" {
		return override, os.MkdirAll(override, 0o700)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, "Library", "Application Support", AppSupportName)
	return dir, os.MkdirAll(dir, 0o700)
}

func Open() (*Store, error) {
	dir, err := Dir()
	if err != nil {
		return nil, err
	}
	s := &Store{
		dir:          dir,
		settingsPath: filepath.Join(dir, "settings.json"),
		rulesPath:    filepath.Join(dir, "rules.json"),
		machinePath:  filepath.Join(dir, "machine.json"),
		profilesDir:  filepath.Join(dir, "profiles"),
		scriptsDir:   filepath.Join(dir, "scripts"),
	}
	if err := s.load(); err != nil {
		return nil, err
	}
	syncBundledRules(dir)
	return s, nil
}

// syncBundledRules 检查并自愈本地规则集文件：
// 在新设备安装包首次部署时，自动从 App Bundle Resources/rules 复制预置的
// geosite-cn.srs 与 geoip-cn.srs 到用户数据目录，避免全新安装下分流规则失效
func syncBundledRules(dir string) {
	targetRulesDir := filepath.Join(dir, "rules")
	_ = os.MkdirAll(targetRulesDir, 0o755)

	// 尝试寻找应用包内置的 rules 目录
	var candidateDirs []string
	if exe, err := os.Executable(); err == nil {
		candidateDirs = append(candidateDirs,
			filepath.Join(filepath.Dir(exe), "..", "Resources", "rules"),
			filepath.Join(filepath.Dir(exe), "rules"),
		)
	}
	candidateDirs = append(candidateDirs,
		"/Applications/Aster.app/Contents/Resources/rules",
		"vendor/rules",
	)

	for _, cand := range candidateDirs {
		entries, err := os.ReadDir(cand)
		if err != nil || len(entries) == 0 {
			continue
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".srs") {
				continue
			}
			destPath := filepath.Join(targetRulesDir, e.Name())
			if st, err := os.Stat(destPath); err == nil && st.Size() > 0 {
				continue // 目标已有规则集且非空，跳过
			}
			srcData, err := os.ReadFile(filepath.Join(cand, e.Name()))
			if err == nil && len(srcData) > 0 {
				_ = os.WriteFile(destPath, srcData, 0o644)
			}
		}
		break
	}
}

func (s *Store) Dir() string { return s.dir }

func (s *Store) ConfigPath() string { return filepath.Join(s.dir, "config.json") }

func (s *Store) PIDPath() string { return filepath.Join(s.dir, "core.pid") }

func (s *Store) DaemonPIDPath() string { return filepath.Join(s.dir, "daemon.pid") }

func (s *Store) CachePath() string { return filepath.Join(s.dir, "cache.db") }

func (s *Store) LogsPath() string { return filepath.Join(s.dir, "logs.db") }

func (s *Store) DaemonLogPath() string { return filepath.Join(s.dir, "daemon.log") }

func (s *Store) CoresDir() string {
	d := filepath.Join(s.dir, "cores")
	_ = os.MkdirAll(d, 0o700)
	return d
}

func DefaultFile() File {
	secret := make([]byte, 16)
	_, _ = rand.Read(secret)
	token := make([]byte, 24)
	_, _ = rand.Read(token)
	f := File{
		Settings: Settings{
			MixedPort:        2080,
			ClashPort:        2090,
			ControlPort:      1780,
			DirectCN:         true,
			DNSMode:          "fake-ip",
			ProxyBypass:      []string{"127.0.0.1", "localhost", "*.local", "*.lan", "10.*", "172.16.*", "172.17.*", "172.18.*", "172.19.*", "172.20.*", "172.21.*", "172.22.*", "172.23.*", "172.24.*", "172.25.*", "172.26.*", "172.27.*", "172.28.*", "172.29.*", "172.30.*", "172.31.*", "192.168.*"},
			DelayURL:         "https://www.gstatic.com/generate_204",
			DelayTimeoutMs:   2500,
			DelayConcurrency: 16,
			StrictRoute:      true,
			PassiveSampling:  true,
			SubIntervalHours: 6,
			LogRetention:     "15m",
			LogLevel:         "warn",
			NodeView:         "grid",
			Theme:            "system",
		},
		Capture:     Capture{SystemProxy: true},
		Wanted:      true,
		Mode:        "rule",
		Selected:    "auto",
		ClashSecret: hex.EncodeToString(secret),
		APIToken:    hex.EncodeToString(token),
	}
	f.Profiles = []ConfigProfile{{ID: NewID(), Name: "节点池", Kind: ProfileKindNodes, UpdatedAt: time.Now().Unix(), Revision: 1}}
	f.ActiveConfigID = f.Profiles[0].ID
	f.Runtime.LastSuccessfulConfigID = f.ActiveConfigID
	return f
}

func (s *Store) load() error {
	return s.loadPersisted()
}

func mergeDefaults(f File) File {
	d := DefaultFile()
	upgrading := f.APIToken == ""
	if f.Settings.MixedPort == 0 || f.Settings.MixedPort == 7890 {
		f.Settings.MixedPort = d.Settings.MixedPort
	}
	if f.Settings.ClashPort == 0 || f.Settings.ClashPort == 9090 {
		f.Settings.ClashPort = d.Settings.ClashPort
	}
	if f.Settings.ControlPort == 0 {
		f.Settings.ControlPort = d.Settings.ControlPort
	}
	if f.Settings.DelayURL == "" {
		f.Settings.DelayURL = d.Settings.DelayURL
	}
	if f.Settings.DelayTimeoutMs <= 0 {
		f.Settings.DelayTimeoutMs = d.Settings.DelayTimeoutMs
	}
	if f.Settings.DelayConcurrency <= 0 {
		f.Settings.DelayConcurrency = d.Settings.DelayConcurrency
	}
	if upgrading {
		f.Settings.StrictRoute = true
	}
	if f.Settings.SubIntervalHours == 0 {
		f.Settings.SubIntervalHours = d.Settings.SubIntervalHours
	}
	if f.Settings.LogRetention == "" {
		f.Settings.LogRetention = d.Settings.LogRetention
	}
	if f.Settings.DNSMode == "" {
		f.Settings.DNSMode = d.Settings.DNSMode
	}
	if f.Settings.LogLevel == "" {
		f.Settings.LogLevel = d.Settings.LogLevel
	}
	if f.Settings.NodeView == "" {
		f.Settings.NodeView = "grid"
	}
	if f.Settings.Theme == "" {
		f.Settings.Theme = "system"
	}
	if len(f.Settings.ProxyBypass) == 0 {
		f.Settings.ProxyBypass = d.Settings.ProxyBypass
	}
	if f.Mode == "" {
		f.Mode = "rule"
	}
	if f.Selected == "" {
		f.Selected = "auto"
	}
	if f.ClashSecret == "" {
		f.ClashSecret = d.ClashSecret
	}
	if f.APIToken == "" {
		f.APIToken = d.APIToken
	}
	if len(f.Profiles) == 0 {
		f.Profiles = d.Profiles
		f.ActiveConfigID = f.Profiles[0].ID
	}
	for i := range f.Profiles {
		if f.Profiles[i].Revision == 0 {
			f.Profiles[i].Revision = 1
		}
		if f.Profiles[i].Script != "" && f.Profiles[i].ScriptID == "" {
			scriptID := NewID()
			f.Scripts = append(f.Scripts, ScriptItem{
				ID:        scriptID,
				Name:      f.Profiles[i].Name + " 覆写",
				Kind:      f.Profiles[i].Kind,
				Content:   f.Profiles[i].Script,
				UpdatedAt: time.Now().Unix(),
			})
			f.Profiles[i].ScriptID = scriptID
		}
		hydrateImportedCapabilities(&f.Profiles[i])
	}
	if f.ActiveConfigID == "" || !profileExists(f.Profiles, f.ActiveConfigID) {
		if profileExists(f.Profiles, f.Runtime.LastSuccessfulConfigID) {
			f.ActiveConfigID = f.Runtime.LastSuccessfulConfigID
		} else {
			f.ActiveConfigID = f.Profiles[0].ID
		}
	}
	return f
}

// HydrateImportedCapabilities records the narrow inbound facts that Aster may
// observe for a strict read-only complete profile. Keeping these alongside the
// profile lets high-frequency status reads avoid copying its raw JSON.
func HydrateImportedCapabilities(profile *ConfigProfile) {
	hydrateImportedCapabilities(profile)
}

func hydrateImportedCapabilities(profile *ConfigProfile) {
	if profile == nil || profile.Kind != ProfileKindSubscription {
		return
	}
	profile.ImportedMixedListen = ""
	profile.ImportedMixedPort = 0
	profile.ImportedTun = false
	var config struct {
		Inbounds []struct {
			Type       string `json:"type"`
			Listen     string `json:"listen"`
			ListenPort int    `json:"listen_port"`
		} `json:"inbounds"`
	}
	if json.Unmarshal(profile.Config, &config) != nil {
		return
	}
	for _, inbound := range config.Inbounds {
		switch inbound.Type {
		case "tun":
			profile.ImportedTun = true
		case "mixed":
			if inbound.ListenPort > 0 && (inbound.Listen == "127.0.0.1" || inbound.Listen == "::1" || inbound.Listen == "localhost") {
				profile.ImportedMixedListen = inbound.Listen
				profile.ImportedMixedPort = inbound.ListenPort
			}
		}
	}
}

// Normalize applies the same migration and defaults used when opening a state
// file. Backup import uses this before it can become a runtime candidate.
func Normalize(f File) File { return mergeDefaults(f) }

// TouchProfile advances the internal cache revision while retaining the
// second-granularity timestamp exposed in the UI. Every mutation that can
// affect a rendered node view must use this instead of assigning UpdatedAt.
func TouchProfile(profile *ConfigProfile) {
	profile.UpdatedAt = time.Now().Unix()
	profile.Revision++
}

func profileExists(profiles []ConfigProfile, id string) bool {
	for _, p := range profiles {
		if p.ID == id {
			return true
		}
	}
	return false
}

// ActiveProfile returns a copy of the unique active profile.
func (f File) ActiveProfile() *ConfigProfile {
	for i := range f.Profiles {
		if f.Profiles[i].ID == f.ActiveConfigID {
			p := f.Profiles[i]
			return &p
		}
	}
	return nil
}

func (s *Store) saveLocked() error {
	return s.saveFileLocked(s.cur)
}

func (s *Store) saveFileLocked(f File) error {
	return s.savePersisted(f)
}

func (s *Store) Get() File {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return clone(s.cur)
}

// Active returns the runtime portion of state without cloning inactive
// profiles.  It is for high-frequency polling and status paths; mutations
// must continue to use Get/Update.
func (s *Store) Active() File {
	s.mu.RLock()
	defer s.mu.RUnlock()
	f := s.cur
	f.Settings.ProxyBypass = append([]string(nil), s.cur.Settings.ProxyBypass...)
	f.RecentNodes = append([]string(nil), s.cur.RecentNodes...)
	f.Runtime.History = append([]RunEvent(nil), s.cur.Runtime.History...)
	f.Rules = nil
	f.Profiles = nil
	for _, profile := range s.cur.Profiles {
		if profile.ID == s.cur.ActiveConfigID {
			active := activeProfileSnapshot(profile)
			f.Profiles = []ConfigProfile{active}
			break
		}
	}
	return f
}

func activeProfileSnapshot(profile ConfigProfile) ConfigProfile {
	if profile.Kind != ProfileKindSubscription {
		// Active is a read-only runtime view. All mutation paths use Get/Update
		// and therefore clone their candidate state first. Retaining these node
		// slices here avoids deep-copying every outbound on status, poll and
		// delay paths while preserving that mutation boundary.
		return profile
	}
	// Do not call cloneProfile here: it deliberately deep-copies Config for
	// mutation candidates, which would allocate the entire imported document on
	// every status poll only to discard it immediately.
	active := profile
	active.Config = nil
	active.Sources = nil
	active.ManualNodes = nil
	active.RefreshHistory = append([]RefreshEvent(nil), profile.RefreshHistory...)
	return active
}

func (s *Store) Update(fn func(*File) error) (File, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur := clone(s.cur)
	if err := fn(&cur); err != nil {
		return File{}, err
	}
	if err := s.saveFileLocked(cur); err != nil {
		return File{}, err
	}
	s.cur = cur
	return clone(s.cur), nil
}

func clone(f File) File {
	out := f
	out.Settings.ProxyBypass = append([]string(nil), f.Settings.ProxyBypass...)
	out.Rules = append([]Rule(nil), f.Rules...)
	out.RecentNodes = append([]string(nil), f.RecentNodes...)
	out.Runtime.History = append([]RunEvent(nil), f.Runtime.History...)
	out.Profiles = make([]ConfigProfile, len(f.Profiles))
	for i, profile := range f.Profiles {
		out.Profiles[i] = cloneProfile(profile)
	}
	out.Scripts = append([]ScriptItem(nil), f.Scripts...)
	return out
}

// CloneFile returns an independent state snapshot for candidate mutations.
// Callers must use it instead of a struct assignment because File contains
// nested slices with shared backing storage.
func CloneFile(f File) File { return clone(f) }

func cloneProfile(profile ConfigProfile) ConfigProfile {
	out := profile
	out.Config = append(json.RawMessage(nil), profile.Config...)
	out.RefreshHistory = append([]RefreshEvent(nil), profile.RefreshHistory...)
	out.ManualNodes = cloneNodes(profile.ManualNodes)
	out.Sources = make([]ConfigSource, len(profile.Sources))
	for i, source := range profile.Sources {
		out.Sources[i] = source
		out.Sources[i].Nodes = cloneNodes(source.Nodes)
	}
	return out
}

// CloneProfile returns an independent profile snapshot for candidate refresh
// and rendering paths that must never mutate the prior running snapshot.
func CloneProfile(profile ConfigProfile) ConfigProfile { return cloneProfile(profile) }

func cloneNodes(nodes []Node) []Node {
	out := make([]Node, len(nodes))
	for i, node := range nodes {
		out[i] = node
		out[i].Outbound = append(json.RawMessage(nil), node.Outbound...)
	}
	return out
}

func NewID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func RetentionDuration(s string) time.Duration {
	switch s {
	case "5m":
		return 5 * time.Minute
	case "1h":
		return time.Hour
	case "6h":
		return 6 * time.Hour
	case "24h":
		return 24 * time.Hour
	default:
		return 15 * time.Minute
	}
}
