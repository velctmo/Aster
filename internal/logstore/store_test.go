package logstore

import (
	"fmt"
	"path/filepath"
	"testing"

	"aster/internal/clash"
)

func TestSnapshotWritesActiveConnectionOnlyOnceWithinThrottleWindow(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "logs.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	snap := &clash.Connections{Connections: []clash.Connection{{ID: "one", Metadata: clash.Metadata{Host: "example.com"}}}}
	if events := s.UpsertSnapshot(snap, map[string]bool{}); len(events) != 1 {
		t.Fatalf("first events=%d", len(events))
	}
	if events := s.UpsertSnapshot(snap, map[string]bool{"one": true}); len(events) != 0 {
		t.Fatalf("unchanged events=%d", len(events))
	}
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM requests`).Scan(new(int)); err != nil {
		t.Fatal(err)
	}
	if events := s.UpsertSnapshot(&clash.Connections{}, map[string]bool{"one": true}); len(events) != 0 {
		t.Fatalf("close events=%d", len(events))
	}
	var closed int
	if err := s.db.QueryRow(`SELECT closed FROM requests WHERE id='one'`).Scan(&closed); err != nil {
		t.Fatal(err)
	}
	if closed != 1 {
		t.Fatalf("closed=%d", closed)
	}
}

// BenchmarkUpsertSnapshot100ActiveThrottled represents the steady-state
// 100-connection polling path. The first call persists connection starts;
// subsequent one-second snapshots must remain in memory until the write
// throttle expires rather than issuing 100 SQLite upserts per second.
func BenchmarkUpsertSnapshot100ActiveThrottled(b *testing.B) {
	s, err := Open(filepath.Join(b.TempDir(), "logs.db"))
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = s.Close() })
	connections := make([]clash.Connection, 0, 100)
	previous := make(map[string]bool, 100)
	for i := 0; i < 100; i++ {
		id := fmt.Sprintf("connection-%d", i)
		connections = append(connections, clash.Connection{ID: id, Upload: int64(i), Download: int64(i), Metadata: clash.Metadata{Host: "example.test"}})
		previous[id] = true
	}
	snap := &clash.Connections{Connections: connections}
	_ = s.UpsertSnapshot(snap, map[string]bool{})
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = s.UpsertSnapshot(snap, previous)
	}
}
