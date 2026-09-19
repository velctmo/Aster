package app

import (
	"testing"
	"time"

	"aster/internal/clash"
)

func TestEnrichConnectionDiagnostics_DurationMs(t *testing.T) {
	now := time.Date(2026, 9, 19, 12, 0, 10, 500000000, time.UTC)

	// Case 1: RFC3339Nano start time (5.5s ago = 5500ms)
	conn1 := clash.Connection{
		ID:    "c1",
		Start: "2026-09-19T12:00:05.000000000Z",
	}
	EnrichConnectionDiagnostics(&conn1, nil, now)
	if conn1.Diagnostics.DurationMs != 5500 {
		t.Fatalf("expected 5500ms, got %d", conn1.Diagnostics.DurationMs)
	}

	// Case 2: RFC3339 start time (10s ago = 10000ms)
	conn2 := clash.Connection{
		ID:    "c2",
		Start: "2026-09-19T12:00:00Z",
	}
	EnrichConnectionDiagnostics(&conn2, nil, now)
	if conn2.Diagnostics.DurationMs != 10500 {
		t.Fatalf("expected 10500ms, got %d", conn2.Diagnostics.DurationMs)
	}

	// Case 3: Future start time clamped to 0
	conn3 := clash.Connection{
		ID:    "c3",
		Start: "2026-09-19T12:00:20Z",
	}
	EnrichConnectionDiagnostics(&conn3, nil, now)
	if conn3.Diagnostics.DurationMs != 0 {
		t.Fatalf("expected 0ms for future start, got %d", conn3.Diagnostics.DurationMs)
	}

	// Case 4: Invalid start time falling back to history
	oldConn := clash.Connection{
		ID:          "c4",
		Diagnostics: clash.ConnectionDiagnostics{DurationMs: 3200},
	}
	conn4 := clash.Connection{
		ID:    "c4",
		Start: "invalid-time",
	}
	EnrichConnectionDiagnostics(&conn4, &oldConn, now)
	if conn4.Diagnostics.DurationMs != 3200 {
		t.Fatalf("expected 3200ms from history, got %d", conn4.Diagnostics.DurationMs)
	}

	// Case 5: Invalid start time without history defaults to 0
	conn5 := clash.Connection{
		ID:    "c5",
		Start: "",
	}
	EnrichConnectionDiagnostics(&conn5, nil, now)
	if conn5.Diagnostics.DurationMs != 0 {
		t.Fatalf("expected 0ms for empty start without history, got %d", conn5.Diagnostics.DurationMs)
	}
}

func TestEnrichConnectionDiagnostics_Speed(t *testing.T) {
	now := time.Now()

	// Case 1: First snapshot (no previous connection) -> 0
	conn1 := clash.Connection{
		ID:       "c1",
		Download: 5000,
		Upload:   2000,
	}
	EnrichConnectionDiagnostics(&conn1, nil, now)
	if conn1.Diagnostics.SpeedIn != 0 || conn1.Diagnostics.SpeedOut != 0 {
		t.Fatalf("expected 0/0 speed on first snapshot, got %d/%d", conn1.Diagnostics.SpeedIn, conn1.Diagnostics.SpeedOut)
	}

	// Case 2: Smooth speed difference
	oldConn := clash.Connection{
		ID:       "c1",
		Download: 5000,
		Upload:   2000,
	}
	conn2 := clash.Connection{
		ID:       "c1",
		Download: 8500,
		Upload:   3200,
	}
	EnrichConnectionDiagnostics(&conn2, &oldConn, now)
	if conn2.Diagnostics.SpeedIn != 3500 {
		t.Fatalf("expected SpeedIn 3500, got %d", conn2.Diagnostics.SpeedIn)
	}
	if conn2.Diagnostics.SpeedOut != 1200 {
		t.Fatalf("expected SpeedOut 1200, got %d", conn2.Diagnostics.SpeedOut)
	}

	// Case 3: Counter wrap / reset clamped to 0
	conn3 := clash.Connection{
		ID:       "c1",
		Download: 1000,
		Upload:   500,
	}
	EnrichConnectionDiagnostics(&conn3, &oldConn, now)
	if conn3.Diagnostics.SpeedIn != 0 || conn3.Diagnostics.SpeedOut != 0 {
		t.Fatalf("expected 0 clamped speeds, got %d/%d", conn3.Diagnostics.SpeedIn, conn3.Diagnostics.SpeedOut)
	}
}

func TestEnrichConnectionDiagnostics_Rejected(t *testing.T) {
	now := time.Now()

	testCases := []struct {
		name   string
		rule   string
		chains []string
	}{
		{"lowercase reject rule", "reject", []string{"DIRECT"}},
		{"uppercase REJECT rule", "REJECT", []string{"DIRECT"}},
		{"mixed-case Reject rule", "Reject", []string{"DIRECT"}},
		{"chain contains REJECT", "Match", []string{"Proxy", "REJECT"}},
		{"chain contains reject lowercase", "Match", []string{"reject"}},
		{"chain contains REJECT-DROP", "Match", []string{"REJECT-DROP"}},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			conn := clash.Connection{
				ID:     "rej-1",
				Rule:   tc.rule,
				Chains: tc.chains,
			}
			EnrichConnectionDiagnostics(&conn, nil, now)
			if conn.Diagnostics.CloseReason != "rejected" {
				t.Fatalf("expected closeReason rejected, got %s", conn.Diagnostics.CloseReason)
			}
			if !conn.Diagnostics.IsFailed {
				t.Fatalf("expected isFailed true for rejected connection")
			}
		})
	}
}

func TestEnrichConnectionDiagnostics_Active(t *testing.T) {
	now := time.Now()
	conn := clash.Connection{
		ID:     "c-active",
		Rule:   "GEOIP",
		Chains: []string{"Proxy", "Node-A"},
	}
	EnrichConnectionDiagnostics(&conn, nil, now)
	if conn.Diagnostics.CloseReason != "active" {
		t.Fatalf("expected closeReason active, got %s", conn.Diagnostics.CloseReason)
	}
	if conn.Diagnostics.IsFailed {
		t.Fatalf("expected isFailed false for active connection")
	}
}

func TestInferClosedDiagnostics(t *testing.T) {
	// Case 1: Rejected connection maintains rejected & isFailed = true
	rejConn := clash.Connection{
		ID:       "rej",
		Rule:     "REJECT",
		Download: 0,
		Diagnostics: clash.ConnectionDiagnostics{
			DurationMs:  15000,
			CloseReason: "rejected",
			IsFailed:    true,
			SpeedIn:     500,
		},
	}
	rejDiag := InferClosedDiagnostics(rejConn)
	if rejDiag.CloseReason != "rejected" || !rejDiag.IsFailed {
		t.Fatalf("expected rejected & failed=true, got reason=%s failed=%v", rejDiag.CloseReason, rejDiag.IsFailed)
	}
	if rejDiag.SpeedIn != 0 || rejDiag.SpeedOut != 0 {
		t.Fatalf("expected speeds reset to 0, got in=%d out=%d", rejDiag.SpeedIn, rejDiag.SpeedOut)
	}

	// Case 2: Timeout (duration > 10000ms and Download == 0) -> timeout & isFailed = true
	timeoutConn := clash.Connection{
		ID:       "timeout",
		Rule:     "Match",
		Download: 0,
		Upload:   100,
		Diagnostics: clash.ConnectionDiagnostics{
			DurationMs:  10001,
			CloseReason: "active",
			IsFailed:    false,
		},
	}
	toDiag := InferClosedDiagnostics(timeoutConn)
	if toDiag.CloseReason != "timeout" || !toDiag.IsFailed {
		t.Fatalf("expected timeout & failed=true, got reason=%s failed=%v", toDiag.CloseReason, toDiag.IsFailed)
	}

	// Case 3: Short connection (duration <= 10000ms and Download == 0) -> completed & isFailed = false
	shortConn := clash.Connection{
		ID:       "short",
		Rule:     "Match",
		Download: 0,
		Upload:   50,
		Diagnostics: clash.ConnectionDiagnostics{
			DurationMs:  1500,
			CloseReason: "active",
			IsFailed:    false,
		},
	}
	shortDiag := InferClosedDiagnostics(shortConn)
	if shortDiag.CloseReason != "completed" || shortDiag.IsFailed {
		t.Fatalf("expected completed & failed=false for short connection, got reason=%s failed=%v", shortDiag.CloseReason, shortDiag.IsFailed)
	}

	// Case 4: Long connection with data transfer (duration > 10000ms and Download > 0) -> completed & isFailed = false
	longSuccessConn := clash.Connection{
		ID:       "long-success",
		Rule:     "Match",
		Download: 1048576,
		Upload:   50000,
		Diagnostics: clash.ConnectionDiagnostics{
			DurationMs:  25000,
			CloseReason: "active",
			IsFailed:    false,
		},
	}
	lsDiag := InferClosedDiagnostics(longSuccessConn)
	if lsDiag.CloseReason != "completed" || lsDiag.IsFailed {
		t.Fatalf("expected completed & failed=false for long successful connection, got reason=%s failed=%v", lsDiag.CloseReason, lsDiag.IsFailed)
	}
}

func TestDiffConnections_DiagnosticsChange(t *testing.T) {
	previous := map[string]clash.Connection{
		"c1": {
			ID:       "c1",
			Upload:   10,
			Download: 20,
			Rule:     "direct",
			Chains:   []string{"DIRECT"},
			Diagnostics: clash.ConnectionDiagnostics{
				DurationMs:  1000,
				SpeedIn:     100,
				SpeedOut:    50,
				CloseReason: "active",
				IsFailed:    false,
			},
		},
		"c2": {
			ID:       "c2",
			Upload:   5,
			Download: 5,
			Rule:     "direct",
			Chains:   []string{"DIRECT"},
			Diagnostics: clash.ConnectionDiagnostics{
				DurationMs:  2000,
				SpeedIn:     0,
				SpeedOut:    0,
				CloseReason: "active",
				IsFailed:    false,
			},
		},
	}

	// c1 only changes Diagnostics (speed/duration updated)
	// c2 is unchanged
	// c3 is closed (not in current)
	current := map[string]clash.Connection{
		"c1": {
			ID:       "c1",
			Upload:   10,
			Download: 20,
			Rule:     "direct",
			Chains:   []string{"DIRECT"},
			Diagnostics: clash.ConnectionDiagnostics{
				DurationMs:  2000,
				SpeedIn:     200,
				SpeedOut:    50,
				CloseReason: "active",
				IsFailed:    false,
			},
		},
		"c2": {
			ID:       "c2",
			Upload:   5,
			Download: 5,
			Rule:     "direct",
			Chains:   []string{"DIRECT"},
			Diagnostics: clash.ConnectionDiagnostics{
				DurationMs:  2000,
				SpeedIn:     0,
				SpeedOut:    0,
				CloseReason: "active",
				IsFailed:    false,
			},
		},
	}

	delta := diffConnections(previous, current, 100, 200)
	if len(delta.Upserts) != 1 || delta.Upserts[0].ID != "c1" {
		t.Fatalf("expected 1 upsert for c1 due to diagnostics change, got %+v", delta.Upserts)
	}
	if len(delta.Closed) != 0 {
		t.Fatalf("expected 0 closed, got %+v", delta.Closed)
	}

	// Now remove c2 -> enters delta.Closed
	delete(current, "c2")
	delta2 := diffConnections(previous, current, 100, 200)
	if len(delta2.Closed) != 1 || delta2.Closed[0] != "c2" {
		t.Fatalf("expected c2 in closed, got %+v", delta2.Closed)
	}
}
