package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"
	"time"

	"aster/internal/api"
	"aster/internal/app"
)

var version = "1.1.0"

func main() {
	if runtime.GOOS != "darwin" {
		log.Fatalf("Aster Core Daemon 仅支持 macOS，当前系统: %s", runtime.GOOS)
	}
	if runtime.GOARCH != "arm64" {
		log.Fatalf("Aster Core Daemon 仅支持 Apple Silicon (arm64)，当前架构: %s", runtime.GOARCH)
	}

	showVer := flag.Bool("v", false, "显示版本信息")
	flag.Parse()

	if *showVer {
		fmt.Printf("Aster Core Daemon v%s (%s/%s)\n", version, runtime.GOOS, runtime.GOARCH)
		return
	}

	detachFromParentSession()

	application, err := app.New()
	if err != nil {
		log.Fatalf("初始化 Aster 应用核心失败: %v", err)
	}

	setupDaemonLog(application.Store().DaemonLogPath())

	sock := application.ControlSocket()
	if pingUnixStatus(sock) {
		log.Printf("Aster 核心守护进程已在 %s 上健康运行，直接复用已有实例。", sock)
		os.Exit(0)
	}
	detachFromParentSession()
	replaceUnreachableDaemon(application.ReadDaemonPID(), sock)
	_ = os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		log.Fatalf("无法监听控制面 %s: %v", sock, err)
	}
	_ = os.Chmod(sock, 0o600)

	if err := application.WriteDaemonPID(); err != nil {
		log.Printf("写入 daemon.pid 失败: %v", err)
	}

	srv := &http.Server{
		Handler: (&api.Server{App: application}).Handler(),
	}

	application.StartBackground()

	go func() {
		log.Printf("Aster Core Daemon v%s 已就绪，正在监听: unix://%s", version, sock)
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("Aster HTTP/WS 服务异常终止: %v", err)
		}
	}()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigChan
	log.Printf("接收到系统信号 [%s]，正在安全关闭 Aster 网络中枢...", sig)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	ownsSocket := application.OwnsDaemonPID()
	_ = srv.Shutdown(ctx)
	application.Shutdown()
	if ownsSocket {
		_ = os.Remove(sock)
	}
	log.Println("Aster Core Daemon 已安全退出。")
}

func detachFromParentSession() {
	if _, err := syscall.Setsid(); err != nil && !errors.Is(err, syscall.EPERM) {
		log.Printf("脱离父进程会话失败: %v", err)
	}
	signal.Ignore(syscall.SIGHUP)
}

func replaceUnreachableDaemon(pid int, sock string) {
	if pid <= 0 || pid == os.Getpid() || !processSignalable(pid) {
		return
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return
	}
	log.Printf("控制面 %s 不可达，正在替换旧守护进程 pid=%d", sock, pid)
	_ = proc.Signal(syscall.SIGTERM)
	deadline := time.Now().Add(3 * time.Second)
	for processSignalable(pid) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if processSignalable(pid) {
		_ = proc.Signal(syscall.SIGKILL)
	}
}

func processSignalable(pid int) bool {
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

func pingUnixStatus(path string) bool {
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", path)
			},
		},
		Timeout: 500 * time.Millisecond,
	}
	resp, err := client.Get("http://localhost/api/v1/status")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func setupDaemonLog(path string) {
	_ = os.MkdirAll(filepath.Dir(path), 0o700)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	log.SetOutput(io.MultiWriter(os.Stderr, f))
}
