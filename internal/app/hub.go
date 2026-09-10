package app

import (
	"encoding/json"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

type client struct {
	ch   chan []byte
	kind string
}

type Hub struct {
	mu    sync.Mutex
	conns map[*websocket.Conn]*client
	seq   atomic.Uint64
}

type Event struct {
	Type      string          `json:"type"`
	Data      json.RawMessage `json:"data"`
	Sequence  uint64          `json:"sequence"`
	Timestamp int64           `json:"timestamp"`
}

const realtimeQueueCapacity = 256

func NewHub() *Hub {
	return &Hub{conns: map[*websocket.Conn]*client{}}
}

func (h *Hub) Add(c *websocket.Conn, kind string) chan []byte {
	ch := make(chan []byte, realtimeQueueCapacity)
	h.mu.Lock()
	h.conns[c] = &client{ch: ch, kind: kind}
	h.mu.Unlock()
	return ch
}

func (h *Hub) Remove(c *websocket.Conn) {
	h.mu.Lock()
	if cl, ok := h.conns[c]; ok {
		close(cl.ch)
		delete(h.conns, c)
	}
	h.mu.Unlock()
}

func (h *Hub) Broadcast(kind string, payload any) {
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}
	b, err := json.Marshal(Event{Type: kind, Data: data, Sequence: h.seq.Add(1), Timestamp: time.Now().UnixMilli()})
	if err != nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for conn, cl := range h.conns {
		if !clientAccepts(cl.kind, kind) {
			continue
		}
		select {
		case cl.ch <- b:
		default:
			// Never silently lose an incremental event: removing this stream
			// closes its writer loop, and the client reconnects for a fresh
			// snapshot before accepting more deltas.
			close(cl.ch)
			delete(h.conns, conn)
		}
	}
}

// clientAccepts keeps event streams narrowly scoped. Traffic additionally
// carries per-node measurements and refresh-triggered node snapshots because
// the same UI owns both views.
func clientAccepts(clientKind, eventKind string) bool {
	if clientKind == "" || clientKind == eventKind {
		return true
	}
	if eventKind == "notify" {
		return clientKind == "status" || clientKind == "traffic"
	}
	return clientKind == "traffic" && (eventKind == "node_delay" || eventKind == "node_speed" || eventKind == "nodes")
}

func (h *Hub) Event(kind string, payload any) Event {
	data, _ := json.Marshal(payload)
	return Event{Type: kind, Data: data, Sequence: h.seq.Add(1), Timestamp: time.Now().UnixMilli()}
}

func (h *Hub) Sequence() uint64 { return h.seq.Load() }

func (h *Hub) HasClients() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.conns) > 0
}

// HasSubscribers lets producers skip building high-cardinality observation
// payloads when no live client can consume them.
func (h *Hub) HasSubscribers(kind string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, cl := range h.conns {
		if clientAccepts(cl.kind, kind) {
			return true
		}
	}
	return false
}
