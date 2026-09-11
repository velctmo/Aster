package app

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"aster/internal/state"
)

const (
	maxBackupBytes = 32 << 20

	portableBackupFormat  = "app.aster.portable-backup"
	portableBackupVersion = 1
	backupManifestName    = "manifest.json"
	backupSettingsName    = "settings.json"
	backupRulesName       = "rules.json"
	backupProfilesDir     = "profiles"
	backupScriptsDir      = "scripts"
	iCloudBackupName      = "aster-backup.zip"
)

// portableBackup is intentionally narrower than state.File. It contains the
// user's configuration, but never credentials, local ports, core paths,
// captured networking state, or operational history from another Mac.
type portableBackup struct {
	Version        int                     `json:"version"`
	Settings       portableBackupSettings  `json:"settings"`
	Mode           string                  `json:"mode"`
	Selected       string                  `json:"selected"`
	Profiles       []portableBackupProfile `json:"profiles"`
	Rules          []state.Rule            `json:"rules"`
	Scripts        []portableBackupScript  `json:"scripts"`
	ActiveConfigID string                  `json:"activeConfigId"`
}

type portableBackupSettings struct {
	DirectCN         bool     `json:"directCN"`
	DNSMode          string   `json:"dnsMode"`
	ProxyBypass      []string `json:"proxyBypass"`
	DelayURL         string   `json:"delayURL"`
	DelayTimeoutMs   int      `json:"delayTimeoutMs"`
	DelayConcurrency int      `json:"delayConcurrency"`
	StrictRoute      bool     `json:"strictRoute"`
	SubIntervalHours int      `json:"subIntervalHours"`
	LogRetention     string   `json:"logRetention"`
	LogLevel         string   `json:"logLevel"`
	NodeView         string   `json:"nodeView"`
	Theme            string   `json:"theme"`
}

type portableBackupProfile struct {
	ID          string                       `json:"id"`
	Name        string                       `json:"name"`
	Kind        string                       `json:"kind"`
	Source      string                       `json:"source,omitempty"`
	Config      json.RawMessage              `json:"config,omitempty"`
	Sources     []portableBackupConfigSource `json:"sources,omitempty"`
	ManualNodes []state.Node                 `json:"manualNodes,omitempty"`
	UpdatedAt   int64                        `json:"updatedAt"`
	ScriptID    string                       `json:"scriptId,omitempty"`
}

type portableBackupConfigSource struct {
	ID    string       `json:"id"`
	URL   string       `json:"url"`
	Nodes []state.Node `json:"nodes"`
}

type portableBackupScript struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	Content   string `json:"content"`
	UpdatedAt int64  `json:"updatedAt"`
}

type portableBackupManifest struct {
	Format    string   `json:"format"`
	Version   int      `json:"version"`
	Entries   []string `json:"entries"`
	CreatedAt int64    `json:"createdAt"`
}

type portableSettingsDocument struct {
	Version          int      `json:"version"`
	DirectCN         bool     `json:"directCN"`
	DNSMode          string   `json:"dnsMode"`
	ProxyBypass      []string `json:"proxyBypass"`
	DelayURL         string   `json:"delayURL"`
	DelayTimeoutMs   int      `json:"delayTimeoutMs"`
	DelayConcurrency int      `json:"delayConcurrency"`
	StrictRoute      bool     `json:"strictRoute"`
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

type portableProfileDocument struct {
	Version int                   `json:"version"`
	Profile portableBackupProfile `json:"profile"`
}

type portableScriptDocument struct {
	Version int                  `json:"version"`
	Script  portableBackupScript `json:"script"`
}

type portableRulesDocument struct {
	Version int          `json:"version"`
	Rules   []state.Rule `json:"rules"`
}

func (a *App) ExportZip() ([]byte, error) {
	return encodePortableBackup(portableBackupFromState(a.st.Get()))
}

func (a *App) ImportZip(r io.Reader) error {
	backup, err := decodePortableBackup(r)
	if err != nil {
		return err
	}
	return a.restorePortableBackup(backup)
}

func portableBackupFromState(f state.File) portableBackup {
	profiles := make([]portableBackupProfile, len(f.Profiles))
	for i, profile := range f.Profiles {
		sources := make([]portableBackupConfigSource, len(profile.Sources))
		for j, source := range profile.Sources {
			sources[j] = portableBackupConfigSource{
				ID: source.ID, URL: source.URL, Nodes: source.Nodes,
			}
		}
		profiles[i] = portableBackupProfile{
			ID: profile.ID, Name: profile.Name, Kind: profile.Kind, Source: profile.Source,
			Config: profile.Config, Sources: sources, ManualNodes: profile.ManualNodes,
			UpdatedAt: profile.UpdatedAt, ScriptID: profile.ScriptID,
		}
	}
	scripts := make([]portableBackupScript, len(f.Scripts))
	for i, script := range f.Scripts {
		scripts[i] = portableBackupScript{
			ID: script.ID, Name: script.Name, Kind: script.Kind,
			Content: script.Content, UpdatedAt: script.UpdatedAt,
		}
	}
	return portableBackup{
		Version: portableBackupVersion,
		Settings: portableBackupSettings{
			DirectCN: f.Settings.DirectCN, DNSMode: f.Settings.DNSMode,
			ProxyBypass: append([]string(nil), f.Settings.ProxyBypass...),
			DelayURL:    f.Settings.DelayURL, DelayTimeoutMs: f.Settings.DelayTimeoutMs,
			DelayConcurrency: f.Settings.DelayConcurrency, StrictRoute: f.Settings.StrictRoute,
			SubIntervalHours: f.Settings.SubIntervalHours,
			LogRetention:     f.Settings.LogRetention, LogLevel: f.Settings.LogLevel,
			NodeView: f.Settings.NodeView, Theme: f.Settings.Theme,
		},
		Mode: f.Mode, Selected: f.Selected, Profiles: profiles,
		Rules: append([]state.Rule(nil), f.Rules...), Scripts: scripts,
		ActiveConfigID: f.ActiveConfigID,
	}
}

func encodePortableBackup(backup portableBackup) ([]byte, error) {
	if err := validatePortableBackup(backup); err != nil {
		return nil, err
	}
	entries, err := portableBackupEntries(backup)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for name := range entries {
		names = append(names, name)
	}
	sort.Strings(names)
	manifest, err := json.MarshalIndent(portableBackupManifest{
		Format: portableBackupFormat, Version: portableBackupVersion,
		Entries: names, CreatedAt: time.Now().Unix(),
	}, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("编码备份清单失败: %w", err)
	}

	var archive bytes.Buffer
	writer := zip.NewWriter(&archive)
	archiveEntries := append([]string{backupManifestName}, names...)
	for _, name := range archiveEntries {
		data := manifest
		if name != backupManifestName {
			data = entries[name]
		}
		file, err := writer.Create(name)
		if err != nil {
			_ = writer.Close()
			return nil, fmt.Errorf("创建备份条目失败: %w", err)
		}
		if _, err := file.Write(data); err != nil {
			_ = writer.Close()
			return nil, fmt.Errorf("写入备份条目失败: %w", err)
		}
	}
	if err := writer.Close(); err != nil {
		return nil, fmt.Errorf("完成备份归档失败: %w", err)
	}
	return archive.Bytes(), nil
}

func decodePortableBackup(r io.Reader) (portableBackup, error) {
	data, err := io.ReadAll(io.LimitReader(r, maxBackupBytes+1))
	if err != nil {
		return portableBackup{}, fmt.Errorf("读取备份失败: %w", err)
	}
	if len(data) > maxBackupBytes {
		return portableBackup{}, fmt.Errorf("备份文件超过 32 MiB 限制")
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return portableBackup{}, fmt.Errorf("备份不是有效的 ZIP 归档: %w", err)
	}

	entries := make(map[string][]byte, 2)
	var totalSize uint64
	for _, entry := range reader.File {
		if entry.FileInfo().IsDir() || !isPortableBackupEntry(entry.Name) {
			return portableBackup{}, fmt.Errorf("备份包含不支持的条目: %s", entry.Name)
		}
		if _, duplicate := entries[entry.Name]; duplicate {
			return portableBackup{}, fmt.Errorf("备份包含重复条目: %s", entry.Name)
		}
		if entry.UncompressedSize64 > maxBackupBytes || totalSize > maxBackupBytes-entry.UncompressedSize64 {
			return portableBackup{}, fmt.Errorf("备份解压后超过 32 MiB 限制")
		}
		totalSize += entry.UncompressedSize64
		file, err := entry.Open()
		if err != nil {
			return portableBackup{}, fmt.Errorf("读取备份条目失败: %w", err)
		}
		body, readErr := io.ReadAll(io.LimitReader(file, maxBackupBytes+1))
		closeErr := file.Close()
		if readErr != nil {
			return portableBackup{}, fmt.Errorf("读取备份条目失败: %w", readErr)
		}
		if closeErr != nil {
			return portableBackup{}, fmt.Errorf("关闭备份条目失败: %w", closeErr)
		}
		if uint64(len(body)) != entry.UncompressedSize64 || len(body) > maxBackupBytes {
			return portableBackup{}, fmt.Errorf("备份条目大小无效: %s", entry.Name)
		}
		entries[entry.Name] = body
	}

	manifestData, hasManifest := entries[backupManifestName]
	settingsData, hasSettings := entries[backupSettingsName]
	rulesData, hasRules := entries[backupRulesName]
	if !hasManifest || !hasSettings || !hasRules {
		return portableBackup{}, fmt.Errorf("备份必须包含 %s、%s 和 %s", backupManifestName, backupSettingsName, backupRulesName)
	}
	var manifest portableBackupManifest
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		return portableBackup{}, fmt.Errorf("备份清单损坏: %w", err)
	}
	if manifest.Format != portableBackupFormat || manifest.Version != portableBackupVersion || !sameEntrySet(manifest.Entries, entries) {
		return portableBackup{}, fmt.Errorf("不支持的备份格式或版本")
	}
	var settings portableSettingsDocument
	if err := json.Unmarshal(settingsData, &settings); err != nil {
		return portableBackup{}, fmt.Errorf("备份设置损坏: %w", err)
	}
	if settings.Version != portableBackupVersion {
		return portableBackup{}, fmt.Errorf("不支持的备份设置版本: %d", settings.Version)
	}
	var rules portableRulesDocument
	if err := json.Unmarshal(rulesData, &rules); err != nil {
		return portableBackup{}, fmt.Errorf("备份规则损坏: %w", err)
	}
	if rules.Version != portableBackupVersion {
		return portableBackup{}, fmt.Errorf("不支持的备份规则版本: %d", rules.Version)
	}
	backup := portableBackup{
		Version:  portableBackupVersion,
		Settings: portableSettingsDocumentSettings(settings),
		Mode:     settings.Mode, Selected: settings.Selected,
		Rules: rules.Rules, ActiveConfigID: settings.ActiveConfigID,
		Profiles: make([]portableBackupProfile, len(settings.ProfileIDs)),
		Scripts:  make([]portableBackupScript, len(settings.ScriptIDs)),
	}
	for i, id := range settings.ProfileIDs {
		name, err := portableDocumentName(backupProfilesDir, id)
		if err != nil {
			return portableBackup{}, fmt.Errorf("备份设置包含无效配置 ID: %w", err)
		}
		data, exists := entries[name]
		if !exists {
			return portableBackup{}, fmt.Errorf("备份缺少配置文件: %s", id)
		}
		var document portableProfileDocument
		if err := json.Unmarshal(data, &document); err != nil || document.Version != portableBackupVersion || document.Profile.ID != id {
			return portableBackup{}, fmt.Errorf("备份配置文件无效: %s", id)
		}
		backup.Profiles[i] = document.Profile
	}
	for i, id := range settings.ScriptIDs {
		name, err := portableDocumentName(backupScriptsDir, id)
		if err != nil {
			return portableBackup{}, fmt.Errorf("备份设置包含无效脚本 ID: %w", err)
		}
		data, exists := entries[name]
		if !exists {
			return portableBackup{}, fmt.Errorf("备份缺少脚本文件: %s", id)
		}
		var document portableScriptDocument
		if err := json.Unmarshal(data, &document); err != nil || document.Version != portableBackupVersion || document.Script.ID != id {
			return portableBackup{}, fmt.Errorf("备份脚本文件无效: %s", id)
		}
		backup.Scripts[i] = document.Script
	}
	if err := validatePortableBackup(backup); err != nil {
		return portableBackup{}, err
	}
	return backup, nil
}

func portableBackupEntries(backup portableBackup) (map[string][]byte, error) {
	entries := make(map[string][]byte, len(backup.Profiles)+len(backup.Scripts)+2)
	profileIDs := make([]string, len(backup.Profiles))
	for i, profile := range backup.Profiles {
		name, err := portableDocumentName(backupProfilesDir, profile.ID)
		if err != nil {
			return nil, fmt.Errorf("无效的配置 ID: %w", err)
		}
		if _, duplicate := entries[name]; duplicate {
			return nil, fmt.Errorf("备份包含重复配置 ID: %s", profile.ID)
		}
		profileIDs[i] = profile.ID
		entries[name], err = json.MarshalIndent(portableProfileDocument{Version: portableBackupVersion, Profile: profile}, "", "  ")
		if err != nil {
			return nil, fmt.Errorf("编码配置 %s 失败: %w", profile.ID, err)
		}
	}
	scriptIDs := make([]string, len(backup.Scripts))
	for i, script := range backup.Scripts {
		name, err := portableDocumentName(backupScriptsDir, script.ID)
		if err != nil {
			return nil, fmt.Errorf("无效的脚本 ID: %w", err)
		}
		if _, duplicate := entries[name]; duplicate {
			return nil, fmt.Errorf("备份包含重复脚本 ID: %s", script.ID)
		}
		scriptIDs[i] = script.ID
		entries[name], err = json.MarshalIndent(portableScriptDocument{Version: portableBackupVersion, Script: script}, "", "  ")
		if err != nil {
			return nil, fmt.Errorf("编码脚本 %s 失败: %w", script.ID, err)
		}
	}
	settings := portableSettingsDocument{
		Version:  portableBackupVersion,
		DirectCN: backup.Settings.DirectCN, DNSMode: backup.Settings.DNSMode,
		ProxyBypass: append([]string(nil), backup.Settings.ProxyBypass...),
		DelayURL:    backup.Settings.DelayURL, DelayTimeoutMs: backup.Settings.DelayTimeoutMs,
		DelayConcurrency: backup.Settings.DelayConcurrency, StrictRoute: backup.Settings.StrictRoute,
		SubIntervalHours: backup.Settings.SubIntervalHours,
		LogRetention:     backup.Settings.LogRetention, LogLevel: backup.Settings.LogLevel,
		NodeView: backup.Settings.NodeView, Theme: backup.Settings.Theme,
		Mode: backup.Mode, Selected: backup.Selected, ActiveConfigID: backup.ActiveConfigID,
		ProfileIDs: profileIDs, ScriptIDs: scriptIDs,
	}
	var err error
	entries[backupSettingsName], err = json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("编码备份设置失败: %w", err)
	}
	entries[backupRulesName], err = json.MarshalIndent(portableRulesDocument{Version: portableBackupVersion, Rules: backup.Rules}, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("编码备份规则失败: %w", err)
	}
	return entries, nil
}

func portableSettingsDocumentSettings(document portableSettingsDocument) portableBackupSettings {
	return portableBackupSettings{
		DirectCN: document.DirectCN, DNSMode: document.DNSMode,
		ProxyBypass: append([]string(nil), document.ProxyBypass...),
		DelayURL:    document.DelayURL, DelayTimeoutMs: document.DelayTimeoutMs,
		DelayConcurrency: document.DelayConcurrency, StrictRoute: document.StrictRoute,
		SubIntervalHours: document.SubIntervalHours,
		LogRetention:     document.LogRetention, LogLevel: document.LogLevel,
		NodeView: document.NodeView, Theme: document.Theme,
	}
}

func isPortableBackupEntry(name string) bool {
	if name == backupManifestName || name == backupSettingsName || name == backupRulesName {
		return true
	}
	for _, directory := range []string{backupProfilesDir, backupScriptsDir} {
		prefix := directory + "/"
		if !strings.HasPrefix(name, prefix) {
			continue
		}
		id := strings.TrimSuffix(strings.TrimPrefix(name, prefix), ".json")
		expected, err := portableDocumentName(directory, id)
		return err == nil && expected == name
	}
	return false
}

func portableDocumentName(directory, id string) (string, error) {
	if id == "" {
		return "", fmt.Errorf("ID 不能为空")
	}
	for _, character := range id {
		if (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') || character == '-' || character == '_' {
			continue
		}
		return "", fmt.Errorf("ID 包含不支持的字符")
	}
	return directory + "/" + id + ".json", nil
}

func sameEntrySet(declared []string, entries map[string][]byte) bool {
	if len(declared) != len(entries)-1 {
		return false
	}
	seen := make(map[string]struct{}, len(declared))
	for _, name := range declared {
		if name == backupManifestName || !isPortableBackupEntry(name) {
			return false
		}
		if _, duplicate := seen[name]; duplicate {
			return false
		}
		if _, exists := entries[name]; !exists {
			return false
		}
		seen[name] = struct{}{}
	}
	return true
}

func (a *App) restorePortableBackup(backup portableBackup) error {
	a.mutationMu.Lock()
	defer a.mutationMu.Unlock()

	current := a.st.Get()
	candidate := state.Normalize(portableBackupState(backup, current))
	if err := validateBackupCandidate(candidate); err != nil {
		return fmt.Errorf("备份配置无效: %w", err)
	}
	if _, err := a.st.Update(func(file *state.File) error {
		*file = candidate
		return nil
	}); err != nil {
		return fmt.Errorf("保存恢复后的配置失败: %w", err)
	}
	return nil
}

func portableBackupState(backup portableBackup, current state.File) state.File {
	candidate := state.CloneFile(current)
	settings := candidate.Settings
	settings.DirectCN = backup.Settings.DirectCN
	settings.DNSMode = backup.Settings.DNSMode
	settings.ProxyBypass = append([]string(nil), backup.Settings.ProxyBypass...)
	settings.DelayURL = backup.Settings.DelayURL
	settings.DelayTimeoutMs = backup.Settings.DelayTimeoutMs
	settings.DelayConcurrency = backup.Settings.DelayConcurrency
	settings.StrictRoute = backup.Settings.StrictRoute
	settings.SubIntervalHours = backup.Settings.SubIntervalHours
	settings.LogRetention = backup.Settings.LogRetention
	settings.LogLevel = backup.Settings.LogLevel
	settings.NodeView = backup.Settings.NodeView
	settings.Theme = backup.Settings.Theme
	candidate.Settings = settings
	candidate.Mode = backup.Mode
	candidate.Selected = backup.Selected
	candidate.Profiles = make([]state.ConfigProfile, len(backup.Profiles))
	for i, profile := range backup.Profiles {
		sources := make([]state.ConfigSource, len(profile.Sources))
		for j, source := range profile.Sources {
			sources[j] = state.ConfigSource{ID: source.ID, URL: source.URL, Nodes: source.Nodes}
		}
		candidate.Profiles[i] = state.ConfigProfile{
			ID: profile.ID, Name: profile.Name, Kind: profile.Kind, Source: profile.Source,
			Config: profile.Config, Sources: sources, ManualNodes: profile.ManualNodes,
			UpdatedAt: profile.UpdatedAt, Revision: 1, ScriptID: profile.ScriptID,
		}
	}
	candidate.Rules = append([]state.Rule(nil), backup.Rules...)
	candidate.Scripts = make([]state.ScriptItem, len(backup.Scripts))
	for i, script := range backup.Scripts {
		candidate.Scripts[i] = state.ScriptItem{
			ID: script.ID, Name: script.Name, Kind: script.Kind,
			Content: script.Content, UpdatedAt: script.UpdatedAt,
		}
	}
	candidate.ActiveConfigID = backup.ActiveConfigID
	candidate.RecentNodes = nil
	candidate.Runtime = state.RuntimeState{}
	return candidate
}

func validatePortableBackup(backup portableBackup) error {
	if backup.Version != portableBackupVersion {
		return fmt.Errorf("不支持的便携备份版本: %d", backup.Version)
	}
	switch backup.Mode {
	case "rule", "global", "direct":
	default:
		return fmt.Errorf("备份包含不支持的代理模式: %s", backup.Mode)
	}
	if len(backup.Profiles) == 0 || strings.TrimSpace(backup.ActiveConfigID) == "" {
		return fmt.Errorf("备份中没有可用活动配置")
	}
	return nil
}

func iCloudDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	base := filepath.Join(home, "Library", "Mobile Documents", "com~apple~CloudDocs")
	if fi, err := os.Stat(base); err != nil || !fi.IsDir() {
		return ""
	}
	target := filepath.Join(base, "Aster")
	if err := os.MkdirAll(target, 0o700); err != nil {
		return ""
	}
	if err := os.Chmod(target, 0o700); err != nil {
		return ""
	}
	return target
}

func (a *App) ICloudStatus() map[string]any {
	dir := iCloudDir()
	available := dir != ""
	hasBackup := false
	var modTime int64
	if available {
		backupPath := filepath.Join(dir, iCloudBackupName)
		if info, err := os.Stat(backupPath); err == nil && !info.IsDir() {
			hasBackup = true
			modTime = info.ModTime().Unix()
		}
	}
	return map[string]any{"available": available, "hasBackup": hasBackup, "updatedAt": modTime}
}

func (a *App) ExportToICloud() error {
	dir := iCloudDir()
	if dir == "" {
		return fmt.Errorf("当前 Mac 未开启 iCloud Drive 或未登录 Apple ID")
	}
	archive, err := a.ExportZip()
	if err != nil {
		return err
	}
	return writePrivateAtomic(filepath.Join(dir, iCloudBackupName), archive)
}

func (a *App) ImportFromICloud() error {
	dir := iCloudDir()
	if dir == "" {
		return fmt.Errorf("当前 Mac 未开启 iCloud Drive 或未登录 Apple ID")
	}
	file, err := os.Open(filepath.Join(dir, iCloudBackupName))
	if err != nil {
		return fmt.Errorf("未能读取 iCloud 备份: %w", err)
	}
	defer file.Close()
	if err := a.ImportZip(file); err != nil {
		return fmt.Errorf("iCloud 备份无效: %w", err)
	}
	return nil
}

func writePrivateAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".aster-backup-*")
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
