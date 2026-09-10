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

var version = "1.0.0"

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

	application, err := app.New()
	if err != nil {
		log.Fatalf("初始化 Aster 应用核心失败: %v", err)
	}

	setupDaemonLog(application.Store().DaemonLogPath())

	addr := application.ControlAddr()
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		resp, pingErr := http.Get(fmt.Sprintf("http://%s/api/v1/status", addr))
		if pingErr == nil && resp.StatusCode == 200 {
			_ = resp.Body.Close()
			log.Printf("Aster 核心守护进程已在 %s 上健康运行，直接复用已有实例。", addr)
			os.Exit(0)
		}
		log.Fatalf("无法监听端口 %s: %v（请检查是否被其他进程占用）", addr, err)
	}

	if err := application.WriteDaemonPID(); err != nil {
		log.Printf("写入 daemon.pid 失败: %v", err)
	}

	srv := &http.Server{
		Handler: (&api.Server{App: application}).Handler(),
	}

	application.StartBackground()

	go func() {
		log.Printf("Aster Core Daemon v%s 已就绪，正在监听: http://%s", version, addr)
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

	_ = srv.Shutdown(ctx)
	application.Shutdown()
	log.Println("Aster Core Daemon 已安全退出。")
}

func setupDaemonLog(path string) {
	_ = os.MkdirAll(filepath.Dir(path), 0o700)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	log.SetOutput(io.MultiWriter(os.Stderr, f))
}
