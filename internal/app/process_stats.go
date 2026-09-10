package app

import (
	"sort"
	"strings"
	"time"

	"aster/internal/clash"
)

// ProcessTrafficStat「进程与客户端」实时速率模型
type ProcessTrafficStat struct {
	Name        string `json:"name"`
	ProcessPath string `json:"processPath"`
	UpSpeed     int64  `json:"upSpeed"`
	DownSpeed   int64  `json:"downSpeed"`
	ConnCount   int    `json:"connCount"`
	TotalBytes  int64  `json:"totalBytes"`
}

type procHistory struct {
	lastUp   int64
	lastDown int64
	lastAt   time.Time
}

// UpdateProcessStats 在连接快照中聚合各应用进程的实时吞吐速率
func (a *App) UpdateProcessStats(conns []clash.Connection) []ProcessTrafficStat {
	a.processMu.Lock()
	defer a.processMu.Unlock()
	if a.processHist == nil {
		a.processHist = make(map[string]procHistory)
	}

	now := time.Now()
	procUploads := make(map[string]int64)
	procDownloads := make(map[string]int64)
	procCounts := make(map[string]int)
	procPaths := make(map[string]string)

	for _, c := range conns {
		name := strings.TrimSpace(c.Metadata.Process)
		if name == "" {
			if c.Metadata.ProcessPath != "" {
				parts := strings.Split(c.Metadata.ProcessPath, "/")
				name = parts[len(parts)-1]
			}
		}
		if name == "" {
			name = "系统网络服务"
		}
		name = cleanProcessName(name)

		procUploads[name] += c.Upload
		procDownloads[name] += c.Download
		procCounts[name]++
		if procPaths[name] == "" && c.Metadata.ProcessPath != "" {
			procPaths[name] = c.Metadata.ProcessPath
		}
	}

	var results []ProcessTrafficStat
	for name, upTotal := range procUploads {
		downTotal := procDownloads[name]
		hist, exists := a.processHist[name]

		var upSpeed, downSpeed int64
		if exists {
			elapsedSec := now.Sub(hist.lastAt).Seconds()
			if elapsedSec > 0.3 && elapsedSec < 10 {
				upDiff := upTotal - hist.lastUp
				downDiff := downTotal - hist.lastDown
				if upDiff > 0 {
					upSpeed = int64(float64(upDiff) / elapsedSec)
				}
				if downDiff > 0 {
					downSpeed = int64(float64(downDiff) / elapsedSec)
				}
			}
		}

		a.processHist[name] = procHistory{
			lastUp:   upTotal,
			lastDown: downTotal,
			lastAt:   now,
		}

		results = append(results, ProcessTrafficStat{
			Name:        name,
			ProcessPath: procPaths[name],
			UpSpeed:     upSpeed,
			DownSpeed:   downSpeed,
			ConnCount:   procCounts[name],
			TotalBytes:  upTotal + downTotal,
		})
	}

	// 按总瞬时速率降序排列，速率相同时按累计流量排序
	sort.Slice(results, func(i, j int) bool {
		speedI := results[i].UpSpeed + results[i].DownSpeed
		speedJ := results[j].UpSpeed + results[j].DownSpeed
		if speedI != speedJ {
			return speedI > speedJ
		}
		return results[i].TotalBytes > results[j].TotalBytes
	})

	if len(results) > 6 {
		results = results[:6]
	}

	// A process which no longer owns an active connection needs no baseline
	// for a future rate calculation. Removing it bounds history in long-lived
	// sessions that see many short-lived helper processes.
	for name := range a.processHist {
		if _, active := procUploads[name]; !active {
			delete(a.processHist, name)
		}
	}
	a.cachedProcs = append(a.cachedProcs[:0], results...)
	return append([]ProcessTrafficStat(nil), results...)
}

func cleanProcessName(raw string) string {
	raw = strings.TrimSuffix(raw, ".app")
	lower := strings.ToLower(raw)
	if strings.Contains(lower, "google chrome") {
		return "Google Chrome"
	}
	if strings.Contains(lower, "telegram") {
		return "Telegram Lite"
	}
	if strings.Contains(lower, "dingtalk") {
		return "钉钉"
	}
	if strings.Contains(lower, "chatgpt") {
		return "ChatGPT"
	}
	if strings.Contains(lower, "wechat") {
		return "微信"
	}
	return raw
}

// GetTopProcesses 获取当前速率 Top 5 活跃进程
func (a *App) GetTopProcesses() []ProcessTrafficStat {
	a.processMu.Lock()
	defer a.processMu.Unlock()
	if a.cachedProcs == nil {
		return []ProcessTrafficStat{}
	}
	return append([]ProcessTrafficStat(nil), a.cachedProcs...)
}
