package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const persistenceVersion = 1

// settingsDocument is the portable, user-owned part of Aster's global
// configuration. It deliberately excludes ports, credentials, helper state
// and other facts that belong to one Mac only.
type settingsDocument struct {
	Version          int      `json:"version"`
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
	LogLevel         string   `json:"logLevel"`
	NodeView         string   `json:"nodeView"`
	Theme            string   `json:"theme"`
	Mode             string   `json:"mode"`
	Selected         string   `json:"selected"`
	ActiveConfigID   string   `json:"activeConfigId"`
	ProfileIDs       []string `json:"profileIds"`
	ScriptIDs        []string `json:"scriptIds"`
}

// machineDocument holds data that must never leave the current Mac. It is
// private on disk and is intentionally excluded from every backup archive.
type machineDocument struct {
	Version     int          `json:"version"`
	CorePath    string       `json:"corePath"`
	MixedPort   int          `json:"mixedPort"`
	ClashPort   int          `json:"clashPort"`
	ControlPort int          `json:"controlPort"`
	AllowLan    bool         `json:"allowLan"`
	Autostart   bool         `json:"autostart"`
	AutoConnect bool         `json:"autoConnect"`
	Capture     Capture      `json:"capture"`
	Wanted      bool         `json:"wanted"`
	ClashSecret string       `json:"clashSecret"`
	APIToken    string       `json:"apiToken"`
	RecentNodes []string     `json:"recentNodes"`
	Runtime     RuntimeState `json:"runtime"`
}

type profileDocument struct {
	Version int           `json:"version"`
	Profile ConfigProfile `json:"profile"`
}

type scriptDocument struct {
	Version int        `json:"version"`
	Script  ScriptItem `json:"script"`
}

type rulesDocument struct {
	Version int    `json:"version"`
	Rules   []Rule `json:"rules"`
}

func (s *Store) loadPersisted() error {
	fresh, err := s.isFreshStorage()
	if err != nil {
		return err
	}
	if fresh {
		s.cur = DefaultFile()
		return s.saveLocked()
	}

	var settings settingsDocument
	if err := readJSON(s.settingsPath, &settings); err != nil {
		return fmt.Errorf("读取 settings.json 失败: %w", err)
	}
	if settings.Version != persistenceVersion {
		return fmt.Errorf("不支持的 settings.json 版本: %d", settings.Version)
	}
	var machine machineDocument
	if err := readJSON(s.machinePath, &machine); err != nil {
		return fmt.Errorf("读取 machine.json 失败: %w", err)
	}
	if machine.Version != persistenceVersion {
		return fmt.Errorf("不支持的 machine.json 版本: %d", machine.Version)
	}
	var rules rulesDocument
	if err := readJSON(s.rulesPath, &rules); err != nil {
		return fmt.Errorf("读取 rules.json 失败: %w", err)
	}
	if rules.Version != persistenceVersion {
		return fmt.Errorf("不支持的 rules.json 版本: %d", rules.Version)
	}

	f := DefaultFile()
	applySettingsDocument(&f, settings)
	applyMachineDocument(&f, machine)
	f.Rules = append([]Rule(nil), rules.Rules...)
	profiles, err := s.readProfiles(settings.ProfileIDs)
	if err != nil {
		return err
	}
	scripts, err := s.readScripts(settings.ScriptIDs)
	if err != nil {
		return err
	}
	f.Profiles = profiles
	f.Scripts = scripts
	s.cur = mergeDefaults(f)
	return nil
}

func (s *Store) isFreshStorage() (bool, error) {
	paths := []string{s.settingsPath, s.machinePath, s.rulesPath, s.profilesDir, s.scriptsDir}
	for _, path := range paths {
		_, err := os.Stat(path)
		if err == nil {
			return false, nil
		}
		if !os.IsNotExist(err) {
			return false, err
		}
	}
	return true, nil
}

func (s *Store) savePersisted(f File) error {
	settings, machine, rules, profileDocs, scriptDocs, err := persistedDocuments(f)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(s.profilesDir, 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(s.scriptsDir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(s.profilesDir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(s.scriptsDir, 0o700); err != nil {
		return err
	}

	profileNames := make(map[string]struct{}, len(profileDocs))
	for id, data := range profileDocs {
		name, err := documentFilename(id)
		if err != nil {
			return err
		}
		profileNames[name] = struct{}{}
		if err := writePrivateAtomic(filepath.Join(s.profilesDir, name), data); err != nil {
			return fmt.Errorf("写入配置 %s 失败: %w", id, err)
		}
	}
	scriptNames := make(map[string]struct{}, len(scriptDocs))
	for id, data := range scriptDocs {
		name, err := documentFilename(id)
		if err != nil {
			return err
		}
		scriptNames[name] = struct{}{}
		if err := writePrivateAtomic(filepath.Join(s.scriptsDir, name), data); err != nil {
			return fmt.Errorf("写入脚本 %s 失败: %w", id, err)
		}
	}
	if err := writePrivateAtomic(s.rulesPath, rules); err != nil {
		return fmt.Errorf("写入 rules.json 失败: %w", err)
	}
	if err := writePrivateAtomic(s.machinePath, machine); err != nil {
		return fmt.Errorf("写入 machine.json 失败: %w", err)
	}
	// settings.json commits the exact profile and script lists. A stale document
	// left by an interrupted update is ignored until it can be safely removed.
	if err := writePrivateAtomic(s.settingsPath, settings); err != nil {
		return fmt.Errorf("写入 settings.json 失败: %w", err)
	}
	if err := removeStaleDocuments(s.profilesDir, profileNames); err != nil {
		return err
	}
	if err := removeStaleDocuments(s.scriptsDir, scriptNames); err != nil {
		return err
	}
	return nil
}

func persistedDocuments(f File) (settings, machine, rules []byte, profiles, scripts map[string][]byte, err error) {
	profileIDs := make([]string, len(f.Profiles))
	profiles = make(map[string][]byte, len(f.Profiles))
	for i, profile := range f.Profiles {
		if _, err := documentFilename(profile.ID); err != nil {
			return nil, nil, nil, nil, nil, fmt.Errorf("无效的配置 ID: %w", err)
		}
		if _, duplicate := profiles[profile.ID]; duplicate {
			return nil, nil, nil, nil, nil, fmt.Errorf("重复的配置 ID: %s", profile.ID)
		}
		profileIDs[i] = profile.ID
		profiles[profile.ID], err = json.MarshalIndent(profileDocument{Version: persistenceVersion, Profile: profile}, "", "  ")
		if err != nil {
			return nil, nil, nil, nil, nil, err
		}
	}
	scriptIDs := make([]string, len(f.Scripts))
	scripts = make(map[string][]byte, len(f.Scripts))
	for i, script := range f.Scripts {
		if _, err := documentFilename(script.ID); err != nil {
			return nil, nil, nil, nil, nil, fmt.Errorf("无效的脚本 ID: %w", err)
		}
		if _, duplicate := scripts[script.ID]; duplicate {
			return nil, nil, nil, nil, nil, fmt.Errorf("重复的脚本 ID: %s", script.ID)
		}
		scriptIDs[i] = script.ID
		scripts[script.ID], err = json.MarshalIndent(scriptDocument{Version: persistenceVersion, Script: script}, "", "  ")
		if err != nil {
			return nil, nil, nil, nil, nil, err
		}
	}
	settings, err = json.MarshalIndent(settingsDocumentFromFile(f, profileIDs, scriptIDs), "", "  ")
	if err != nil {
		return nil, nil, nil, nil, nil, err
	}
	machine, err = json.MarshalIndent(machineDocumentFromFile(f), "", "  ")
	if err != nil {
		return nil, nil, nil, nil, nil, err
	}
	rules, err = json.MarshalIndent(rulesDocument{Version: persistenceVersion, Rules: f.Rules}, "", "  ")
	if err != nil {
		return nil, nil, nil, nil, nil, err
	}
	return settings, machine, rules, profiles, scripts, nil
}

func settingsDocumentFromFile(f File, profileIDs, scriptIDs []string) settingsDocument {
	return settingsDocument{
		Version:  persistenceVersion,
		DirectCN: f.Settings.DirectCN, DNSMode: f.Settings.DNSMode,
		ProxyBypass: append([]string(nil), f.Settings.ProxyBypass...),
		DelayURL:    f.Settings.DelayURL, DelayTimeoutMs: f.Settings.DelayTimeoutMs,
		DelayConcurrency: f.Settings.DelayConcurrency, StrictRoute: f.Settings.StrictRoute,
		PassiveSampling: f.Settings.PassiveSampling, SubIntervalHours: f.Settings.SubIntervalHours,
		LogRetention: f.Settings.LogRetention, LogLevel: f.Settings.LogLevel,
		NodeView: f.Settings.NodeView, Theme: f.Settings.Theme,
		Mode: f.Mode, Selected: f.Selected, ActiveConfigID: f.ActiveConfigID,
		ProfileIDs: profileIDs, ScriptIDs: scriptIDs,
	}
}

func machineDocumentFromFile(f File) machineDocument {
	return machineDocument{
		Version: persistenceVersion, CorePath: f.Settings.CorePath,
		MixedPort: f.Settings.MixedPort, ClashPort: f.Settings.ClashPort,
		ControlPort: f.Settings.ControlPort, AllowLan: f.Settings.AllowLan,
		Autostart: f.Settings.Autostart, AutoConnect: f.Settings.AutoConnect,
		Capture: f.Capture, Wanted: f.Wanted, ClashSecret: f.ClashSecret,
		APIToken: f.APIToken, RecentNodes: append([]string(nil), f.RecentNodes...),
		Runtime: f.Runtime,
	}
}

func applySettingsDocument(f *File, doc settingsDocument) {
	f.Settings.DirectCN = doc.DirectCN
	f.Settings.DNSMode = doc.DNSMode
	f.Settings.ProxyBypass = append([]string(nil), doc.ProxyBypass...)
	f.Settings.DelayURL = doc.DelayURL
	f.Settings.DelayTimeoutMs = doc.DelayTimeoutMs
	f.Settings.DelayConcurrency = doc.DelayConcurrency
	f.Settings.StrictRoute = doc.StrictRoute
	f.Settings.PassiveSampling = doc.PassiveSampling
	f.Settings.SubIntervalHours = doc.SubIntervalHours
	f.Settings.LogRetention = doc.LogRetention
	f.Settings.LogLevel = doc.LogLevel
	f.Settings.NodeView = doc.NodeView
	f.Settings.Theme = doc.Theme
	f.Mode = doc.Mode
	f.Selected = doc.Selected
	f.ActiveConfigID = doc.ActiveConfigID
}

func applyMachineDocument(f *File, doc machineDocument) {
	f.Settings.CorePath = doc.CorePath
	f.Settings.MixedPort = doc.MixedPort
	f.Settings.ClashPort = doc.ClashPort
	f.Settings.ControlPort = doc.ControlPort
	f.Settings.AllowLan = doc.AllowLan
	f.Settings.Autostart = doc.Autostart
	f.Settings.AutoConnect = doc.AutoConnect
	f.Capture = doc.Capture
	f.Wanted = doc.Wanted
	f.ClashSecret = doc.ClashSecret
	f.APIToken = doc.APIToken
	f.RecentNodes = append([]string(nil), doc.RecentNodes...)
	f.Runtime = doc.Runtime
}

func (s *Store) readProfiles(ids []string) ([]ConfigProfile, error) {
	profiles := make([]ConfigProfile, len(ids))
	seen := make(map[string]struct{}, len(ids))
	for i, id := range ids {
		name, err := documentFilename(id)
		if err != nil {
			return nil, fmt.Errorf("settings.json 包含无效配置 ID: %w", err)
		}
		if _, duplicate := seen[id]; duplicate {
			return nil, fmt.Errorf("settings.json 包含重复配置 ID: %s", id)
		}
		seen[id] = struct{}{}
		var doc profileDocument
		if err := readJSON(filepath.Join(s.profilesDir, name), &doc); err != nil {
			return nil, fmt.Errorf("读取配置 %s 失败: %w", id, err)
		}
		if doc.Version != persistenceVersion || doc.Profile.ID != id {
			return nil, fmt.Errorf("配置文件 %s 不匹配", id)
		}
		profiles[i] = doc.Profile
	}
	return profiles, nil
}

func (s *Store) readScripts(ids []string) ([]ScriptItem, error) {
	scripts := make([]ScriptItem, len(ids))
	seen := make(map[string]struct{}, len(ids))
	for i, id := range ids {
		name, err := documentFilename(id)
		if err != nil {
			return nil, fmt.Errorf("settings.json 包含无效脚本 ID: %w", err)
		}
		if _, duplicate := seen[id]; duplicate {
			return nil, fmt.Errorf("settings.json 包含重复脚本 ID: %s", id)
		}
		seen[id] = struct{}{}
		var doc scriptDocument
		if err := readJSON(filepath.Join(s.scriptsDir, name), &doc); err != nil {
			return nil, fmt.Errorf("读取脚本 %s 失败: %w", id, err)
		}
		if doc.Version != persistenceVersion || doc.Script.ID != id {
			return nil, fmt.Errorf("脚本文件 %s 不匹配", id)
		}
		scripts[i] = doc.Script
	}
	return scripts, nil
}

func readJSON(path string, target any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, target)
}

func writePrivateAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".aster-write-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

func removeStaleDocuments(dir string, keep map[string]struct{}) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		if _, exists := keep[entry.Name()]; exists {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("移除已删除的配置文件 %s 失败: %w", entry.Name(), err)
		}
	}
	return nil
}

func documentFilename(id string) (string, error) {
	if id == "" || filepath.Base(id) != id {
		return "", fmt.Errorf("ID 不能为空且不能包含路径")
	}
	for _, character := range id {
		if (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') || character == '-' || character == '_' {
			continue
		}
		return "", fmt.Errorf("ID 包含不支持的字符")
	}
	return id + ".json", nil
}
