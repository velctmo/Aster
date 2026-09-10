package app

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/gorilla/websocket"

	"aster/internal/clash"
)

func TestHubEventHasOrderedEnvelope(t *testing.T) {
	h := NewHub()
	first := h.Event("traffic", map[string]int64{"up": 1})
	second := h.Event("connections", map[string]any{"connections": []any{}})
	if first.Sequence == 0 || second.Sequence <= first.Sequence || first.Timestamp == 0 {
		t.Fatalf("events are not ordered: %+v %+v", first, second)
	}
	var payload map[string]int64
	if err := json.Unmarshal(first.Data, &payload); err != nil || payload["up"] != 1 {
		t.Fatalf("unexpected event payload: %v %v", payload, err)
	}
}

func TestClientAcceptsOnlyItsRealtimeContract(t *testing.T) {
	for _, tc := range []struct {
		client, event string
		want          bool
	}{
		{"log", "log", true}, {"log", "traffic", false},
		{"connections", "connections", true}, {"connections", "status", false},
		{"traffic", "traffic", true}, {"traffic", "node_delay", true},
		{"traffic", "node_speed", true}, {"traffic", "nodes", true},
		{"process_traffic", "connections", false},
	} {
		if got := clientAccepts(tc.client, tc.event); got != tc.want {
			t.Fatalf("clientAccepts(%q, %q) = %v, want %v", tc.client, tc.event, got, tc.want)
		}
	}
}

func TestClientEventQueueHasBoundedReconnectThreshold(t *testing.T) {
	h := NewHub()
	if realtimeQueueCapacity != 256 {
		t.Fatalf("unexpected realtime queue capacity: %d", realtimeQueueCapacity)
	}
	if h.Sequence() != 0 {
		t.Fatal("new hub should have no events")
	}
}

func TestHubReportsOnlyCompatibleSubscribers(t *testing.T) {
	h := NewHub()
	if h.HasSubscribers("traffic") {
		t.Fatal("new hub unexpectedly has subscribers")
	}
	h.conns[&websocket.Conn{}] = &client{kind: "traffic", ch: make(chan []byte, 1)}
	if !h.HasSubscribers("traffic") || !h.HasSubscribers("node_delay") || h.HasSubscribers("connections") {
		t.Fatal("subscriber routing is incorrect")
	}
}

func TestDiffConnectionsEmitsOnlyChangesAndClosures(t *testing.T) {
	previous := map[string]clash.Connection{
		"same": {ID: "same", Upload: 1, Download: 2},
		"gone": {ID: "gone"},
	}
	current := map[string]clash.Connection{
		"same":    {ID: "same", Upload: 1, Download: 2},
		"changed": {ID: "changed", Upload: 3},
	}
	delta := diffConnections(previous, current, 12, 34)
	if len(delta.Upserts) != 1 || delta.Upserts[0].ID != "changed" {
		t.Fatalf("upserts=%+v", delta.Upserts)
	}
	if len(delta.Closed) != 1 || delta.Closed[0] != "gone" {
		t.Fatalf("closed=%+v", delta.Closed)
	}
	if delta.UploadTotal != 12 || delta.DownloadTotal != 34 {
		t.Fatalf("totals=%+v", delta)
	}
}

func TestDiffConnections100ActiveUnchangedProducesNoUpserts(t *testing.T) {
	previous := connectionFixture(100)
	current := connectionFixture(100)
	delta := diffConnections(previous, current, 1024, 2048)
	if len(delta.Upserts) != 0 || len(delta.Closed) != 0 {
		t.Fatalf("unchanged snapshot must be empty: %+v", delta)
	}
}

func BenchmarkDiffConnections100Active(b *testing.B) {
	previous := connectionFixture(100)
	current := connectionFixture(100)
	current["conn-42"] = clash.Connection{ID: "conn-42", Upload: 43, Download: 42}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = diffConnections(previous, current, int64(i), int64(i))
	}
}

func connectionFixture(count int) map[string]clash.Connection {
	connections := make(map[string]clash.Connection, count)
	for i := 0; i < count; i++ {
		id := fmt.Sprintf("conn-%d", i)
		connections[id] = clash.Connection{ID: id, Upload: int64(i), Download: int64(i)}
	}
	return connections
}
