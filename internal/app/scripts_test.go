package app

import (
	"testing"

	"aster/internal/state"
)

func TestScriptsCRUDAndBinding(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Store().Update(func(f *state.File) error {
		f.Wanted = false
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	// 1. 创建脚本
	item, err := a.CreateScript("测试覆写脚本", "config", "function main(config) { return config; }")
	if err != nil {
		t.Fatalf("CreateScript 失败: %v", err)
	}
	if item.ID == "" || item.Name != "测试覆写脚本" {
		t.Fatalf("返回的 item 不符合预期: %+v", item)
	}

	// 2. 查询脚本列表
	scripts := a.Scripts()
	found := false
	for _, s := range scripts {
		if s.ID == item.ID {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("列表中未找到新建的脚本")
	}

	// 3. 更新脚本
	err = a.UpdateScript(item.ID, "新名称", "function main(config) { config.outbounds = config.outbounds || []; return config; }")
	if err != nil {
		t.Fatalf("UpdateScript 失败: %v", err)
	}
	updatedFound := false
	for _, s := range a.Scripts() {
		if s.ID == item.ID && s.Name == "新名称" {
			updatedFound = true
			break
		}
	}
	if !updatedFound {
		t.Fatalf("脚本更新未生效")
	}

	// 4. 绑定脚本到配置
	profiles := a.Profiles()
	if len(profiles) > 0 {
		targetProfile := profiles[0]
		err = a.BindProfileScript(targetProfile.ID, item.ID)
		if err != nil {
			t.Fatalf("BindProfileScript 失败: %v", err)
		}
		for _, p := range a.Profiles() {
			if p.ID == targetProfile.ID {
				if p.ScriptID != item.ID {
					t.Fatalf("绑定的 scriptId 不匹配: %s vs %s", p.ScriptID, item.ID)
				}
				break
			}
		}

		// 5. 解绑脚本
		err = a.BindProfileScript(targetProfile.ID, "")
		if err != nil {
			t.Fatalf("解绑脚本失败: %v", err)
		}
		for _, p := range a.Profiles() {
			if p.ID == targetProfile.ID {
				if p.ScriptID != "" {
					t.Fatalf("解绑未生效，仍有 scriptId: %s", p.ScriptID)
				}
				break
			}
		}
	}

	// 6. 删除脚本
	err = a.DeleteScript(item.ID)
	if err != nil {
		t.Fatalf("DeleteScript 失败: %v", err)
	}
	for _, s := range a.Scripts() {
		if s.ID == item.ID {
			t.Fatalf("脚本删除未生效，仍存在于列表中")
		}
	}
}
