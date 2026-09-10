package core

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"testing"

	"aster/internal/helper"
	"aster/internal/state"
)

func TestRequiresPrivilegeForNodeTun(t *testing.T) {
	f := state.DefaultFile()
	f.Capture.Tun = true
	if !requiresPrivilege(f) {
		t.Fatal("node-mode TUN must require privileged launch")
	}
}

func TestNewRestoresPrivilegedOwnershipForExistingTunCore(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	st, err := state.Open()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Update(func(f *state.File) error {
		f.Capture.Tun = true
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(st.PIDPath(), []byte(strconv.Itoa(os.Getpid())), 0o600); err != nil {
		t.Fatal(err)
	}
	m := New(st)
	if !m.Privileged() {
		t.Fatal("existing TUN PID must retain privileged ownership after manager recreation")
	}
	if !m.CanReload(st.Get()) {
		t.Fatal("same TUN privilege boundary should be reloadable without a new authorization")
	}
}

func TestRequiresPrivilegeForReadOnlySubscriptionTun(t *testing.T) {
	f := state.DefaultFile()
	f.Capture.Tun = false
	f.Profiles = []state.ConfigProfile{{
		ID: "full", Kind: state.ProfileKindSubscription,
		Config: json.RawMessage(`{"outbounds":[{"type":"direct"}],"inbounds":[{"type":"tun"}]}`),
	}}
	f.ActiveConfigID = "full"
	if !requiresPrivilege(f) {
		t.Fatal("imported TUN must require privileged launch without mutating Capture")
	}
}

func TestRequiresPrivilegeIgnoresNonTunReadOnlySubscription(t *testing.T) {
	f := state.DefaultFile()
	f.Profiles = []state.ConfigProfile{{
		ID: "full", Kind: state.ProfileKindSubscription,
		Config: json.RawMessage(`{"outbounds":[{"type":"direct"}],"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":7890}]}`),
	}}
	f.ActiveConfigID = "full"
	if requiresPrivilege(f) {
		t.Fatal("mixed-only imported profile must not request administrator authorization")
	}
}

func TestBinaryForTunIgnoresCustomCore(t *testing.T) {
	f := state.DefaultFile()
	f.Capture.Tun = true
	f.Settings.CorePath = "/tmp/custom-sing-box"
	bin, err := BinaryFor(f)
	if err == nil && bin != helper.ManagedCorePath {
		t.Fatalf("TUN binary=%q, want managed path %q", bin, helper.ManagedCorePath)
	}
	if err != nil && strings.Contains(err.Error(), "custom-sing-box") {
		t.Fatalf("TUN should ignore custom core path, err=%v", err)
	}
}
