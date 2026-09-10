package app

import (
	"fmt"
	"testing"
)

func TestFailureCategory(t *testing.T) {
	for _, tc := range []struct {
		message string
		want    string
	}{
		{"需要管理员权限", "authorization"},
		{"端口被占用", "port_conflict"},
		{"内核配置校验失败", "validation"},
		{"核心启动后未通过健康检查", "health"},
		{"进程意外退出", "runtime"},
	} {
		if got := failureCategory(fmt.Errorf("%s", tc.message)); got != tc.want {
			t.Fatalf("failureCategory(%q)=%q, want %q", tc.message, got, tc.want)
		}
	}
}
