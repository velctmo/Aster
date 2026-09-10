package core

import (
	"bytes"
	"debug/macho"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"aster/internal/helper"
	"aster/internal/state"
)

type Manager struct {
	mu         sync.Mutex
	cmd        *exec.Cmd
	privileged bool
	binary     string
	version    string
	st         *state.Store
	lastErr    string
}

func New(st *state.Store) *Manager {
	m := &Manager{st: st}
	// A TUN core is launched by macOS administrator authorization and therefore
	// survives a UI/daemon restart. Reconstruct the ownership boundary from the
	// persisted active state so a later stop/reload never treats that root-owned
	// process as an unprivileged child.
	f := st.Get()
	if requiresPrivilege(f) && processAlive(m.readPID()) {
		m.privileged = true
		m.binary, _ = BinaryFor(f)
	}
	return m
}

func (m *Manager) Running() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.aliveLocked()
}

func (m *Manager) LastError() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.lastErr
}

func (m *Manager) Privileged() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.privileged && m.aliveLocked()
}

// CanReload reports whether the currently managed process can reload a new
// configuration without crossing the macOS privilege boundary. Keeping the
// same TUN process alive avoids a second authorization dialog while changing
// profiles or other reloadable settings.
func (m *Manager) CanReload(f state.File) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.aliveLocked() && m.privileged == requiresPrivilege(f)
}

// Version returns the version observed while launching the managed core. It
// deliberately never spawns an external process on a status-poll path.
func (m *Manager) Version() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.version
}

func (m *Manager) aliveLocked() bool {
	return processAlive(m.readPID())
}

// processAlive reports whether pid refers to a live process.
// Signal(0) returns EPERM when the process exists but is owned by another
// user (root sing-box after TUN). That still means alive.
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	err = proc.Signal(syscall.Signal(0))
	if err == nil {
		return true
	}
	return errors.Is(err, syscall.EPERM)
}

func waitProcessGone(pid int, timeout time.Duration) {
	if pid <= 0 {
		return
	}
	deadline := time.Now().Add(timeout)
	for processAlive(pid) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
}

func ValidateConfig(bin, cfg string) error {
	cmd := exec.Command(bin, "check", "-c", cfg)
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("内核配置校验失败: %s", msg)
	}
	return nil
}

func (m *Manager) Apply(f state.File, needRestart bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !f.Wanted {
		return m.stopLocked()
	}
	running := m.aliveLocked()
	wantPriv := requiresPrivilege(f)
	bin, err := BinaryFor(f)
	if err != nil {
		m.lastErr = err.Error()
		return err
	}
	if running && !needRestart && m.privileged == wantPriv {
		if wantPriv {
			config, err := os.ReadFile(m.st.ConfigPath())
			if err != nil {
				return err
			}
			response, err := helper.NewClient().Reload(config)
			if err == nil && response.PID > 0 {
				_ = os.WriteFile(m.st.PIDPath(), []byte(strconv.Itoa(response.PID)), 0o600)
				return nil
			}
			if err != nil {
				m.lastErr = err.Error()
			}
		}
		if m.cmd != nil && m.cmd.Process != nil {
			if err := m.cmd.Process.Signal(syscall.SIGHUP); err == nil {
				return nil
			}
		}
		pid := m.readPID()
		if pid > 0 {
			if err := syscall.Kill(pid, syscall.SIGHUP); err == nil {
				return nil
			}
		}
	}
	oldPID := m.readPID()
	oldPrivileged := m.privileged
	if err := m.stopLocked(); err != nil {
		return err
	}
	if oldPrivileged && oldPID > 0 {
		waitProcessGone(oldPID, 2*time.Second)
	}
	m.version = versionOfBinary(bin)
	cfg := m.st.ConfigPath()

	// Pre-validate config before launching process
	if err := ValidateConfig(bin, cfg); err != nil {
		m.lastErr = err.Error()
		return err
	}

	if wantPriv {
		// Root launch is delegated to the PKG-installed launchd helper.  Never
		// fall back to osascript or a SUID binary: absence is an actionable setup
		// error, not a reason to display another authorization prompt.
		config, readErr := os.ReadFile(cfg)
		if readErr != nil {
			return readErr
		}
		response, err := helper.NewClient().Start(config)
		if err != nil {
			m.lastErr = err.Error()
			return err
		}
		pid := response.PID
		m.privileged = true
		m.binary = bin
		if pid > 0 {
			_ = os.WriteFile(m.st.PIDPath(), []byte(strconv.Itoa(pid)), 0o600)
		}
		if pid <= 0 || !processAlive(pid) {
			m.privileged = false
			_ = os.Remove(m.st.PIDPath())
			m.lastErr = "内核在 TUN 模式下立即退出"
			return fmt.Errorf("%s", m.lastErr)
		}
		m.lastErr = ""
		return nil
	}

	cmd := exec.Command(bin, "run", "-c", cfg)
	cmd.Dir = m.st.Dir()
	var errBuf bytes.Buffer
	cmd.Stderr = &errBuf
	cmd.Stdout = nil

	if err := cmd.Start(); err != nil {
		m.lastErr = err.Error()
		return err
	}
	m.cmd = cmd
	m.privileged = false
	m.binary = bin
	m.lastErr = ""
	_ = os.WriteFile(m.st.PIDPath(), []byte(strconv.Itoa(cmd.Process.Pid)), 0o600)

	go func() {
		err := cmd.Wait()
		if err != nil {
			errStr := strings.TrimSpace(errBuf.String())
			m.mu.Lock()
			if errStr != "" {
				m.lastErr = errStr
			} else {
				m.lastErr = fmt.Sprintf("内核异常退出: %v", err)
			}
			m.mu.Unlock()
		}
	}()
	return nil
}

// BinaryFor returns the exact binary that will validate and run the provided
// state. TUN deliberately ignores a per-user CorePath: only the PKG-managed
// core can cross the privilege boundary, so validation cannot diverge from the
// root helper's eventual execution target.
func BinaryFor(f state.File) (string, error) {
	if requiresPrivilege(f) {
		return privilegedBinary()
	}
	return FindBinary(f.Settings.CorePath)
}

func privilegedBinary() (string, error) {
	path := helper.ManagedCorePath
	if st, err := os.Stat(path); err != nil || st.IsDir() || !isArm64Binary(path) {
		return "", fmt.Errorf("未找到由 Aster 网络组件管理的 Apple Silicon 内核")
	}
	return path, nil
}

// requiresPrivilege derives the TUN requirement without altering an imported
// profile. Node profiles are controlled by Aster's Capture state; full
// profiles remain read-only, so their own inbounds are inspected only to pick
// the process-launch privilege boundary.
func requiresPrivilege(f state.File) bool {
	if f.Capture.Tun {
		return true
	}
	p := f.ActiveProfile()
	if p == nil || p.Kind != state.ProfileKindSubscription || len(p.Config) == 0 {
		return false
	}
	var config struct {
		Inbounds []struct {
			Type string `json:"type"`
		} `json:"inbounds"`
	}
	if json.Unmarshal(p.Config, &config) != nil {
		return false
	}
	for _, inbound := range config.Inbounds {
		if inbound.Type == "tun" {
			return true
		}
	}
	return false
}

func (m *Manager) Stop() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.stopLocked()
}

// Lease records that the user daemon is still alive.  The root helper uses it
// to tear down an orphaned TUN core after a crash or forced termination.
func (m *Manager) Lease() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.privileged && m.aliveLocked() {
		_, _ = helper.NewClient().Lease()
	}
}

func (m *Manager) stopLocked() error {
	// 1. 若拥有直接子进程句柄，优先通过信号安全平滑停止，避免调用外部提权
	if m.cmd != nil && m.cmd.Process != nil {
		_ = m.cmd.Process.Signal(syscall.SIGTERM)
		done := make(chan error, 1)
		go func() {
			_, err := m.cmd.Process.Wait()
			done <- err
		}()
		select {
		case <-done:
		case <-time.After(500 * time.Millisecond):
			_ = m.cmd.Process.Kill()
			select {
			case <-done:
			case <-time.After(300 * time.Millisecond):
			}
		}
		m.cmd = nil
		m.privileged = false
		m.binary = ""
		_ = os.Remove(m.st.PIDPath())
		return nil
	}

	// 2. 孤儿或脱离句柄的进程，通过 PID 清理
	pid := m.readPID()
	if pid > 0 {
		if m.privileged {
			if _, err := helper.NewClient().Stop(); err != nil {
				return err
			}
		} else {
			_ = syscall.Kill(pid, syscall.SIGTERM)
			stopped := false
			for i := 0; i < 20; i++ {
				time.Sleep(50 * time.Millisecond)
				if syscall.Kill(pid, 0) != nil {
					stopped = true
					break
				}
			}
			if !stopped {
				_ = syscall.Kill(pid, syscall.SIGKILL)
				for i := 0; i < 10; i++ {
					time.Sleep(50 * time.Millisecond)
					if syscall.Kill(pid, 0) != nil {
						break
					}
				}
			}
		}
	}
	m.cmd = nil
	m.privileged = false
	m.binary = ""
	_ = os.Remove(m.st.PIDPath())
	return nil
}

func (m *Manager) readPID() int {
	b, err := os.ReadFile(m.st.PIDPath())
	if err != nil {
		if m.cmd != nil && m.cmd.Process != nil {
			return m.cmd.Process.Pid
		}
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	return n
}

func FindBinary(configured string) (string, error) {
	if configured != "" {
		if st, err := os.Stat(configured); err == nil && !st.IsDir() {
			if !isArm64Binary(configured) {
				return "", fmt.Errorf("配置的内核不是 macOS ARM64 (Apple Silicon) 可执行文件")
			}
			return configured, nil
		}
		if path, err := exec.LookPath(configured); err == nil {
			if !isArm64Binary(path) {
				return "", fmt.Errorf("配置的内核不是 macOS ARM64 (Apple Silicon) 可执行文件")
			}
			return path, nil
		}
	}
	// 优先检查 App Bundle 内部 Resources 目录
	if exe, err := os.Executable(); err == nil {
		bundleRes := filepath.Join(filepath.Dir(exe), "..", "Resources", "sing-box")
		if st, err := os.Stat(bundleRes); err == nil && !st.IsDir() && isArm64Binary(bundleRes) {
			return bundleRes, nil
		}
		sameDir := filepath.Join(filepath.Dir(exe), "sing-box")
		if st, err := os.Stat(sameDir); err == nil && !st.IsDir() && isArm64Binary(sameDir) {
			return sameDir, nil
		}
	}
	if dir, err := state.Dir(); err == nil {
		if p := latestManaged(filepath.Join(dir, "cores")); p != "" {
			return p, nil
		}
	}
	cands := []string{"sing-box", "/opt/homebrew/bin/sing-box"}
	if home, err := os.UserHomeDir(); err == nil {
		cands = append(cands, filepath.Join(home, "bin", "sing-box"))
	}
	for _, c := range cands {
		path, err := exec.LookPath(c)
		if err == nil && isArm64Binary(path) {
			return path, nil
		}
		if filepath.IsAbs(c) {
			if st, err := os.Stat(c); err == nil && !st.IsDir() && isArm64Binary(c) {
				return c, nil
			}
		}
	}
	return "", fmt.Errorf("未找到 sing-box 内核")
}

func Version(path string) string {
	bin, err := FindBinary(path)
	if err != nil {
		return ""
	}
	return versionOfBinary(bin)
}

func versionOfBinary(bin string) string {
	out, err := exec.Command(bin, "version").Output()
	if err != nil {
		return ""
	}
	line := strings.TrimSpace(strings.Split(string(out), "\n")[0])
	return line
}

func findSingBoxPID(bin string) int {
	out, err := exec.Command("pgrep", "-n", "-f", bin+" run").Output()
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(out)))
	return n
}

func isArm64Binary(path string) bool {
	if f, err := macho.Open(path); err == nil {
		defer f.Close()
		return f.Cpu == macho.CpuArm64
	}
	if ff, err := macho.OpenFat(path); err == nil {
		defer ff.Close()
		for _, arch := range ff.Arches {
			if arch.Cpu == macho.CpuArm64 {
				return true
			}
		}
	}
	return false
}

func latestManaged(coresDir string) string {
	ents, err := os.ReadDir(coresDir)
	if err != nil {
		return ""
	}
	var best string
	var bestMod time.Time
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, "sing-box") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		p := filepath.Join(coresDir, name)
		if info.Mode()&0o111 == 0 {
			continue
		}
		if !isArm64Binary(p) {
			continue
		}
		if info.ModTime().After(bestMod) {
			bestMod = info.ModTime()
			best = p
		}
	}
	return best
}
