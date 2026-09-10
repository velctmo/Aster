package app

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"aster/internal/core"
	"aster/internal/render"
	"aster/internal/state"
)

func (a *App) Scripts() []state.ScriptItem {
	f := a.st.Get()
	if len(f.Scripts) == 0 {
		return []state.ScriptItem{}
	}
	out := make([]state.ScriptItem, len(f.Scripts))
	copy(out, f.Scripts)
	return out
}

func (a *App) CreateScript(name, kind, content string) (state.ScriptItem, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return state.ScriptItem{}, fmt.Errorf("脚本名称不能为空")
	}
	if kind == "" {
		kind = "config"
	}
	item := state.ScriptItem{
		ID:        state.NewID(),
		Name:      name,
		Kind:      kind,
		Content:   content,
		UpdatedAt: time.Now().Unix(),
	}
	_, err := a.st.Update(func(f *state.File) error {
		f.Scripts = append(f.Scripts, item)
		return nil
	})
	if err != nil {
		return state.ScriptItem{}, err
	}
	return item, nil
}

func (a *App) UpdateScript(id, name, content string) error {
	f := a.st.Get()
	candidate := state.CloneFile(f)
	var targetScript *state.ScriptItem
	for i := range candidate.Scripts {
		if candidate.Scripts[i].ID == id {
			targetScript = &candidate.Scripts[i]
			break
		}
	}
	if targetScript == nil {
		return fmt.Errorf("脚本不存在")
	}
	if name = strings.TrimSpace(name); name != "" {
		targetScript.Name = name
	}
	targetScript.Content = content
	targetScript.UpdatedAt = time.Now().Unix()

	// 检查是否有活动的配置正在引用此脚本，如果是，必须先预检候选配置
	activeProfile := candidate.ActiveProfile()
	if activeProfile != nil && activeProfile.ScriptID == id && f.Wanted {
		configBytes, err := render.Config(candidate, a.st.Dir())
		if err != nil {
			return fmt.Errorf("脚本覆写渲染错误: %w", err)
		}
		bin, err := core.BinaryFor(candidate)
		if err != nil {
			return err
		}
		path := filepath.Join(a.st.Dir(), "config.candidate.json")
		if err := os.WriteFile(path, configBytes, 0o600); err != nil {
			return err
		}
		defer os.Remove(path)
		if err := core.ValidateConfig(bin, path); err != nil {
			return fmt.Errorf("内核校验失败: %w", err)
		}
		if err := a.apply(candidate, true); err != nil {
			_ = a.apply(f, true)
			return fmt.Errorf("应用新配置失败: %w", err)
		}
	}

	_, err := a.st.Update(func(file *state.File) error {
		for i := range file.Scripts {
			if file.Scripts[i].ID == id {
				if name != "" {
					file.Scripts[i].Name = name
				}
				file.Scripts[i].Content = content
				file.Scripts[i].UpdatedAt = time.Now().Unix()
				return nil
			}
		}
		return fmt.Errorf("脚本未找到")
	})
	return err
}

func (a *App) DeleteScript(id string) error {
	f := a.st.Get()
	candidate := state.CloneFile(f)
	found := false
	newScripts := make([]state.ScriptItem, 0, len(candidate.Scripts))
	for _, s := range candidate.Scripts {
		if s.ID == id {
			found = true
			continue
		}
		newScripts = append(newScripts, s)
	}
	if !found {
		return fmt.Errorf("脚本不存在")
	}
	candidate.Scripts = newScripts

	// 如果有 profile 引用了被删脚本，清空引用的 scriptId
	needsReload := false
	for i := range candidate.Profiles {
		if candidate.Profiles[i].ScriptID == id {
			candidate.Profiles[i].ScriptID = ""
			state.TouchProfile(&candidate.Profiles[i])
			if candidate.Profiles[i].ID == candidate.ActiveConfigID {
				needsReload = true
			}
		}
	}

	if needsReload && f.Wanted {
		if err := a.apply(candidate, true); err != nil {
			_ = a.apply(f, true)
			return fmt.Errorf("重载配置失败: %w", err)
		}
	}

	_, err := a.st.Update(func(file *state.File) error {
		file.Scripts = newScripts
		for i := range file.Profiles {
			if file.Profiles[i].ScriptID == id {
				file.Profiles[i].ScriptID = ""
				state.TouchProfile(&file.Profiles[i])
			}
		}
		return nil
	})
	return err
}

func (a *App) BindProfileScript(profileID, scriptID string) error {
	f := a.st.Get()
	candidate := state.CloneFile(f)
	var targetProfile *state.ConfigProfile
	for i := range candidate.Profiles {
		if candidate.Profiles[i].ID == profileID {
			targetProfile = &candidate.Profiles[i]
			break
		}
	}
	if targetProfile == nil {
		return fmt.Errorf("配置不存在")
	}

	// 校验 scriptID 是否合法（空代表解绑）
	if scriptID != "" {
		scriptFound := false
		for _, s := range candidate.Scripts {
			if s.ID == scriptID {
				scriptFound = true
				break
			}
		}
		if !scriptFound {
			return fmt.Errorf("指定的脚本不存在")
		}
	}

	targetProfile.ScriptID = scriptID
	state.TouchProfile(targetProfile)

	// 如果该配置处于激活中，执行候选配置校验与平滑热重载
	if profileID == candidate.ActiveConfigID && f.Wanted {
		configBytes, err := render.Config(candidate, a.st.Dir())
		if err != nil {
			return fmt.Errorf("配置渲染失败: %w", err)
		}
		bin, err := core.BinaryFor(candidate)
		if err != nil {
			return err
		}
		path := filepath.Join(a.st.Dir(), "config.candidate.json")
		if err := os.WriteFile(path, configBytes, 0o600); err != nil {
			return err
		}
		defer os.Remove(path)
		if err := core.ValidateConfig(bin, path); err != nil {
			return fmt.Errorf("配置语法校验失败: %w", err)
		}
		if err := a.apply(candidate, true); err != nil {
			_ = a.apply(f, true)
			return fmt.Errorf("应用配置失败: %w", err)
		}
	}

	_, err := a.st.Update(func(file *state.File) error {
		for i := range file.Profiles {
			if file.Profiles[i].ID == profileID {
				file.Profiles[i].ScriptID = scriptID
				state.TouchProfile(&file.Profiles[i])
				return nil
			}
		}
		return fmt.Errorf("配置不存在")
	})
	return err
}
