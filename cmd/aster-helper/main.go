// aster-helper is installed by the optional PKG as a root-owned launchd
// daemon.  It deliberately has no HTTP server and only accepts a fixed set of
// requests over a Unix socket after verifying the connecting local UID.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
	"aster/internal/helper"
)

const managedCoreOwner = 0

type persistedState struct {
	UID          uint32 `json:"uid"`
	PID          int    `json:"pid"`
	Generation   uint64 `json:"generation"`
	ProxyService string `json:"proxyService,omitempty"`
	ProxyPort    int    `json:"proxyPort,omitempty"`
}

type server struct {
	mu         sync.Mutex
	socket     string
	core       string
	runtime    string
	state      string
	current    *exec.Cmd
	persist    persistedState
	allowedUID uint32
	leaseAt    time.Time
}

func main() {
	socket := flag.String("socket", helper.DefaultSocket, "Unix socket path")
	runtime := flag.String("runtime", "/Library/Application Support/Aster/runtime", "root-owned runtime directory")
	flag.Parse()
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "aster-helper must be launched by launchd as root")
		os.Exit(1)
	}
	s := &server{socket: *socket, core: helper.ManagedCorePath, runtime: *runtime, state: filepath.Join(*runtime, "helper-state.json")}
	if err := s.prepare(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	go s.expireLease()
	if err := s.serve(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func (s *server) prepare() error {
	if err := os.MkdirAll(s.runtime, 0o700); err != nil {
		return err
	}
	if err := verifyManagedCore(s.core); err != nil {
		return err
	}
	if data, err := os.ReadFile(s.state); err == nil {
		_ = json.Unmarshal(data, &s.persist)
	}
	owner, err := os.ReadFile(filepath.Join(filepath.Dir(s.runtime), "allowed-uid"))
	if err != nil {
		return fmt.Errorf("missing installation owner: %w", err)
	}
	uid, err := strconv.ParseUint(strings.TrimSpace(string(owner)), 10, 32)
	if err != nil || uid == 0 {
		return errors.New("invalid installation owner")
	}
	s.allowedUID = uint32(uid)
	if s.persist.UID != 0 && s.persist.UID != s.allowedUID {
		return errors.New("helper state owner does not match installation owner")
	}
	s.persist.UID = s.allowedUID
	_ = s.save()
	_ = os.Remove(s.socket)
	return nil
}

// verifyManagedCore makes the privileged execution boundary explicit: the
// helper may run only the PKG-installed bundled core, owned by root and
// immutable to every non-root account. The daemon's per-user CorePath is never
// a valid TUN target.
func verifyManagedCore(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("refusing unmanaged core %q: %w", path, err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("refusing non-root-writable or non-regular core %q", path)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != managedCoreOwner {
		return fmt.Errorf("refusing non-root-owned core %q", path)
	}
	return nil
}

func (s *server) serve() error {
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: s.socket, Net: "unix"})
	if err != nil {
		return err
	}
	defer listener.Close()
	// The socket is private to the console user recorded by postinstall.  A
	// root:wheel socket would reject normal macOS users before peer-UID
	// validation could even run.
	if err := os.Chown(s.socket, int(s.allowedUID), -1); err != nil {
		return err
	}
	if err := os.Chmod(s.socket, 0o600); err != nil {
		return err
	}
	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			return err
		}
		go s.handle(conn)
	}
}

func peerUID(conn *net.UnixConn) (uint32, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var cred *unix.Xucred
	var controlErr error
	err = raw.Control(func(fd uintptr) {
		cred, controlErr = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	})
	if err != nil {
		return 0, err
	}
	if controlErr != nil {
		return 0, controlErr
	}
	return cred.Uid, nil
}

func (s *server) handle(conn *net.UnixConn) {
	defer conn.Close()
	uid, err := peerUID(conn)
	if err != nil {
		s.reply(conn, helper.Response{Error: "无法验证本地调用者"})
		return
	}
	var request helper.Request
	decoder := json.NewDecoder(&ioLimitReader{Reader: bufio.NewReader(conn), N: helper.MaxConfigSize + 1024})
	if err := decoder.Decode(&request); err != nil {
		s.reply(conn, helper.Response{Error: "无效请求"})
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if uid != s.allowedUID {
		s.reply(conn, helper.Response{Error: "此网络组件属于另一个本机用户"})
		return
	}
	response := s.perform(request)
	s.reply(conn, response)
}

func (s *server) perform(request helper.Request) helper.Response {
	switch request.Action {
	case "start":
		if s.alive() {
			s.leaseAt = time.Now()
			return helper.Response{OK: true, PID: s.persist.PID, Generation: s.persist.Generation}
		}
		if err := s.writeConfig(request.Config); err != nil {
			return helper.Response{Error: err.Error()}
		}
		if err := s.start(); err != nil {
			return helper.Response{Error: err.Error()}
		}
	case "reload":
		if !s.alive() {
			return helper.Response{Error: "受控核心未运行"}
		}
		if err := s.writeConfig(request.Config); err != nil {
			return helper.Response{Error: err.Error()}
		}
		if err := syscall.Kill(s.persist.PID, syscall.SIGHUP); err != nil {
			return helper.Response{Error: err.Error()}
		}
	case "stop":
		s.stop()
	case "lease":
		if !s.alive() {
			return helper.Response{Error: "受控核心未运行"}
		}
	case "set_proxy":
		if err := applyProxy(request.Service, request.Port, request.Bypass, true); err != nil {
			return helper.Response{Error: err.Error()}
		}
		s.persist.ProxyService = request.Service
		s.persist.ProxyPort = request.Port
		if err := s.save(); err != nil {
			return helper.Response{Error: err.Error()}
		}
	case "clear_proxy":
		if s.persist.ProxyService == "" || s.persist.ProxyService != request.Service || s.persist.ProxyPort != request.Port {
			return helper.Response{OK: true}
		}
		if err := applyProxy(request.Service, request.Port, nil, false); err != nil {
			return helper.Response{Error: err.Error()}
		}
		s.persist.ProxyService = ""
		s.persist.ProxyPort = 0
		if err := s.save(); err != nil {
			return helper.Response{Error: err.Error()}
		}
	default:
		return helper.Response{Error: "不允许的 helper 操作"}
	}
	s.leaseAt = time.Now()
	return helper.Response{OK: true, PID: s.persist.PID, Generation: s.persist.Generation}
}

func applyProxy(service string, port int, bypass []string, enabled bool) error {
	if service == "" || len(service) > 128 || port < 1 || port > 65535 {
		return errors.New("拒绝无效系统代理请求")
	}
	for _, item := range bypass {
		if len(item) > 253 {
			return errors.New("拒绝无效代理绕过域名")
		}
	}
	run := func(args ...string) error {
		out, err := exec.Command("/usr/sbin/networksetup", args...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("networksetup: %s", string(out))
		}
		return nil
	}
	state := "off"
	if enabled {
		state = "on"
		for _, kind := range []string{"-setwebproxy", "-setsecurewebproxy", "-setsocksfirewallproxy"} {
			if err := run(kind, service, "127.0.0.1", fmt.Sprint(port)); err != nil {
				return err
			}
		}
		if len(bypass) > 0 {
			args := append([]string{"-setproxybypassdomains", service}, bypass...)
			if err := run(args...); err != nil {
				return err
			}
		}
	}
	for _, kind := range []string{"-setwebproxystate", "-setsecurewebproxystate", "-setsocksfirewallproxystate"} {
		if err := run(kind, service, state); err != nil {
			return err
		}
	}
	return nil
}

func (s *server) writeConfig(config []byte) error {
	if len(config) == 0 || len(config) > helper.MaxConfigSize || !json.Valid(config) {
		return errors.New("拒绝无效核心配置")
	}
	tmp := filepath.Join(s.runtime, "config.json.tmp")
	if err := os.WriteFile(tmp, config, 0o600); err != nil {
		return err
	}
	if out, err := exec.Command(s.core, "check", "-c", tmp).CombinedOutput(); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("核心配置校验失败: %s", string(out))
	}
	return os.Rename(tmp, filepath.Join(s.runtime, "config.json"))
}

func (s *server) start() error {
	cmd := exec.Command(s.core, "run", "-c", filepath.Join(s.runtime, "config.json"))
	cmd.Dir = s.runtime
	if err := cmd.Start(); err != nil {
		return err
	}
	s.current = cmd
	s.persist.PID = cmd.Process.Pid
	s.persist.Generation++
	if err := s.save(); err != nil {
		s.stop()
		return err
	}
	go func() { _ = cmd.Wait() }()
	return nil
}

func (s *server) alive() bool {
	if s.persist.PID <= 0 {
		return false
	}
	return syscall.Kill(s.persist.PID, 0) == nil
}

func (s *server) stop() {
	if s.persist.PID > 0 {
		pid := s.persist.PID
		_ = syscall.Kill(pid, syscall.SIGTERM)
		// 轮询等待进程退出，确保端口完全释放
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
	s.current = nil
	s.persist.PID = 0
	if s.persist.ProxyService != "" && s.persist.ProxyPort > 0 {
		_ = applyProxy(s.persist.ProxyService, s.persist.ProxyPort, nil, false)
		s.persist.ProxyService = ""
		s.persist.ProxyPort = 0
	}
	_ = s.save()
}

func (s *server) save() error {
	data, err := json.Marshal(s.persist)
	if err != nil {
		return err
	}
	return os.WriteFile(s.state, data, 0o600)
}

func (s *server) expireLease() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		s.mu.Lock()
		if !s.leaseAt.IsZero() && time.Since(s.leaseAt) > 20*time.Second {
			s.stop()
			s.leaseAt = time.Time{}
		}
		s.mu.Unlock()
	}
}

func (s *server) reply(conn net.Conn, response helper.Response) {
	_ = json.NewEncoder(conn).Encode(response)
}

// ioLimitReader prevents an untrusted local client from making json.Decoder
// allocate an unbounded request before the config size check is reached.
type ioLimitReader struct {
	Reader *bufio.Reader
	N      int
}

func (r *ioLimitReader) Read(p []byte) (int, error) {
	if r.N <= 0 {
		return 0, errors.New("request too large")
	}
	if len(p) > r.N {
		p = p[:r.N]
	}
	n, err := r.Reader.Read(p)
	r.N -= n
	return n, err
}
