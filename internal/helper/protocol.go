// Package helper defines the intentionally small local protocol between the
// unprivileged Aster daemon and the root launchd helper.
package helper

import "encoding/json"

const (
	DefaultSocket = "/var/run/app.aster.helper.sock"
	// ManagedCorePath is the only binary the root helper may execute. It is
	// installed and made root-owned by the optional network-component PKG.
	ManagedCorePath = "/Applications/Aster.app/Contents/Resources/sing-box"
	MaxConfigSize   = 4 << 20
)

type Request struct {
	Action  string          `json:"action"`
	Config  json.RawMessage `json:"config,omitempty"`
	Service string          `json:"service,omitempty"`
	Port    int             `json:"port,omitempty"`
	Bypass  []string        `json:"bypass,omitempty"`
}

type Response struct {
	OK         bool   `json:"ok"`
	Error      string `json:"error,omitempty"`
	PID        int    `json:"pid,omitempty"`
	Generation uint64 `json:"generation,omitempty"`
}
