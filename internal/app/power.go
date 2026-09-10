package app

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"aster/internal/core"
	"aster/internal/macos"
	"aster/internal/render"
	"aster/internal/state"
)

func (a *App) SetPower(on bool) error {
	a.mutationMu.Lock()
	defer a.mutationMu.Unlock()
	if on {
		return a.startSessionLocked()
	}
	old := a.st.Get()
	// Wanted is persisted intent, not proof that a process survived a previous
	// daemon/UI restart.  A true value with no live core must still apply the
	// configuration and start the process.
	if old.Wanted == on && (!on || a.core.Running()) {
		return nil
	}
	candidate := state.CloneFile(old)
	candidate.Wanted = on
	if !on {
		_ = a.clash.CloseAll()
	}
	if err := a.apply(candidate, true); err != nil {
		if restoreErr := a.apply(old, true); restoreErr != nil {
			return fmt.Errorf("切换核心电源失败: %v；恢复旧核心失败: %w", err, restoreErr)
		}
		return fmt.Errorf("切换核心电源失败，已保留原状态: %w", err)
	}
	if _, err := a.st.Update(func(cur *state.File) error { cur.Wanted = on; return nil }); err != nil {
		if restoreErr := a.apply(old, true); restoreErr != nil {
			return fmt.Errorf("保存核心电源状态失败: %v；恢复旧核心失败: %w", err, restoreErr)
		}
		return fmt.Errorf("保存核心电源状态失败: %w", err)
	}
	return nil
}

// StartSession starts the current profile whenever the daemon owns a user
// session. It intentionally does not treat the legacy Wanted flag as a user
// facing on/off switch.
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
		return fmt.Errorf("请先下载或导入内核: %w", err)
	}
	candidate := state.CloneFile(old)
	candidate.Wanted = true
	if err := a.apply(candidate, true); err != nil {
		// apply(candidate) has already recorded the actionable error. Do not
		// call apply(old): doing so resets lastErr and turns an auto-start
		// failure into an unexplained stopped state.
		_ = a.core.Stop()
		_ = a.writeConfig(old)
		_ = macos.SetProxy(false, proxyHost(old), proxyPort(old), nil)
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
	candidate := state.CloneFile(current)
	candidate.Capture = c
	_ = a.clash.CloseAll()
	return a.applyAndCommitCandidate(current, candidate, func(cur *state.File) { cur.Capture = c })
}

// setFullProfileSystemProxy changes only the macOS proxy setting. The imported
// configuration is intentionally not rendered or restarted for this operation.
// Persist only after the system change succeeds, and put the old system setting
// back if persistence fails.
func (a *App) setFullProfileSystemProxy(old state.File, capture state.Capture) error {
	if old.Wanted && !a.core.Running() {
		if detail := a.core.LastError(); detail != "" {
			return fmt.Errorf("完整配置核心未运行: %s", detail)
		}
		return fmt.Errorf("完整配置核心未运行")
	}
	applyProxy := func(f state.File, enabled bool) error {
		if f.Wanted && enabled {
			return macos.SetProxy(true, proxyHost(f), proxyPort(f), f.Settings.ProxyBypass)
		}
		return macos.SetProxy(false, proxyHost(f), proxyPort(f), nil)
	}
	if err := applyProxy(old, capture.SystemProxy); err != nil {
		return err
	}
	if _, err := a.st.Update(func(cur *state.File) error {
		cur.Capture.SystemProxy = capture.SystemProxy
		return nil
	}); err != nil {
		_ = applyProxy(old, old.Capture.SystemProxy)
		return fmt.Errorf("保存系统代理状态失败，已恢复原设置: %w", err)
	}
	return nil
}

func (a *App) ToggleSystemProxy() error {
	f := a.st.Get()
	return a.SetCapture(state.Capture{
		SystemProxy: !f.Capture.SystemProxy,
		Tun:         f.Capture.Tun,
	})
}

func (a *App) ToggleTun() error {
	f := a.st.Get()
	return a.SetCapture(state.Capture{
		SystemProxy: f.Capture.SystemProxy,
		Tun:         !f.Capture.Tun,
	})
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
		_ = a.clash.CloseAll()
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
			cur.RecentNodes = prepend(cur.RecentNodes, realTag, 8)
			return nil
		}); err != nil {
			_ = a.clash.Select("proxy", old.Selected)
			return err
		}
		_ = a.clash.CloseAll()
		a.hub.Broadcast("status", a.Status())
		return nil
	}
	candidate := state.CloneFile(old)
	candidate.Selected = realTag
	candidate.RecentNodes = prepend(candidate.RecentNodes, realTag, 8)
	return a.applyAndCommitCandidate(old, candidate, func(cur *state.File) {
		cur.Selected = realTag
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
