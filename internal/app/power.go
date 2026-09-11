package app

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"aster/internal/core"
	"aster/internal/helper"
	"aster/internal/macos"
	"aster/internal/render"
	"aster/internal/state"
)

func (a *App) StartSession() error {
	a.mutationMu.Lock()
	defer a.mutationMu.Unlock()
	return a.startSessionLocked()
}

func (a *App) startSessionLocked() error {
	old := a.st.Get()
	if old.Wanted && a.core.Running() {
		return nil
	}
	if _, err := core.BinaryFor(old); err != nil {
		a.setErr(err, 0)
		return fmt.Errorf("未找到 sing-box 内核: %w", err)
	}
	candidate := state.CloneFile(old)
	candidate.Wanted = true
	if err := a.apply(candidate, true); err != nil {
		if !a.core.Running() {
			_ = a.core.Stop()
			_ = a.writeConfig(old)
		}
		_ = a.disableSystemProxy(old)
		return fmt.Errorf("自动启动核心失败: %w", err)
	}
	if _, err := a.st.Update(func(cur *state.File) error { cur.Wanted = true; return nil }); err != nil {
		_ = a.core.Stop()
		a.setErr(err, 0)
		return fmt.Errorf("保存核心会话状态失败: %w", err)
	}
	return nil
}

func (a *App) SetCapture(c state.Capture) error {
	a.mutationMu.Lock()
	defer a.mutationMu.Unlock()
	current := a.st.Get()
	if p := current.ActiveProfile(); p != nil && p.Kind == state.ProfileKindSubscription {
		if c.Tun != current.Capture.Tun {
			return fmt.Errorf("完整订阅的 TUN 由配置自行管理，Aster 不改写其状态")
		}
		if c.SystemProxy && !render.SupportsSystemProxy(current) {
			return fmt.Errorf("当前完整配置没有监听在 loopback 的 mixed 入站，无法启用系统代理")
		}
		return a.setFullProfileSystemProxy(current, c)
	}
	if c.SystemProxy && !render.SupportsSystemProxy(current) {
		return fmt.Errorf("当前完整配置没有 mixed 入站，无法启用系统代理")
	}
	if c.Tun && !render.SupportsTun(current) {
		return fmt.Errorf("当前完整配置没有 tun 入站，无法启用 TUN")
	}
	if c.Tun && !helper.NewClient().Installed() {
		return fmt.Errorf("请安装 Aster 网络组件（Aster.pkg）")
	}
	proxyChanged := c.SystemProxy != current.Capture.SystemProxy
	tunChanged := c.Tun != current.Capture.Tun
	if proxyChanged && !tunChanged {
		return a.setFullProfileSystemProxy(current, c)
	}
	candidate := state.CloneFile(current)
	candidate.Capture = c
	return a.applyAndCommitCandidateWithRestart(current, candidate, tunChanged, func(cur *state.File) { cur.Capture = c })
}

func (a *App) clearStartupLeftover() {
	f := a.st.Get()
	host, port := proxyHost(f), proxyPort(f)
	if owner, ok := macos.ReadOwnership(a.st.Dir()); ok {
		if owner.Host != host || owner.Port != port {
			_ = macos.ClearLeftover(owner.Host, owner.Port)
			macos.ClearOwnership(a.st.Dir())
		}
	}
	if !f.Capture.SystemProxy {
		_ = macos.ClearLeftover(host, port)
		macos.ClearOwnership(a.st.Dir())
	}
}

func (a *App) enableSystemProxy(f state.File) error {
	host, port := proxyHost(f), proxyPort(f)
	if err := macos.SetProxy(true, host, port, f.Settings.ProxyBypass); err != nil {
		return err
	}
	_ = macos.WriteOwnership(a.st.Dir(), host, port, os.Getpid())
	return nil
}

func (a *App) disableSystemProxy(f state.File) error {
	host, port := proxyHost(f), proxyPort(f)
	err := macos.SetProxy(false, host, port, nil)
	_ = macos.ClearLeftover(host, port)
	macos.ClearOwnership(a.st.Dir())
	return err
}

// setFullProfileSystemProxy changes only the macOS proxy setting. The imported
// configuration is intentionally not rendered or restarted for this operation.
// Persist only after the system change succeeds, and put the old system setting
// back if persistence fails.
func (a *App) setFullProfileSystemProxy(old state.File, capture state.Capture) error {
	if capture.SystemProxy && !a.core.Running() {
		if detail := a.core.LastError(); detail != "" {
			return fmt.Errorf("核心未运行，无法启用系统代理: %s", detail)
		}
		return fmt.Errorf("核心未运行，无法启用系统代理")
	}
	applyProxy := func(enabled bool) error {
		if enabled {
			return a.enableSystemProxy(old)
		}
		return a.disableSystemProxy(old)
	}
	if err := applyProxy(capture.SystemProxy); err != nil {
		return err
	}
	if _, err := a.st.Update(func(cur *state.File) error {
		cur.Capture.SystemProxy = capture.SystemProxy
		return nil
	}); err != nil {
		_ = applyProxy(old.Capture.SystemProxy)
		return fmt.Errorf("保存系统代理状态失败，已恢复原设置: %w", err)
	}
	a.hub.Broadcast("status", a.Status())
	return nil
}

func (a *App) SetMode(mode string) error {
	if err := a.requireNodeProfile(); err != nil {
		return err
	}
	if mode != "rule" && mode != "global" && mode != "direct" {
		return fmt.Errorf("未知分流模式: %s", mode)
	}
	old := a.st.Get()
	if old.Mode == mode {
		return nil
	}
	if a.core.Running() {
		if err := a.clash.PatchMode(clashMode(mode)); err != nil {
			return err
		}
		if _, err := a.st.Update(func(cur *state.File) error { cur.Mode = mode; return nil }); err != nil {
			_ = a.clash.PatchMode(clashMode(old.Mode))
			return err
		}
		a.hub.Broadcast("status", a.Status())
		return nil
	}
	candidate := state.CloneFile(old)
	candidate.Mode = mode
	if err := a.applyAndCommitCandidate(old, candidate, func(cur *state.File) { cur.Mode = mode }); err != nil {
		return err
	}
	return nil
}

func (a *App) SelectNode(tag string) error {
	if err := a.requireNodeProfile(); err != nil {
		return err
	}
	realTag := tag
	found := false
	nodes := a.Nodes()
	for _, n := range nodes {
		if n.Tag == tag {
			realTag = n.Tag
			found = true
			break
		}
	}
	if !found {
		for _, n := range nodes {
			if n.ID == tag || n.Name == tag || strings.HasSuffix(n.Tag, tag) || strings.HasSuffix(tag, n.Name) {
				realTag = n.Tag
				found = true
				break
			}
		}
	}
	if !found {
		return fmt.Errorf("节点不存在: %s", tag)
	}
	old := a.st.Get()
	if old.Selected == realTag {
		return nil
	}
	if a.core.Running() {
		if err := a.clash.Select("proxy", realTag); err != nil {
			return err
		}
		if _, err := a.st.Update(func(cur *state.File) error {
			cur.Selected = realTag
			if cur.SelectorNow == nil {
				cur.SelectorNow = map[string]string{}
			}
			cur.SelectorNow["proxy"] = realTag
			cur.RecentNodes = prepend(cur.RecentNodes, realTag, 8)
			return nil
		}); err != nil {
			_ = a.clash.Select("proxy", old.Selected)
			return err
		}
		a.hub.Broadcast("status", a.Status())
		return nil
	}
	candidate := state.CloneFile(old)
	candidate.Selected = realTag
	if candidate.SelectorNow == nil {
		candidate.SelectorNow = map[string]string{}
	}
	candidate.SelectorNow["proxy"] = realTag
	candidate.RecentNodes = prepend(candidate.RecentNodes, realTag, 8)
	return a.applyAndCommitCandidate(old, candidate, func(cur *state.File) {
		cur.Selected = realTag
		if cur.SelectorNow == nil {
			cur.SelectorNow = map[string]string{}
		}
		cur.SelectorNow["proxy"] = realTag
		cur.RecentNodes = prepend(cur.RecentNodes, realTag, 8)
	})
}

// applyAndCommitCandidate is the offline mutation transaction used by mode
// and node selection. It validates before replacing a core, then persists only
// after the candidate is running; any failure restores the last running file.
func (a *App) applyAndCommitCandidate(old, candidate state.File, commit func(*state.File)) error {
	return a.applyAndCommitCandidateWithRestart(old, candidate, false, commit)
}

func (a *App) applyAndCommitCandidateWithRestart(old, candidate state.File, restart bool, commit func(*state.File)) error {
	if candidate.Wanted {
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
		if err := a.apply(candidate, restart); err != nil {
			if restoreErr := a.apply(old, true); restoreErr != nil {
				return fmt.Errorf("应用候选配置失败: %v；恢复旧核心失败: %w", err, restoreErr)
			}
			return fmt.Errorf("应用候选配置失败，已恢复旧核心: %w", err)
		}
	} else if err := a.apply(candidate, true); err != nil {
		return err
	}
	if _, err := a.st.Update(func(cur *state.File) error { commit(cur); return nil }); err != nil {
		if old.Wanted {
			if restoreErr := a.apply(old, true); restoreErr != nil {
				return fmt.Errorf("保存候选配置失败: %v；恢复旧核心失败: %w", err, restoreErr)
			}
		} else {
			_ = a.writeConfig(old)
		}
		return fmt.Errorf("保存候选配置失败: %w", err)
	}
	return nil
}

func (a *App) Restart() error {
	a.mutationMu.Lock()
	defer a.mutationMu.Unlock()
	if !a.st.Get().Wanted {
		return a.startSessionLocked()
	}
	_ = a.clash.CloseAll()
	return a.apply(a.st.Get(), true)
}

func prepend(list []string, v string, n int) []string {
	out := []string{v}
	for _, x := range list {
		if x != v {
			out = append(out, x)
		}
		if len(out) >= n {
			break
		}
	}
	return out
}
