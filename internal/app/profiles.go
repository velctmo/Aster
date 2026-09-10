package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"aster/internal/core"
	"aster/internal/render"
	"aster/internal/state"
	"aster/internal/sub"
)

type ProfileJSON struct {
	ID              string               `json:"id"`
	Name            string               `json:"name"`
	Kind            string               `json:"kind"`
	Active          bool                 `json:"active"`
	SourceCount     int                  `json:"sourceCount"`
	NodeCount       int                  `json:"nodeCount"`
	UpdatedAt       int64                `json:"updatedAt"`
	LastError       string               `json:"lastError"`
	HasScript       bool                 `json:"hasScript"`
	Script          string               `json:"script,omitempty"`
	ScriptID        string               `json:"scriptId,omitempty"`
	RecentRefreshes []state.RefreshEvent `json:"recentRefreshes,omitempty"`
	Capabilities    CapabilitiesJSON     `json:"capabilities"`
	Sources         []SourceJSON         `json:"sources,omitempty"`
	InboundSummary  *InboundSummaryJSON  `json:"inboundSummary,omitempty"`
}

// SourceJSON is presentation metadata only. It intentionally exposes a host
// label instead of the stored URL so query-string subscription credentials are
// never sent to the control-plane client.
type SourceJSON struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	NodeCount int    `json:"nodeCount"`
	UpdatedAt int64  `json:"updatedAt"`
	LastError string `json:"lastError"`
}

// InboundSummaryJSON is an inspectable, non-secret description of imported
// full-profile capabilities. It never contains the configuration document.
type InboundSummaryJSON struct {
	MixedLoopback string `json:"mixedLoopback,omitempty"`
	HasTun        bool   `json:"hasTun"`
}

func (a *App) Profiles() []ProfileJSON {
	f := a.st.Get()
	out := make([]ProfileJSON, 0, len(f.Profiles))
	for _, p := range f.Profiles {
		n := len(p.ManualNodes)
		for _, source := range p.Sources {
			n += len(source.Nodes)
		}
		candidate := state.CloneFile(f)
		candidate.ActiveConfigID = p.ID
		hasScript := p.Script != "" || p.ScriptID != ""
		out = append(out, ProfileJSON{ID: p.ID, Name: p.Name, Kind: p.Kind, Active: p.ID == f.ActiveConfigID, SourceCount: len(p.Sources), NodeCount: n, UpdatedAt: p.UpdatedAt, LastError: redactDiagnosticText(p.LastError), HasScript: hasScript, Script: p.Script, ScriptID: p.ScriptID, RecentRefreshes: recentRefreshes(p.RefreshHistory), Capabilities: capabilitiesFor(candidate), Sources: sourceSummaries(p.Sources), InboundSummary: inboundSummary(candidate)})
	}
	return out
}

const refreshHistoryLimit = 24
const refreshHistoryPresentationLimit = 5

func appendRefreshEvent(profile *state.ConfigProfile, sourceID, outcome string, nodeCount int, err error) {
	event := state.RefreshEvent{At: time.Now().Unix(), SourceID: sourceID, Outcome: outcome, NodeCount: nodeCount}
	if err != nil {
		event.Reason = err.Error()
	}
	profile.RefreshHistory = append(profile.RefreshHistory, event)
	if len(profile.RefreshHistory) > refreshHistoryLimit {
		profile.RefreshHistory = append([]state.RefreshEvent(nil), profile.RefreshHistory[len(profile.RefreshHistory)-refreshHistoryLimit:]...)
	}
}

func recentRefreshes(history []state.RefreshEvent) []state.RefreshEvent {
	if len(history) == 0 {
		return nil
	}
	start := len(history) - refreshHistoryPresentationLimit
	if start < 0 {
		start = 0
	}
	out := append([]state.RefreshEvent(nil), history[start:]...)
	for i := range out {
		out[i].Reason = redactDiagnosticText(out[i].Reason)
	}
	return out
}

func inboundSummary(f state.File) *InboundSummaryJSON {
	p := f.ActiveProfile()
	if p == nil || p.Kind != state.ProfileKindSubscription {
		return nil
	}
	caps := render.ImportedInboundCapabilities(f)
	summary := &InboundSummaryJSON{HasTun: caps.Tun}
	if caps.SystemProxy {
		summary.MixedLoopback = fmt.Sprintf("%s:%d", caps.MixedListen, caps.MixedPort)
	}
	return summary
}

func sourceSummaries(sources []state.ConfigSource) []SourceJSON {
	if len(sources) == 0 {
		return nil
	}
	out := make([]SourceJSON, 0, len(sources))
	for _, source := range sources {
		name := "订阅来源"
		if u, err := url.Parse(source.URL); err == nil && u.Hostname() != "" {
			name = u.Hostname()
		}
		out = append(out, SourceJSON{ID: source.ID, Name: name, NodeCount: len(source.Nodes), UpdatedAt: source.UpdatedAt, LastError: redactDiagnosticText(source.LastError)})
	}
	return out
}

func profileName(name, fallback string) string {
	if name = strings.TrimSpace(name); name != "" {
		return name
	}
	return fallback
}

func validHTTPURL(raw string) error {
	u, err := url.ParseRequestURI(strings.TrimSpace(raw))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("仅支持 HTTP(S) URL: %s", raw)
	}
	return nil
}

func validSingBoxConfig(raw string) (json.RawMessage, error) {
	var cfg map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		return nil, fmt.Errorf("订阅模式只接受 sing-box JSON: %w", err)
	}
	outbounds, ok := cfg["outbounds"]
	if !ok {
		return nil, fmt.Errorf("sing-box 配置缺少 outbounds")
	}
	var entries []json.RawMessage
	if err := json.Unmarshal(outbounds, &entries); err != nil {
		return nil, fmt.Errorf("sing-box 配置的 outbounds 必须是数组")
	}
	return json.RawMessage(append([]byte(nil), raw...)), nil
}

func (a *App) CreateSubscriptionProfile(name, source, content string) error {
	source = strings.TrimSpace(source)
	content = strings.TrimSpace(content)
	if source == "" && content == "" {
		return fmt.Errorf("请选择本地 JSON 或输入订阅 URL")
	}
	if source != "" && content != "" {
		return fmt.Errorf("订阅模式只能选择本地 JSON 或订阅 URL 其中一种来源")
	}
	if source != "" {
		if err := validHTTPURL(source); err != nil {
			return err
		}
		meta, err := sub.Fetch(source)
		if err != nil {
			return err
		}
		content = meta.Body
		name = profileName(name, meta.Name)
	}
	cfg, err := validSingBoxConfig(content)
	if err != nil {
		return err
	}
	p := state.ConfigProfile{ID: state.NewID(), Name: profileName(name, "sing-box 配置"), Kind: state.ProfileKindSubscription, Source: source, Config: cfg, UpdatedAt: time.Now().Unix(), Revision: 1}
	state.HydrateImportedCapabilities(&p)
	_, err = a.st.Update(func(cur *state.File) error {
		cur.Profiles = append(cur.Profiles, p)
		return nil
	})
	return err
}

func (a *App) CreateNodeProfile(name string, urls []string) error {
	seen := map[string]bool{}
	p := state.ConfigProfile{ID: state.NewID(), Name: profileName(name, "节点池"), Kind: state.ProfileKindNodes, UpdatedAt: time.Now().Unix(), Revision: 1}
	for _, raw := range urls {
		raw = strings.TrimSpace(raw)
		if raw == "" || seen[raw] {
			continue
		}
		if err := validHTTPURL(raw); err != nil {
			return err
		}
		seen[raw] = true
		p.Sources = append(p.Sources, state.ConfigSource{ID: state.NewID(), URL: raw})
	}
	if len(p.Sources) == 0 {
		return fmt.Errorf("节点模式至少需要一个订阅 URL")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := a.refreshNodeProfile(ctx, &p); err != nil {
		return err
	}
	_, err := a.st.Update(func(cur *state.File) error {
		cur.Profiles = append(cur.Profiles, p)
		return nil
	})
	return err
}

func (a *App) ActivateProfile(id string) error {
	a.mutationMu.Lock()
	defer a.mutationMu.Unlock()
	f := a.st.Get()
	if f.ActiveConfigID == id {
		return nil
	}
	if !profileExists(f.Profiles, id) {
		return fmt.Errorf("配置不存在")
	}
	candidate := state.CloneFile(f)
	candidate.ActiveConfigID = id
	if f.Wanted {
		config, err := render.Config(candidate, a.st.Dir())
		if err != nil {
			return err
		}
		bin, err := core.BinaryFor(candidate)
		if err != nil {
			return err
		}
		path := filepath.Join(a.st.Dir(), "config.candidate.json")
		if err := os.WriteFile(path, config, 0o600); err != nil {
			return err
		}
		defer os.Remove(path)
		if err := core.ValidateConfig(bin, path); err != nil {
			return err
		}
	}
	if !f.Wanted {
		if err := a.writeConfig(candidate); err != nil {
			return err
		}
		if _, err := a.st.Update(func(cur *state.File) error { cur.ActiveConfigID = id; return nil }); err != nil {
			if restoreErr := a.writeConfig(f); restoreErr != nil {
				return fmt.Errorf("保存活动配置失败: %v；恢复旧渲染配置失败: %w", err, restoreErr)
			}
			return fmt.Errorf("保存活动配置失败，已恢复旧渲染配置: %w", err)
		}
		return nil
	}
	// Do not commit the active ID until the candidate has started.  If the
	// restart fails after the old core has been stopped, immediately restore the
	// old rendered config and process before returning the failure.
	// A running core with the same privilege boundary can reload in place. In
	// particular, a TUN-to-TUN profile switch keeps the administrator-authorized
	// process alive and only sends it the rendered configuration reload signal.
	if err := a.apply(candidate, !a.core.CanReload(candidate)); err != nil {
		restoreErr := a.apply(f, true)
		if restoreErr != nil {
			return fmt.Errorf("切换配置失败: %v；恢复旧配置失败: %w", err, restoreErr)
		}
		return fmt.Errorf("切换配置失败，已恢复旧配置: %w", err)
	}
	if _, err := a.st.Update(func(cur *state.File) error { cur.ActiveConfigID = id; return nil }); err != nil {
		if restoreErr := a.apply(f, true); restoreErr != nil {
			return fmt.Errorf("保存活动配置失败: %v；恢复旧配置失败: %w", err, restoreErr)
		}
		return fmt.Errorf("保存活动配置失败，已恢复旧配置: %w", err)
	}
	return nil
}

func (a *App) DeleteProfile(id string) error {
	f := a.st.Get()
	if len(f.Profiles) <= 1 {
		return fmt.Errorf("至少保留一个配置")
	}
	if id == f.ActiveConfigID {
		return fmt.Errorf("请先选择其他配置")
	}
	_, err := a.st.Update(func(cur *state.File) error {
		out := cur.Profiles[:0]
		for _, p := range cur.Profiles {
			if p.ID != id {
				out = append(out, p)
			}
		}
		cur.Profiles = out
		return nil
	})
	return err
}

func (a *App) SetProfileScript(id, source string) error {
	f := a.st.Get()
	candidate := state.CloneFile(f)
	found := false
	for i := range candidate.Profiles {
		if candidate.Profiles[i].ID != id {
			continue
		}
		candidate.Profiles[i].Script = source
		state.TouchProfile(&candidate.Profiles[i])
		found = true
		break
	}
	if !found {
		return fmt.Errorf("配置不存在")
	}
	if id == f.ActiveConfigID && f.Selected != "" && f.Selected != "auto" {
		previousID := ""
		for _, node := range render.Merge(f) {
			if node.Tag == f.Selected || node.NodeID == f.Selected {
				previousID = node.NodeID
				break
			}
		}
		if previousID != "" {
			effective, err := render.Effective(candidate)
			if err != nil {
				return err
			}
			candidate.Selected = "auto"
			for _, node := range render.Merge(effective) {
				if node.NodeID == previousID && !node.Disabled {
					candidate.Selected = node.Tag
					break
				}
			}
		}
	}
	// Render the edited profile before modifying persistent state so an invalid
	// transform cannot become saved configuration. This must target id even when
	// it is currently inactive; otherwise an invalid inactive override would be
	// discovered only during a later activation.
	validation := state.CloneFile(candidate)
	validation.ActiveConfigID = id
	config, err := render.Config(validation, a.st.Dir())
	if err != nil {
		return err
	}
	if f.Wanted && id == f.ActiveConfigID {
		bin, err := core.BinaryFor(candidate)
		if err != nil {
			return err
		}
		path := filepath.Join(a.st.Dir(), "config.candidate.json")
		if err := os.WriteFile(path, config, 0o600); err != nil {
			return err
		}
		defer os.Remove(path)
		if err := core.ValidateConfig(bin, path); err != nil {
			return err
		}
		if err := a.apply(candidate, true); err != nil {
			if restoreErr := a.apply(f, true); restoreErr != nil {
				return fmt.Errorf("覆写应用失败: %v；恢复旧核心失败: %w", err, restoreErr)
			}
			return fmt.Errorf("覆写应用失败，已恢复旧核心: %w", err)
		}
	}
	if !f.Wanted || id != f.ActiveConfigID {
		if err := a.writeConfig(candidate); err != nil {
			return err
		}
	}
	if _, err := a.st.Update(func(cur *state.File) error {
		cur.Selected = candidate.Selected
		for i := range cur.Profiles {
			if cur.Profiles[i].ID == id {
				cur.Profiles[i].Script = source
				cur.Profiles[i].UpdatedAt = candidate.Profiles[i].UpdatedAt
				cur.Profiles[i].Revision = candidate.Profiles[i].Revision
				return nil
			}
		}
		return fmt.Errorf("配置不存在")
	}); err != nil {
		if id == f.ActiveConfigID {
			if restoreErr := a.apply(f, true); restoreErr != nil {
				return fmt.Errorf("保存覆写失败: %v；恢复旧核心失败: %w", err, restoreErr)
			}
		} else {
			_ = a.writeConfig(f)
		}
		return fmt.Errorf("保存覆写失败: %w", err)
	}
	return nil
}

func (a *App) RefreshProfile(id string) (int, error) {
	return a.refreshProfile(context.Background(), id)
}

func (a *App) refreshProfile(parent context.Context, id string) (int, error) {
	f := a.st.Get()
	ctx, cancel := context.WithTimeout(parent, 30*time.Second)
	defer cancel()
	for i := range f.Profiles {
		if f.Profiles[i].ID != id {
			continue
		}
		p := state.CloneProfile(f.Profiles[i])
		var count int
		var err error
		if p.Kind == state.ProfileKindSubscription {
			count, err = refreshSubscriptionProfile(ctx, &p)
		} else {
			count, err = a.refreshNodeProfile(ctx, &p)
		}
		if cancelErr := ctx.Err(); cancelErr != nil {
			return 0, cancelErr
		}
		if err != nil {
			// Source errors are useful state even when all refreshes fail. The
			// failed source keeps its last successful nodes, so this update cannot
			// change the running node set.
			if updateErr := a.replaceProfile(id, p); updateErr != nil {
				return 0, updateErr
			}
			return count, err
		}

		candidate := state.CloneFile(f)
		if !replaceProfileInFile(&candidate, id, p) {
			return 0, fmt.Errorf("配置不存在")
		}
		if id == f.ActiveConfigID && f.Wanted {
			config, renderErr := render.Config(candidate, a.st.Dir())
			if renderErr != nil {
				a.recordRefreshCandidateFailure(f, id, renderErr)
				return 0, renderErr
			}
			bin, findErr := core.BinaryFor(candidate)
			if findErr != nil {
				a.recordRefreshCandidateFailure(f, id, findErr)
				return 0, findErr
			}
			path := filepath.Join(a.st.Dir(), "config.candidate.json")
			if writeErr := os.WriteFile(path, config, 0o600); writeErr != nil {
				a.recordRefreshCandidateFailure(f, id, writeErr)
				return 0, writeErr
			}
			defer os.Remove(path)
			if checkErr := core.ValidateConfig(bin, path); checkErr != nil {
				a.recordRefreshCandidateFailure(f, id, checkErr)
				return 0, checkErr
			}
			if applyErr := a.apply(candidate, true); applyErr != nil {
				if restoreErr := a.apply(f, true); restoreErr != nil {
					a.recordRefreshCandidateFailure(f, id, fmt.Errorf("%v；恢复旧核心失败: %w", applyErr, restoreErr))
					return 0, fmt.Errorf("刷新后重载失败: %v；恢复旧核心失败: %w", applyErr, restoreErr)
				}
				a.recordRefreshCandidateFailure(f, id, applyErr)
				return 0, fmt.Errorf("刷新后重载失败，已恢复旧核心: %w", applyErr)
			}
		}
		if updateErr := a.replaceProfile(id, p); updateErr != nil {
			if id == f.ActiveConfigID && f.Wanted {
				if restoreErr := a.apply(f, true); restoreErr != nil {
					return 0, fmt.Errorf("保存刷新结果失败: %v；恢复旧核心失败: %w", updateErr, restoreErr)
				}
			}
			return 0, fmt.Errorf("保存刷新结果失败: %w", updateErr)
		}
		if id == f.ActiveConfigID && p.Kind == state.ProfileKindNodes {
			a.hub.Broadcast("nodes", a.Nodes())
		}
		return count, nil
	}
	return 0, fmt.Errorf("配置不存在")
}

func (a *App) recordRefreshCandidateFailure(previous state.File, id string, err error) {
	for _, profile := range previous.Profiles {
		if profile.ID == id {
			profile.LastError = err.Error()
			_ = a.replaceProfile(id, profile)
			return
		}
	}
}

func (a *App) replaceProfile(id string, profile state.ConfigProfile) error {
	_, err := a.st.Update(func(cur *state.File) error {
		if !replaceProfileInFile(cur, id, profile) {
			return fmt.Errorf("配置不存在")
		}
		return nil
	})
	return err
}

func replaceProfileInFile(f *state.File, id string, profile state.ConfigProfile) bool {
	for i := range f.Profiles {
		if f.Profiles[i].ID == id {
			f.Profiles[i] = profile
			return true
		}
	}
	return false
}

func (a *App) RefreshAllProfiles() (int, error) {
	return a.refreshAllProfiles(context.Background())
}

func (a *App) refreshAllProfiles(ctx context.Context) (int, error) {
	f := a.st.Get()
	ids := make([]string, 0, len(f.Profiles))
	for _, p := range f.Profiles {
		if p.Kind == state.ProfileKindSubscription && p.Source == "" {
			continue
		}
		ids = append(ids, p.ID)
	}
	if len(ids) == 0 {
		return 0, nil
	}
	type outcome struct {
		updated int
		err     error
	}
	workers := 4
	if len(ids) < workers {
		workers = len(ids)
	}
	jobs := make(chan string)
	results := make(chan outcome, len(ids))
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for id := range jobs {
				n, err := a.refreshProfile(ctx, id)
				results <- outcome{updated: n, err: err}
			}
		}()
	}
	go func() {
		for _, id := range ids {
			select {
			case <-ctx.Done():
				close(jobs)
				wg.Wait()
				close(results)
				return
			case jobs <- id:
			}
		}
		close(jobs)
		wg.Wait()
		close(results)
	}()
	updated, failed := 0, 0
	for result := range results {
		updated += result.updated
		if result.err != nil {
			failed++
		}
	}
	if failed > 0 && updated == 0 {
		return 0, fmt.Errorf("所有可刷新配置更新失败")
	}
	return updated, nil
}

func (a *App) refreshProfileAuto(ctx context.Context) (int, error) {
	return a.refreshAllProfiles(ctx)
}

func refreshSubscriptionProfile(ctx context.Context, p *state.ConfigProfile) (int, error) {
	if p.Source == "" {
		return 0, nil
	}
	meta, err := sub.FetchContext(ctx, p.Source)
	if err != nil {
		p.LastError = err.Error()
		appendRefreshEvent(p, "subscription", "failed", 0, err)
		return 0, err
	}
	cfg, err := validSingBoxConfig(meta.Body)
	if err != nil {
		p.LastError = err.Error()
		appendRefreshEvent(p, "subscription", "failed", 0, err)
		return 0, err
	}
	p.Config, p.LastError = cfg, ""
	state.TouchProfile(p)
	state.HydrateImportedCapabilities(p)
	appendRefreshEvent(p, "subscription", "succeeded", 0, nil)
	return 1, nil
}

func (a *App) refreshNodeProfile(ctx context.Context, p *state.ConfigProfile) (int, error) {
	type result struct {
		index  int
		source state.ConfigSource
		err    error
	}
	if len(p.Sources) == 0 {
		return 0, fmt.Errorf("节点模式没有订阅来源")
	}
	workers := 4
	if len(p.Sources) < workers {
		workers = len(p.Sources)
	}
	jobs := make(chan int)
	results := make(chan result, len(p.Sources))
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				var i int
				var ok bool
				select {
				case <-ctx.Done():
					return
				case i, ok = <-jobs:
				}
				if !ok {
					return
				}
				source := p.Sources[i]
				updated, err := refreshNodeSource(ctx, source)
				results <- result{index: i, source: updated, err: err}
			}
		}()
	}
	go func() {
		for i := range p.Sources {
			select {
			case <-ctx.Done():
				close(jobs)
				wg.Wait()
				close(results)
				return
			case jobs <- i:
			}
		}
		close(jobs)
		wg.Wait()
		close(results)
	}()
	updated := 0
	var last error
	for res := range results {
		p.Sources[res.index] = res.source
		if res.err != nil {
			appendRefreshEvent(p, res.source.ID, "failed", len(res.source.Nodes), res.err)
			last = res.err
			continue
		}
		appendRefreshEvent(p, res.source.ID, "succeeded", len(res.source.Nodes), nil)
		updated++
	}
	state.TouchProfile(p)
	if updated == 0 {
		p.LastError = errorText(last, "所有节点订阅刷新失败")
		return 0, fmt.Errorf("%s", p.LastError)
	}
	p.LastError = ""
	return updated, nil
}

func refreshNodeSource(ctx context.Context, source state.ConfigSource) (state.ConfigSource, error) {
	meta, err := sub.FetchContext(ctx, source.URL)
	if err != nil {
		source.LastError = err.Error()
		return source, err
	}
	parsed, err := sub.Parse(meta.Body)
	if err != nil {
		source.LastError = err.Error()
		return source, err
	}
	filtered := sub.CleanAndFilterNodes(parsed.Nodes, "")
	if len(filtered) == 0 && len(source.Nodes) > 0 {
		source.LastError = "更新内容未包含有效代理节点，已保留上次可用节点"
		return source, fmt.Errorf("未解析到有效代理节点")
	}
	source.Nodes = filtered
	source.UpdatedAt, source.LastError = time.Now().Unix(), ""
	source.Upload, source.Download, source.Total, source.Expire, source.Skipped = meta.Upload, meta.Download, meta.Total, meta.Expire, parsed.Skipped
	return source, nil
}

func errorText(err error, fallback string) string {
	if err != nil {
		return err.Error()
	}
	return fallback
}

func (a *App) requireNodeProfile() error {
	p := a.st.Active().ActiveProfile()
	if p != nil && p.Kind != state.ProfileKindNodes {
		return fmt.Errorf("完整订阅配置为只读；此功能仅在节点模式可用")
	}
	return nil
}

func (a *App) AddNode(raw string) error {
	if err := a.requireNodeProfile(); err != nil {
		return err
	}
	parsed, err := sub.Parse(raw)
	if err != nil {
		return err
	}
	nodes := sub.CleanAndFilterNodes(parsed.Nodes, "")
	if len(nodes) == 0 {
		return fmt.Errorf("未解析到可用节点")
	}
	old := a.st.Get()
	candidate := state.CloneFile(old)
	for i := range candidate.Profiles {
		if candidate.Profiles[i].ID == candidate.ActiveConfigID {
			candidate.Profiles[i].ManualNodes = append(candidate.Profiles[i].ManualNodes, nodes...)
			state.TouchProfile(&candidate.Profiles[i])
			return a.applyAndCommitCandidate(old, candidate, func(cur *state.File) {
				cur.Profiles[i].ManualNodes = append(cur.Profiles[i].ManualNodes, nodes...)
				cur.Profiles[i].UpdatedAt = candidate.Profiles[i].UpdatedAt
				cur.Profiles[i].Revision = candidate.Profiles[i].Revision
			})
		}
	}
	return fmt.Errorf("活动配置不存在")
}

func (a *App) DisableNode(id string, disabled bool) error {
	if err := a.requireNodeProfile(); err != nil {
		return err
	}
	f := a.st.Get()
	candidate := state.CloneFile(f)
	changed := false
	for i := range candidate.Profiles {
		if candidate.Profiles[i].ID != f.ActiveConfigID {
			continue
		}
		for j := range candidate.Profiles[i].ManualNodes {
			if candidate.Profiles[i].ManualNodes[j].ID == id {
				candidate.Profiles[i].ManualNodes[j].Disabled = disabled
				changed = true
			}
		}
		for source := range candidate.Profiles[i].Sources {
			for j := range candidate.Profiles[i].Sources[source].Nodes {
				if candidate.Profiles[i].Sources[source].Nodes[j].ID == id {
					candidate.Profiles[i].Sources[source].Nodes[j].Disabled = disabled
					changed = true
				}
			}
		}
	}
	if !changed {
		return fmt.Errorf("节点不存在")
	}
	for i := range candidate.Profiles {
		if candidate.Profiles[i].ID == f.ActiveConfigID {
			state.TouchProfile(&candidate.Profiles[i])
			break
		}
	}
	return a.applyAndCommitCandidate(f, candidate, func(cur *state.File) {
		for i := range cur.Profiles {
			if cur.Profiles[i].ID == cur.ActiveConfigID {
				cur.Profiles[i] = candidate.Profiles[i]
				return
			}
		}
	})
}

func profileExists(profiles []state.ConfigProfile, id string) bool {
	for _, p := range profiles {
		if p.ID == id {
			return true
		}
	}
	return false
}
