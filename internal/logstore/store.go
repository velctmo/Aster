package logstore

import (
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"

	"aster/internal/clash"
	"aster/internal/state"
)

type Row struct {
	ID       string `json:"id"`
	SeenAt   int64  `json:"seenAt"`
	Host     string `json:"host"`
	Process  string `json:"process"`
	Rule     string `json:"rule"`
	Outbound string `json:"outbound"`
	Upload   int64  `json:"upload"`
	Download int64  `json:"download"`
	Closed   bool   `json:"closed"`
	Kind     string `json:"kind"`
}

type Store struct {
	db          *sql.DB
	mu          sync.Mutex
	lastWritten map[string]time.Time
}

func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=auto_vacuum(INCREMENTAL)")
	if err != nil {
		return nil, err
	}
	s := &Store{db: db, lastWritten: map[string]time.Time{}}
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS requests (
		id TEXT PRIMARY KEY,
		seen_at INTEGER NOT NULL,
		host TEXT,
		process TEXT,
		rule TEXT,
		outbound TEXT,
		upload INTEGER,
		download INTEGER,
		closed INTEGER,
		kind TEXT
	);
	CREATE INDEX IF NOT EXISTS idx_requests_seen ON requests(seen_at);
	CREATE INDEX IF NOT EXISTS idx_requests_kind_seen ON requests(kind, seen_at);`); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) UpsertSnapshot(snap *clash.Connections, prevIDs map[string]bool) []Row {
	if snap == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	nowTime := time.Now()
	now := nowTime.UnixMilli()
	cur := map[string]bool{}
	var events []Row

	rows := make([]Row, 0, len(snap.Connections))
	for _, c := range snap.Connections {
		cur[c.ID] = true
		if prevIDs == nil || !prevIDs[c.ID] || nowTime.Sub(s.lastWritten[c.ID]) >= 10*time.Second {
			rows = append(rows, rowFromConnection(c, now))
			s.lastWritten[c.ID] = nowTime
		}
	}
	closed := make([]string, 0)
	for id := range prevIDs {
		if !cur[id] {
			closed = append(closed, id)
			delete(s.lastWritten, id)
		}
	}
	if len(rows) == 0 && len(closed) == 0 {
		return events
	}

	tx, err := s.db.Begin()
	if err != nil {
		return events
	}
	defer func() {
		if tx != nil {
			_ = tx.Rollback()
		}
	}()
	stmt, err := tx.Prepare(`INSERT INTO requests(id,seen_at,host,process,rule,outbound,upload,download,closed,kind)
		VALUES(?,?,?,?,?,?,?,?,0,?)
		ON CONFLICT(id) DO UPDATE SET seen_at=excluded.seen_at, upload=excluded.upload, download=excluded.download,
		rule=excluded.rule, outbound=excluded.outbound, process=excluded.process, host=excluded.host, kind=excluded.kind`)
	if err != nil {
		return nil
	}
	defer stmt.Close()

	for _, row := range rows {
		_, _ = stmt.Exec(row.ID, row.SeenAt, row.Host, row.Process, row.Rule, row.Outbound, row.Upload, row.Download, row.Kind)
		if prevIDs != nil && !prevIDs[row.ID] {
			events = append(events, row)
		}
	}

	if len(closed) > 0 {
		closeStmt, err := tx.Prepare(`UPDATE requests SET closed=1, seen_at=? WHERE id=?`)
		if err == nil {
			for _, id := range closed {
				_, _ = closeStmt.Exec(now, id)
			}
			closeStmt.Close()
		}
	}

	_ = tx.Commit()
	tx = nil
	return events
}

func rowFromConnection(c clash.Connection, seenAt int64) Row {
	host := c.Metadata.Host
	if host == "" {
		host = c.Metadata.Destination
		if c.Metadata.DestinationPort != "" {
			host += ":" + c.Metadata.DestinationPort
		}
	}
	proc := c.Metadata.Process
	if proc == "" {
		proc = basename(c.Metadata.ProcessPath)
	}
	outbound := ""
	if len(c.Chains) > 0 {
		outbound = c.Chains[0]
	}
	return Row{ID: c.ID, SeenAt: seenAt, Host: host, Process: proc, Rule: c.Rule, Outbound: outbound, Upload: c.Upload, Download: c.Download, Kind: kindOf(outbound, c.Rule)}
}

func (s *Store) Query(kind string, limit int, since int64) ([]Row, error) {
	if limit <= 0 || limit > 200 {
		limit = 200
	}
	q := `SELECT id,seen_at,host,process,rule,outbound,upload,download,closed,kind FROM requests WHERE seen_at>=?`
	args := []any{since}
	if kind != "" && kind != "all" {
		q += ` AND kind=?`
		args = append(args, kind)
	}
	q += ` ORDER BY seen_at DESC LIMIT ?`
	args = append(args, limit)
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Row
	for rows.Next() {
		var r Row
		var closed int
		if err := rows.Scan(&r.ID, &r.SeenAt, &r.Host, &r.Process, &r.Rule, &r.Outbound, &r.Upload, &r.Download, &closed, &r.Kind); err != nil {
			return nil, err
		}
		r.Closed = closed != 0
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) Sweep(retention time.Duration) {
	cut := time.Now().Add(-retention).UnixMilli()
	_, _ = s.db.Exec(`DELETE FROM requests WHERE seen_at <= ?`, cut)
	var n int
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM requests`).Scan(&n)
	if n > 10000 {
		_, _ = s.db.Exec(`DELETE FROM requests WHERE id IN (SELECT id FROM requests ORDER BY seen_at ASC LIMIT ?)`, n-10000)
	}
	var sz int64
	_ = s.db.QueryRow(`SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()`).Scan(&sz)
	if sz > 16*1024*1024 {
		_, _ = s.db.Exec(`DELETE FROM requests WHERE id IN (SELECT id FROM requests ORDER BY seen_at ASC LIMIT 2000)`)
	}
	_, _ = s.db.Exec(`PRAGMA incremental_vacuum`)
}

func kindOf(outbound, rule string) string {
	o := strings.ToLower(outbound)
	r := strings.ToLower(rule)
	if strings.Contains(o, "reject") || strings.Contains(r, "reject") {
		return "reject"
	}
	if o == "direct" || strings.Contains(o, "direct") {
		return "direct"
	}
	return "proxy"
}

func basename(p string) string {
	if p == "" {
		return ""
	}
	p = strings.ReplaceAll(p, "\\", "/")
	if i := strings.LastIndex(p, "/"); i >= 0 {
		return p[i+1:]
	}
	return p
}

func RetentionOf(f state.File) time.Duration {
	return state.RetentionDuration(f.Settings.LogRetention)
}
