package render

import (
	"encoding/json"
	"fmt"
	"testing"

	"aster/internal/state"
)

func BenchmarkRender500Nodes(b *testing.B) {
	f := state.DefaultFile()
	for i := 0; i < 500; i++ {
		f.Profiles[0].ManualNodes = append(f.Profiles[0].ManualNodes, state.Node{
			ID: fmt.Sprintf("node-%d", i), Name: fmt.Sprintf("node-%d", i), Protocol: "shadowsocks",
			Outbound: json.RawMessage(`{"type":"shadowsocks","server":"127.0.0.1","server_port":443,"method":"aes-128-gcm","password":"test"}`),
		})
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Config(f, "/tmp/aster-benchmark"); err != nil {
			b.Fatal(err)
		}
	}
}
