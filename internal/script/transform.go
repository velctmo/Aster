// Package script runs user node transforms in a deliberately capability-free
// JavaScript runtime. It exposes data only: no require(), network, filesystem,
// environment, or Go host functions are registered.
package script

import (
	"encoding/json"
	"fmt"
	"reflect"
	"time"

	"github.com/dop251/goja"

	"aster/internal/state"
)

const maxScriptBytes = 64 << 10

// Transform evaluates the native transformNodes(nodes, profile) hook. The
// legacy transform(nodes, profile) name remains accepted for stored scripts.
func Transform(source string, nodes []state.Node, profile state.ConfigProfile) ([]state.Node, error) {
	if source == "" {
		return nodes, nil
	}
	if len(source) > maxScriptBytes {
		return nil, fmt.Errorf("覆写脚本超过 64 KiB 限制")
	}
	vm := goja.New()
	timer := time.AfterFunc(200*time.Millisecond, func() { vm.Interrupt("覆写脚本执行超时（200ms）") })
	defer timer.Stop()
	if _, err := vm.RunString(`"use strict";` + source); err != nil {
		return nil, fmt.Errorf("覆写脚本错误: %w", err)
	}
	fn, ok := goja.AssertFunction(vm.Get("transformNodes"))
	if !ok {
		fn, ok = goja.AssertFunction(vm.Get("transform"))
	}
	if !ok {
		return nil, fmt.Errorf("覆写脚本必须定义 transformNodes(nodes, profile) 函数")
	}
	input, _ := json.Marshal(nodes)
	var jsNodes any
	if err := json.Unmarshal(input, &jsNodes); err != nil {
		return nil, err
	}
	result, err := fn(goja.Undefined(), vm.ToValue(jsNodes), vm.ToValue(map[string]any{"id": profile.ID, "name": profile.Name, "kind": profile.Kind}))
	if err != nil {
		return nil, fmt.Errorf("覆写脚本错误: %w", err)
	}
	exported := result.Export()
	b, err := json.Marshal(exported)
	if err != nil {
		return nil, fmt.Errorf("覆写结果不可序列化: %w", err)
	}
	var out []state.Node
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, fmt.Errorf("覆写结果必须是节点数组: %w", err)
	}
	if len(out) > 5000 {
		return nil, fmt.Errorf("覆写结果超过 5000 个节点限制")
	}
	seenIDs := make(map[string]struct{}, len(out))
	originalOutbounds := make(map[string]json.RawMessage, len(nodes))
	for _, node := range nodes {
		originalOutbounds[node.ID] = node.Outbound
	}
	for i := range out {
		if out[i].ID == "" || out[i].Name == "" || len(out[i].Outbound) == 0 {
			return nil, fmt.Errorf("覆写结果第 %d 项缺少 id、name 或 outbound", i+1)
		}
		if _, exists := seenIDs[out[i].ID]; exists {
			return nil, fmt.Errorf("覆写结果包含重复节点 id: %s", out[i].ID)
		}
		original, exists := originalOutbounds[out[i].ID]
		if !exists {
			return nil, fmt.Errorf("覆写结果引用了未知节点 id: %s", out[i].ID)
		}
		if !sameJSON(out[i].Outbound, original) {
			return nil, fmt.Errorf("覆写不能修改既有节点的出站内容: %s", out[i].ID)
		}
		seenIDs[out[i].ID] = struct{}{}
	}
	return out, nil
}

func sameJSON(a, b json.RawMessage) bool {
	var left, right any
	if json.Unmarshal(a, &left) != nil || json.Unmarshal(b, &right) != nil {
		return false
	}
	return reflect.DeepEqual(left, right)
}
