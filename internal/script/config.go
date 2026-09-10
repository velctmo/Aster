package script

import (
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"github.com/dop251/goja"
	"aster/internal/state"
)

// TransformConfig runs the Aster-native complete-configuration hook. It has
// the same capability-free sandbox and limits as node transforms.
func TransformConfig(source string, config json.RawMessage, profile state.ConfigProfile) (json.RawMessage, error) {
	if source == "" { return append(json.RawMessage(nil), config...), nil }
	if len(source) > maxScriptBytes { return nil, fmt.Errorf("覆写脚本超过 64 KiB 限制") }
	var checkJSON any
	if err := json.Unmarshal(config, &checkJSON); err != nil { return nil, fmt.Errorf("完整配置不是有效 JSON: %w", err) }
	vm := goja.New()
	timer := time.AfterFunc(200*time.Millisecond, func() { vm.Interrupt("覆写脚本执行超时（200ms）") })
	defer timer.Stop()
	if _, err := vm.RunString(`"use strict";` + source); err != nil { return nil, fmt.Errorf("覆写脚本错误: %w", err) }
	fn, ok := goja.AssertFunction(vm.Get("transformConfig"))
	if !ok {
		fn, ok = goja.AssertFunction(vm.Get("main"))
	}
	if !ok {
		return nil, fmt.Errorf("配置覆写脚本必须定义 main(config) 或 transformConfig(config, profile) 函数")
	}
	input, err := vm.RunString("JSON.parse(" + strconv.Quote(string(config)) + ")")
	if err != nil { return nil, fmt.Errorf("完整配置不是有效 JSON: %w", err) }
	result, err := fn(goja.Undefined(), input, vm.ToValue(map[string]any{"id": profile.ID, "name": profile.Name, "kind": profile.Kind}))
	if err != nil { return nil, fmt.Errorf("覆写脚本错误: %w", err) }
	b, err := json.Marshal(result.Export())
	if err != nil { return nil, fmt.Errorf("覆写结果不可序列化: %w", err) }
	if len(b) > 8<<20 { return nil, fmt.Errorf("覆写结果超过 8 MiB 限制") }
	var check struct { Outbounds []json.RawMessage `json:"outbounds"` }
	if err := json.Unmarshal(b, &check); err != nil || check.Outbounds == nil { return nil, fmt.Errorf("覆写结果必须是含 outbounds 数组的 sing-box 配置") }
	return b, nil
}
