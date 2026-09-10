package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"aster/internal/clash"
	"aster/internal/core"
	"aster/internal/logstore"
	"aster/internal/macos"
	"aster/internal/render"
	"aster/internal/state"
)

const DefaultListenAddr = "127.0.0.1:1780"

// ListenAddr is kept for compatibility; prefer App.ControlAddr().
const ListenAddr = DefaultListenAddr

type IPInfo struct {
	IP        string `json:"ip"`
	Country   string `json:"country"`
	City      string `json:"city"`
	ISP       string `json:"isp"`
	FetchedAt int64  `json:"fetchedAt"`
}

type DualIPInfo struct {
	LocalIP   IPInfo `json:"localIP"`
	ProxyIP   IPInfo `json:"proxyIP"`
	Protected bool   `json:"protected"`
	FetchedAt int64  `json:"fetchedAt"`
}

type App struct {
	mu sync.Mutex
	// mutationMu serializes operations that render config.json and transition
	// the managed core. Without it, a second TUN click while macOS is showing
	// its authorization dialog can start a competing privileged launch.
	mutationMu          sync.Mutex
	st                  *state.Store
	core                *core.Manager
	clash               *clash.Client
	logs                *logstore.Store
	prevIDs             map[string]bool
	connections         map[string]clash.Connection
	processMu           sync.Mutex
	processHist         map[string]procHistory
	cachedProcs         []ProcessTrafficStat
	speedtestMu         sync.Mutex
	diagnosticsMu       sync.Mutex
	cachedDiagnostics   NetworkDiagnostics
	cachedDiagnosticsAt time.Time
	pending             bool
	lastErr             string
	needAdm             bool
	tunFail             bool
	up                  int64
	down                int64
	delay               int
	delays              map[string]int
	bandwidths          map[string]float64
	effectiveNodesKey   string
	effectiveNodes      []render.MergedNode
	lastPassive         time.Time
	failN               int
	lastUp              int64
	lastDown            int64
	started             time.Time
	hub                 *Hub
	cancel              context.CancelFunc
	bgWG                sync.WaitGroup
	ipMu                sync.Mutex
	cachedDual          DualIPInfo
	cachedAt            time.Time
	coreRestarts        int
	nextRestart         time.Time
	refreshing          bool
	polling             bool
	sampling            bool
	sweeping            bool
	networkCheck        bool
	startupGraceUntil   time.Time
	lastNotifyTime      map[string]time.Time
	listenAddr          string
}

type StatusJSON struct {
	Running                bool             `json:"running"`
	Pending                bool             `json:"pending"`
	SessionPhase           string           `json:"sessionPhase"`
	NeedAdmin              bool             `json:"needAdmin"`
	TunFailed              bool             `json:"tunFailed"`
	Error                  string           `json:"error"`
	Mode                   string           `json:"mode"`
	Capture                state.Capture    `json:"capture"`
	Selected               string           `json:"selected"`
	SelectedLabel          string           `json:"selectedLabel"`
	DelayMs                int              `json:"delayMs"`
	Upload                 int64            `json:"upload"`
	Download               int64            `json:"download"`
	CoreVersion            string           `json:"coreVersion"`
	HasNodes               bool             `json:"hasNodes"`
	Wanted                 bool             `json:"wanted"`
	RecentNodes            []string         `json:"recentNodes"`
	MixedBusy              bool             `json:"mixedBusy"`
	ClashBusy              bool             `json:"clashBusy"`
	Privileged             bool             `json:"privileged"`
	MixedPort              int              `json:"mixedPort"`
	HttpPort               int              `json:"httpPort"`
	SocksPort              int              `json:"socksPort"`
	ClashPort              int              `json:"clashPort"`
	ControlPort            int              `json:"controlPort"`
	DelayURL               string           `json:"delayURL"`
	APIVersion             string           `json:"apiVersion"`
	ActiveConfigID         string           `json:"activeConfigId"`
	ActiveConfigName       string           `json:"activeConfigName"`
	ActiveConfigKind       string           `json:"activeConfigKind"`
	FeatureRestriction     string           `json:"featureRestriction"`
	Capabilities           CapabilitiesJSON `json:"capabilities"`
	LastSuccessfulConfigID string           `json:"lastSuccessfulConfigId"`
	LastSuccessfulAt       int64            `json:"lastSuccessfulAt"`
}

type CapabilityJSON struct {
	Available bool   `json:"available"`
	Reason    string `json:"reason,omitempty"`
}

type CapabilitiesJSON struct {
	SystemProxy CapabilityJSON `json:"systemProxy"`
	Tun         CapabilityJSON `json:"tun"`
	NodeControl CapabilityJSON `json:"nodeControl"`
	RuleControl CapabilityJSON `json:"ruleControl"`
	Speedtest   CapabilityJSON `json:"speedtest"`
}

type NodeJSON struct {
	ID            string  `json:"id"`
	Tag           string  `json:"tag"`
	Name          string  `json:"name"`
	Protocol      string  `json:"protocol"`
	SubID         string  `json:"subId"`
	SubName       string  `json:"subName"`
	Disabled      bool    `json:"disabled"`
	DelayMs       int     `json:"delayMs"`
	BandwidthMbps float64 `json:"bandwidthMbps,omitempty"`
}

type ConnectionsDelta struct {
	DownloadTotal int64              `json:"downloadTotal"`
	UploadTotal   int64              `json:"uploadTotal"`
	Snapshot      bool               `json:"snapshot,omitempty"`
	Upserts       []clash.Connection `json:"upserts"`
	Closed        []string           `json:"closed"`
}

func New() (*App, error) {
	st, err := state.Open()
	if err != nil {
		return nil, err
	}
	ls, err := logstore.Open(st.LogsPath())
	if err != nil {
		return nil, err
	}
	f := st.Get()
	ctrl := f.Settings.ControlPort
	if ctrl <= 0 {
		ctrl = 1780
	}
	a := &App{
		st:                st,
		core:              core.New(st),
		clash:             clash.New(f.ClashSecret, f.Settings.ClashPort),
		logs:              ls,
		prevIDs:           map[string]bool{},
		connections:       map[string]clash.Connection{},
		processHist:       map[string]procHistory{},
		delays:            map[string]int{},
		bandwidths:        map[string]float64{},
		hub:               NewHub(),
		listenAddr:        fmt.Sprintf("127.0.0.1:%d", ctrl),
		lastErr:           f.Runtime.LastFailure,
		startupGraceUntil: time.Now().Add(10 * time.Second),
		lastNotifyTime:    make(map[string]time.Time),
	}
	return a, nil
}

func (a *App) ControlAddr() string {
	if a.listenAddr == "" {
		return DefaultListenAddr
	}
	return a.listenAddr
}

func (a *App) APIToken() string {
	return a.st.Active().APIToken
}

func (a *App) WriteDaemonPID() error {
	return os.WriteFile(a.st.DaemonPIDPath(), []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600)
}

func (a *App) ClearDaemonPID() {
	_ = os.Remove(a.st.DaemonPIDPath())
}

func (a *App) Store() *state.Store { return a.st }

func (a *App) Hub() *Hub { return a.hub }

func (a *App) StartBackground() {
	ctx, cancel := context.WithCancel(context.Background())
	a.cancel = cancel
	a.bgWG.Add(1)
	go func() {
		defer a.bgWG.Done()
		a.loop(ctx)
	}()
	f := a.st.Get()
	if f.Settings.Autostart {
		_ = macos.SetAutostart(true, mustExe())
	}
	// Aster owns one core session while its daemon is alive.  Wanted remains on
	// disk for API compatibility, but a previous manual/offline state must not
	// make a newly opened application silently fail to start its core.
	a.bgWG.Add(1)
	go func() {
		defer a.bgWG.Done()
		select {
		case <-ctx.Done():
			return
		case <-time.After(300 * time.Millisecond):
		}
		_ = a.StartSession()
	}()
	a.bgWG.Add(1)
	go func() {
		defer a.bgWG.Done()
		select {
		case <-ctx.Done():
			return
		case <-time.After(500 * time.Millisecond):
		}
		a.refreshProfilesAsync(ctx)
	}()
}

func (a *App) Shutdown() {
	if a.cancel != nil {
		a.cancel()
	}
	// The loop can have an in-flight core snapshot, refresh or SQLite sweep.
	// Drain those tasks before closing shared resources below.
	a.waitBackground()
	_ = a.core.Stop()
	f := a.st.Active()
	_ = macos.SetProxy(false, proxyHost(f), proxyPort(f), nil)
	_ = a.logs.Close()
	a.ClearDaemonPID()
}

func (a *App) waitBackground() { a.bgWG.Wait() }

func (a *App) loop(ctx context.Context) {
	tick := time.NewTicker(time.Second)
	sweep := time.NewTicker(30 * time.Second)
	subTick := time.NewTicker(time.Minute)
	netTick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	defer sweep.Stop()
	defer subTick.Stop()
	defer netTick.Stop()
	lastSvc := ""
	lastRefresh := time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			a.runBackground(ctx, &a.polling, func() { a.poll(ctx) })
		case <-sweep.C:
			a.runBackground(ctx, &a.sweeping, func() {
				a.logs.Sweep(state.RetentionDuration(a.st.Get().Settings.LogRetention))
			})
		case <-subTick.C:
			f := a.st.Active()
			if f.Settings.SubIntervalHours <= 0 {
				continue
			}
			if time.Since(lastRefresh) < time.Duration(f.Settings.SubIntervalHours)*time.Hour {
				continue
			}
			lastRefresh = time.Now()
			a.refreshProfilesAsync(ctx)
		case <-netTick.C:
			a.runBackground(ctx, &a.networkCheck, func() { a.reconcileSystemProxy(&lastSvc) })
		}
	}
}

// runBackground keeps periodic work independent without allowing a slow
// invocation to pile up behind every ticker event.  The flag is always read
// and cleared under the App lock, while the actual work runs without it.
func (a *App) runBackground(ctx context.Context, running *bool, work func()) {
	a.mu.Lock()
	if *running {
		a.mu.Unlock()
		return
	}
	*running = true
	a.mu.Unlock()
	a.bgWG.Add(1)
	go func() {
		defer func() {
			a.mu.Lock()
			*running = false
			a.mu.Unlock()
			a.bgWG.Done()
		}()
		if ctx.Err() != nil {
			return
		}
		work()
	}()
}

func (a *App) reconcileSystemProxy(lastSvc *string) {
	f := a.st.Active()
	if !f.Wanted || !f.Capture.SystemProxy || !render.SupportsSystemProxy(f) {
		return
	}
	svc, err := macos.ActiveService()
	if err != nil {
		return
	}
	if svc != *lastSvc && *lastSvc != "" {
		_ = macos.SetProxy(true, proxyHost(f), proxyPort(f), f.Settings.ProxyBypass)
	}
	*lastSvc = svc
}

func (a *App) refreshProfilesAsync(ctx context.Context) {
	a.mu.Lock()
	if a.refreshing {
		a.mu.Unlock()
		return
	}
	a.refreshing = true
	a.mu.Unlock()
	a.bgWG.Add(1)
	go func() {
		defer func() {
			a.mu.Lock()
			a.refreshing = false
			a.mu.Unlock()
			a.bgWG.Done()
		}()
		if ctx.Err() == nil {
			_, _ = a.refreshProfileAuto(ctx)
		}
	}()
}

func (a *App) notifyThrottled(title, message string, minInterval time.Duration) {
	a.mu.Lock()
	if time.Now().Before(a.startupGraceUntil) {
		a.mu.Unlock()
		return
	}
	if a.lastNotifyTime == nil {
		a.lastNotifyTime = make(map[string]time.Time)
	}
	last, ok := a.lastNotifyTime[message]
	if ok && time.Since(last) < minInterval {
		a.mu.Unlock()
		return
	}
	a.lastNotifyTime[message] = time.Now()
	a.mu.Unlock()

	// 统一向前端广播通知事件，由原生客户端负责应用内浮窗与原生系统横幅弹出
	a.hub.Broadcast("notify", map[string]string{
		"title":   title,
		"message": message,
		"type":    "error",
	})

	// 仅当没有前端 GUI 客户端接入（无头模式）时，才回退触发系统底层脚本通知
	if !a.hub.HasClients() {
		macos.NotifyIfHidden(title, message)
	}
}

func (a *App) poll(ctx context.Context) {
	f := a.st.Active()
	if !f.Wanted {
		return
	}
	a.core.Lease()
	if time.Now().Before(a.startupGraceUntil) {
		// 启动静默期内等待核心首次拉起，不向外广播停止或弹通知
		if !a.core.Running() {
			return
		}
	}
	if !a.core.Running() {
		a.mu.Lock()
		was := a.lastErr
		a.lastErr = "内核已停止"
		a.failN = 0
		// An administrator authorization failure is actionable user input, not a
		// transient crash. Retrying it from the poll loop would keep presenting
		// macOS authorization dialogs after the user has declined one.
		canRestart := shouldAutoRestart(f, a.needAdm, a.coreRestarts, a.nextRestart, time.Now())
		restarts := a.coreRestarts
		a.mu.Unlock()
		if was != "内核已停止" {
			_ = macos.SetProxy(false, proxyHost(f), proxyPort(f), nil)
			a.hub.Broadcast("status", a.Status())
			a.notifyThrottled("Aster", "内核已停止", 5*time.Minute)
		}
		if canRestart {
			backoff := time.Duration(1<<restarts) * time.Second
			if backoff > 30*time.Second {
				backoff = 30 * time.Second
			}
			a.mu.Lock()
			a.coreRestarts++
			a.nextRestart = time.Now().Add(backoff)
			a.mu.Unlock()
			// Keep the restart delay inside the tracked poll task. Shutdown cancels
			// its context and waits for this task, so an old daemon cannot revive
			// a core after the user has quit the app.
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			if !a.st.Get().Wanted || ctx.Err() != nil {
				return
			}
			if err := a.apply(a.st.Get(), true); err != nil {
				a.mu.Lock()
				a.lastErr = "内核已停止: 自动重启失败 (" + err.Error() + ")"
				a.mu.Unlock()
				a.hub.Broadcast("status", a.Status())
				return
			}
			a.mu.Lock()
			a.lastErr = ""
			a.started = time.Now()
			a.mu.Unlock()
			a.hub.Broadcast("status", a.Status())
		}
		return
	}
	a.mu.Lock()
	a.coreRestarts = 0
	a.mu.Unlock()
	// A strict full profile need not expose Clash API.  Core liveness is still
	// monitored above, but observation endpoints are optional for that mode.
	if p := f.ActiveProfile(); p != nil && p.Kind == state.ProfileKindSubscription {
		return
	}
	if !a.clash.Healthy() {
		a.mu.Lock()
		grace := time.Since(a.started) < 20*time.Second
		if grace {
			a.mu.Unlock()
			return
		}
		a.failN++
		n := a.failN
		a.mu.Unlock()
		if n >= 8 {
			a.mu.Lock()
			a.lastErr = "内核无响应"
			a.mu.Unlock()
			a.hub.Broadcast("status", a.Status())
			if n == 8 {
				_ = macos.SetProxy(false, proxyHost(f), proxyPort(f), nil)
				a.notifyThrottled("Aster", "内核无响应", 5*time.Minute)
			}
		}
		return
	}
	snap, err := a.clash.Snapshot()
	if err != nil {
		return
	}
	observeConnections := a.hub.HasSubscribers("connections")
	observeProcesses := a.hub.HasSubscribers("process_traffic")
	observeTraffic := a.hub.HasSubscribers("traffic")
	observeLogs := a.hub.HasSubscribers("log")
	a.mu.Lock()
	a.failN = 0
	if a.lastUp > 0 || a.lastDown > 0 {
		up := snap.UploadTotal - a.lastUp
		down := snap.DownloadTotal - a.lastDown
		if up < 0 {
			up = 0
		}
		if down < 0 {
			down = 0
		}
		a.up, a.down = up, down
	} else {
		a.up, a.down = 0, 0
	}
	a.lastUp = snap.UploadTotal
	a.lastDown = snap.DownloadTotal
	up, down := a.up, a.down
	prev := a.prevIDs
	a.prevIDs = map[string]bool{}
	previousConnections := a.connections
	if observeConnections {
		a.connections = make(map[string]clash.Connection, len(snap.Connections))
	} else {
		a.connections = nil
	}
	for _, c := range snap.Connections {
		a.prevIDs[c.ID] = true
		if observeConnections {
			a.connections[c.ID] = c
		}
	}
	var delta ConnectionsDelta
	if observeConnections {
		delta = diffConnections(previousConnections, a.connections, snap.UploadTotal, snap.DownloadTotal)
	}
	// 3.1 真实流量被动伴随采样 (用户产生日常轻量流量时静默平滑取样，受设置项控制)
	// Bufferbloat 防护：若瞬时吞吐过高 (下行>6MB/s 或 上行>3MB/s)，TCP 队列膨胀会导致握手延迟严重失真，此时跳过被动采样
	isModerateTraffic := (down > 10240 || up > 5120) && down < 6*1024*1024 && up < 3*1024*1024
	shouldSample := f.Settings.PassiveSampling && isModerateTraffic && time.Since(a.lastPassive) >= 25*time.Second
	if shouldSample {
		a.lastPassive = time.Now()
	}
	a.mu.Unlock()

	if shouldSample {
		a.runBackground(ctx, &a.sampling, func() { a.passiveSamplePing(ctx) })
	}

	if observeProcesses {
		procs := a.UpdateProcessStats(snap.Connections)
		a.hub.Broadcast("process_traffic", procs)
	}

	ev := a.logs.UpsertSnapshot(snap, prev)
	if observeConnections && (len(delta.Upserts) > 0 || len(delta.Closed) > 0) {
		a.hub.Broadcast("connections", delta)
	}
	if observeTraffic {
		a.hub.Broadcast("traffic", map[string]int64{"up": up, "down": down})
	}
	if observeLogs {
		for _, e := range ev {
			a.hub.Broadcast("log", e)
		}
	}
}

func shouldAutoRestart(f state.File, needsAdmin bool, restartCount int, nextRestart, now time.Time) bool {
	return f.Wanted && !needsAdmin && restartCount < 5 && now.After(nextRestart)
}

func sameChains(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func diffConnections(previous, current map[string]clash.Connection, uploadTotal, downloadTotal int64) ConnectionsDelta {
	delta := ConnectionsDelta{UploadTotal: uploadTotal, DownloadTotal: downloadTotal}
	for id, connection := range current {
		old, existed := previous[id]
		if !existed || old.Upload != connection.Upload || old.Download != connection.Download || old.Rule != connection.Rule || old.Metadata != connection.Metadata || !sameChains(old.Chains, connection.Chains) {
			delta.Upserts = append(delta.Upserts, connection)
		}
	}
	for id := range previous {
		if _, exists := current[id]; !exists {
			delta.Closed = append(delta.Closed, id)
		}
	}
	return delta
}

// passiveSamplePing 真实流量被动伴随采样与 EMA 加权滤波算法
func (a *App) passiveSamplePing(ctx context.Context) {
	f := a.st.Get()
	if !a.core.Running() || !f.Wanted {
		return
	}
	targetTag := f.Selected
	if targetTag == "" || targetTag == "direct" {
		return
	}
	realTag := targetTag
	if targetTag != "auto" {
		for _, n := range a.Nodes() {
			if n.ID == targetTag {
				realTag = n.Tag
				break
			}
		}
	}
	targetURL := f.Settings.DelayURL
	if targetURL == "" {
		targetURL = "https://www.gstatic.com/generate_204"
	}
	// 1500ms 极短超时快速握手采样，杜绝开销
	d, err := a.clash.DelayContext(ctx, realTag, targetURL, 1500)
	if err != nil || d <= 0 {
		return
	}
	a.mu.Lock()
	oldD, exists := a.delays[realTag]
	var smoothD int
	if exists && oldD > 0 {
		sample := d
		// Outlier Clipping: 若突增超过基线的 2.5 倍且绝对差值超过 200ms，判定为瞬态网络抖动，进行限幅
		if sample > int(float64(oldD)*2.5) && sample-oldD > 200 {
			sample = oldD + int(float64(oldD)*0.5)
		}
		// EMA 加权滤波：70% 历史均值 + 30% 瞬间采样，平滑过渡消除毛刺
		smoothD = int(0.70*float64(oldD) + 0.30*float64(sample))
	} else {
		smoothD = d
	}
	a.delays[realTag] = smoothD
	if realTag == f.Selected || realTag == "auto" {
		a.delay = smoothD
	}
	a.mu.Unlock()

	a.hub.Broadcast("node_delay", map[string]any{"tag": realTag, "delay": smoothD})
	a.hub.Broadcast("status", a.Status())
}

func (a *App) writeConfig(f state.File) error {
	b, err := render.Config(f, a.st.Dir())
	if err != nil {
		return err
	}
	return os.WriteFile(a.st.ConfigPath(), b, 0o600)
}

func (a *App) apply(f state.File, restart bool) error {
	startedAt := time.Now()
	a.mu.Lock()
	a.pending = true
	a.lastErr = ""
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		a.pending = false
		a.mu.Unlock()
		a.hub.Broadcast("status", a.Status())
	}()
	if err := a.writeConfig(f); err != nil {
		a.setErr(err, time.Since(startedAt))
		return err
	}
	a.clash.SetSecret(f.ClashSecret)
	a.clash.SetPort(f.Settings.ClashPort)
	if err := a.checkPorts(f); err != nil {
		a.setErr(err, time.Since(startedAt))
		return err
	}
	coreFile := f
	if p := f.ActiveProfile(); p != nil && p.Kind == state.ProfileKindSubscription {
		// Complete profiles own their TUN inbound.  The manager only needs this
		// derived bit to choose the administrator-authorized launch path.
		coreFile.Capture.Tun = render.SupportsTun(f)
	}
	if err := a.core.Apply(coreFile, restart); err != nil {
		a.setErr(err, time.Since(startedAt))
		if coreFile.Capture.Tun {
			a.mu.Lock()
			a.tunFail = true
			a.needAdm = true
			a.mu.Unlock()
		}
		return err
	} else {
		a.mu.Lock()
		a.tunFail = false
		a.needAdm = false
		a.started = time.Now()
		a.failN = 0
		a.mu.Unlock()
	}
	if p := f.ActiveProfile(); p != nil && p.Kind == state.ProfileKindSubscription && f.Wanted {
		if err := a.waitForStableCore(); err != nil {
			_ = a.core.Stop()
			a.setErr(err, time.Since(startedAt))
			return err
		}
	}
	proxyAllowed := true
	if p := f.ActiveProfile(); p != nil && p.Kind == state.ProfileKindSubscription {
		proxyAllowed = render.SupportsSystemProxy(f)
	}
	if f.Wanted && f.Capture.SystemProxy && proxyAllowed {
		if err := macos.SetProxy(true, proxyHost(f), proxyPort(f), f.Settings.ProxyBypass); err != nil {
			a.setErr(err, time.Since(startedAt))
		}
	} else {
		_ = macos.SetProxy(false, proxyHost(f), proxyPort(f), nil)
	}
	if f.Wanted {
		if p := f.ActiveProfile(); p != nil && p.Kind == state.ProfileKindSubscription {
			return nil
		}
		deadline := time.Now().Add(8 * time.Second)
		healthy := false
		for time.Now().Before(deadline) {
			if a.clash.Healthy() {
				_ = a.clash.PatchMode(clashMode(f.Mode))
				if f.Selected != "" {
					_ = a.clash.Select("proxy", f.Selected)
				}
				healthy = true
				break
			}
			time.Sleep(200 * time.Millisecond)
		}
		if !healthy {
			_ = a.core.Stop()
			err := fmt.Errorf("核心启动后未在 8 秒内通过控制接口健康检查")
			a.setErr(err, time.Since(startedAt))
			return err
		}
	}
	_, _ = a.st.Update(func(cur *state.File) error {
		cur.Runtime.LastSuccessfulConfigID = f.ActiveConfigID
		cur.Runtime.LastSuccessfulAt = time.Now().Unix()
		cur.Runtime.LastFailure = ""
		appendRunEvent(&cur.Runtime, state.RunEvent{At: time.Now().Unix(), ConfigID: f.ActiveConfigID, Outcome: "started", Category: "lifecycle", DurationMs: time.Since(startedAt).Milliseconds()})
		return nil
	})
	return nil
}

// waitForStableCore is the health check available for a strict read-only
// imported profile: its Clash API is not owned by Aster, so process liveness
// is the only capability that can be safely observed. Requiring the process to
// survive a short observation window catches immediate startup failures before
// system proxy state or the active profile is committed.
func (a *App) waitForStableCore() error {
	deadline := time.Now().Add(600 * time.Millisecond)
	for {
		if !a.core.Running() {
			if detail := a.core.LastError(); detail != "" {
				return fmt.Errorf("完整配置核心启动失败: %s", detail)
			}
			return fmt.Errorf("完整配置核心在启动后立即退出")
		}
		if time.Now().After(deadline) {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func clashMode(mode string) string {
	switch mode {
	case "global":
		return "Global"
	case "direct":
		return "Direct"
	default:
		return "Rule"
	}
}

func (a *App) setErr(err error, elapsed time.Duration) {
	a.mu.Lock()
	a.lastErr = err.Error()
	a.mu.Unlock()
	_, _ = a.st.Update(func(cur *state.File) error {
		cur.Runtime.LastFailure = err.Error()
		appendRunEvent(&cur.Runtime, state.RunEvent{At: time.Now().Unix(), ConfigID: cur.ActiveConfigID, Outcome: "failed", Category: failureCategory(err), DurationMs: elapsed.Milliseconds(), Reason: err.Error()})
		return nil
	})
}

func failureCategory(err error) string {
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "管理员"), strings.Contains(message, "permission"), strings.Contains(message, "authorization"):
		return "authorization"
	case strings.Contains(message, "端口"), strings.Contains(message, "address already in use"):
		return "port_conflict"
	case strings.Contains(message, "校验"), strings.Contains(message, "配置"):
		return "validation"
	case strings.Contains(message, "健康"), strings.Contains(message, "无响应"):
		return "health"
	default:
		return "runtime"
	}
}

func appendRunEvent(runtime *state.RuntimeState, event state.RunEvent) {
	if n := len(runtime.History); n > 0 {
		last := runtime.History[n-1]
		if last.ConfigID == event.ConfigID && last.Outcome == event.Outcome && last.Reason == event.Reason && event.At-last.At < 30 {
			return
		}
	}
	runtime.History = append(runtime.History, event)
	if len(runtime.History) > 50 {
		runtime.History = append([]state.RunEvent(nil), runtime.History[len(runtime.History)-50:]...)
	}
}

func (a *App) hasEnabledNodes(f state.File) bool {
	for _, n := range render.Merge(f) {
		if !n.Disabled {
			return true
		}
	}
	return false
}

func (a *App) checkPorts(f state.File) error {
	if !f.Wanted {
		return nil
	}
	if p := f.ActiveProfile(); p != nil && p.Kind == state.ProfileKindSubscription {
		return nil
	}
	if a.core.Running() {
		return nil
	}
	port := f.Settings.MixedPort
	if port == 0 {
		port = 2080
	}
	clashPort := f.Settings.ClashPort
	if clashPort == 0 {
		clashPort = 2090
	}
	if busyWithRetry("127.0.0.1:"+strconv.Itoa(port), 500*time.Millisecond) {
		return fmt.Errorf("混合端口 %d 已被占用", port)
	}
	if busyWithRetry("127.0.0.1:"+strconv.Itoa(clashPort), 500*time.Millisecond) {
		return fmt.Errorf("控制接口 %d 已被占用", clashPort)
	}
	return nil
}

func busy(addr string) bool {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return true
	}
	_ = ln.Close()
	return false
}

func busyWithRetry(addr string, maxWait time.Duration) bool {
	deadline := time.Now().Add(maxWait)
	for {
		ln, err := net.Listen("tcp", addr)
		if err == nil {
			_ = ln.Close()
			return false
		}
		if time.Now().After(deadline) {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func mustExe() string {
	p, err := os.Executable()
	if err != nil {
		return "aster-daemon"
	}
	return p
}

func TryListen() (net.Listener, error) {
	return net.Listen("tcp", DefaultListenAddr)
}

func countryToFlag(code string) string {
	if len(code) != 2 {
		return "🌐"
	}
	code = strings.ToUpper(code)
	if code[0] < 'A' || code[0] > 'Z' || code[1] < 'A' || code[1] > 'Z' {
		return "🌐"
	}
	r1 := rune(code[0]) - 'A' + 0x1F1E6
	r2 := rune(code[1]) - 'A' + 0x1F1E6
	return string([]rune{r1, r2})
}

func (a *App) GetIPInfo(force bool) DualIPInfo {
	a.ipMu.Lock()
	if !force && time.Since(a.cachedAt) < 15*time.Second && a.cachedDual.LocalIP.IP != "" && a.cachedDual.LocalIP.IP != "检测中..." {
		res := a.cachedDual
		a.ipMu.Unlock()
		return res
	}
	a.ipMu.Unlock()

	// IP probing only needs the active profile's network settings and avoids
	// copying inactive subscriptions or full imported configurations.
	f := a.st.Active()
	port := f.Settings.MixedPort
	if port == 0 {
		port = 2080
	}

	dual := DualIPInfo{
		LocalIP: IPInfo{
			IP:        "检测中...",
			Country:   "未知",
			City:      "",
			ISP:       "",
			FetchedAt: time.Now().Unix(),
		},
		ProxyIP: IPInfo{
			IP:        "待连接",
			Country:   "直连模式",
			City:      "",
			ISP:       "",
			FetchedAt: time.Now().Unix(),
		},
		Protected: false,
		FetchedAt: time.Now().Unix(),
	}

	fetchOne := func(useProxy bool) IPInfo {
		tr := &http.Transport{}
		defer tr.CloseIdleConnections()
		if useProxy {
			if proxyURL, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port)); err == nil {
				tr.Proxy = http.ProxyURL(proxyURL)
			}
		}

		// 策略：直连本机优先探测国内高可用源 (Bilibili/百度)，代理节点优先探测境外多语言源 (ip-api)
		queryBili := func() *IPInfo {
			client := &http.Client{Transport: tr, Timeout: 1800 * time.Millisecond}
			resp, err := client.Get("https://api.bilibili.com/x/web-interface/zone")
			if err != nil {
				return nil
			}
			if resp.StatusCode != http.StatusOK {
				_ = resp.Body.Close()
				return nil
			}
			defer resp.Body.Close()
			var bili struct {
				Code int `json:"code"`
				Data struct {
					Addr     string `json:"addr"`
					Country  string `json:"country"`
					Province string `json:"province"`
					City     string `json:"city"`
					ISP      string `json:"isp"`
				} `json:"data"`
			}
			if err := json.NewDecoder(resp.Body).Decode(&bili); err == nil && bili.Code == 0 && bili.Data.Addr != "" {
				flag := "🇨🇳"
				if bili.Data.Country != "中国" {
					flag = "🌐"
				}
				loc := bili.Data.Province
				if bili.Data.City != "" && bili.Data.City != bili.Data.Province {
					loc = fmt.Sprintf("%s %s", loc, bili.Data.City)
				}
				return &IPInfo{
					IP:        bili.Data.Addr,
					Country:   fmt.Sprintf("%s %s", flag, bili.Data.Country),
					City:      loc,
					ISP:       bili.Data.ISP,
					FetchedAt: time.Now().Unix(),
				}
			}
			return nil
		}

		queryIPAPI := func() *IPInfo {
			client := &http.Client{Transport: tr, Timeout: 2200 * time.Millisecond}
			resp, err := client.Get("http://ip-api.com/json/?lang=zh-CN")
			if err != nil {
				return nil
			}
			if resp.StatusCode != http.StatusOK {
				_ = resp.Body.Close()
				return nil
			}
			defer resp.Body.Close()
			var res struct {
				Status      string `json:"status"`
				Country     string `json:"country"`
				CountryCode string `json:"countryCode"`
				City        string `json:"city"`
				ISP         string `json:"isp"`
				Query       string `json:"query"`
			}
			if err := json.NewDecoder(resp.Body).Decode(&res); err == nil && res.Status == "success" && res.Query != "" {
				flag := countryToFlag(res.CountryCode)
				return &IPInfo{
					IP:        res.Query,
					Country:   fmt.Sprintf("%s %s", flag, res.Country),
					City:      res.City,
					ISP:       res.ISP,
					FetchedAt: time.Now().Unix(),
				}
			}
			return nil
		}

		queryIpify := func() *IPInfo {
			client := &http.Client{Transport: tr, Timeout: 2000 * time.Millisecond}
			resp, err := client.Get("https://api.ipify.org?format=json")
			if err != nil {
				return nil
			}
			if resp.StatusCode != http.StatusOK {
				_ = resp.Body.Close()
				return nil
			}
			defer resp.Body.Close()
			var ipObj struct {
				IP string `json:"ip"`
			}
			if err := json.NewDecoder(resp.Body).Decode(&ipObj); err == nil && ipObj.IP != "" {
				return &IPInfo{
					IP:        ipObj.IP,
					Country:   "🌐 已连接",
					City:      "",
					ISP:       "",
					FetchedAt: time.Now().Unix(),
				}
			}
			return nil
		}

		if !useProxy {
			if info := queryBili(); info != nil {
				return *info
			}
			if info := queryIPAPI(); info != nil {
				return *info
			}
			if info := queryIpify(); info != nil {
				return *info
			}
		} else {
			if info := queryIPAPI(); info != nil {
				return *info
			}
			if info := queryBili(); info != nil {
				return *info
			}
			if info := queryIpify(); info != nil {
				return *info
			}
		}

		return IPInfo{IP: "---", Country: "暂无出口代理", City: "", ISP: "", FetchedAt: time.Now().Unix()}
	}

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		dual.LocalIP = fetchOne(false)
	}()

	if a.core.Running() && f.Wanted && f.Mode != "direct" {
		wg.Add(1)
		go func() {
			defer wg.Done()
			dual.ProxyIP = fetchOne(true)
		}()
	}
	wg.Wait()

	if f.Mode == "direct" {
		dual.ProxyIP = IPInfo{
			IP:        "---",
			Country:   "直连模式 (不经代理)",
			City:      "",
			ISP:       "",
			FetchedAt: time.Now().Unix(),
		}
		dual.Protected = false
	} else if !a.core.Running() || !f.Wanted {
		dual.ProxyIP = IPInfo{
			IP:        "---",
			Country:   "未启用代理",
			City:      "",
			ISP:       "",
			FetchedAt: time.Now().Unix(),
		}
		dual.Protected = false
	} else if dual.ProxyIP.IP == "检测失败" || dual.ProxyIP.IP == "" || dual.ProxyIP.IP == "待连接" {
		dual.ProxyIP = IPInfo{
			IP:        "---",
			Country:   "暂无可用出口",
			City:      "",
			ISP:       "",
			FetchedAt: time.Now().Unix(),
		}
		dual.Protected = false
	} else if dual.ProxyIP.IP != "" && dual.ProxyIP.IP != "---" {
		if dual.LocalIP.IP != "" && dual.ProxyIP.IP != dual.LocalIP.IP {
			dual.Protected = true
		}
	}

	a.ipMu.Lock()
	if dual.LocalIP.IP != "检测中..." {
		a.cachedDual = dual
		a.cachedAt = time.Now()
	}
	a.ipMu.Unlock()
	return dual
}
