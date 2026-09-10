package sub

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const maxSubscriptionBytes = 8 << 20

var fetchClient = &http.Client{Timeout: 20 * time.Second}

type FetchMeta struct {
	Name     string
	Upload   int64
	Download int64
	Total    int64
	Expire   int64
	Body     string
}

func Fetch(source string) (FetchMeta, error) {
	return FetchContext(context.Background(), source)
}

// FetchContext lets refresh workers stop promptly during daemon shutdown and
// shares keep-alive connections across profiles instead of allocating one
// transport per retry.
func FetchContext(ctx context.Context, source string) (FetchMeta, error) {
	source = strings.TrimSpace(source)
	if source == "" {
		return FetchMeta{}, fmt.Errorf("空地址")
	}
	if !strings.HasPrefix(source, "http://") && !strings.HasPrefix(source, "https://") {
		return FetchMeta{Body: source, Name: "本地订阅"}, nil
	}
	uas := []string{
		"ClashVerge/v1.7.7",
		"ClashMeta/1.18.0",
		"sing-box/1.14.0",
		"v2rayN/6.23",
		"clash.meta",
	}
	var last error
	for attempt, ua := range uas {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
		if err != nil {
			return FetchMeta{}, err
		}
		req.Header.Set("User-Agent", ua)
		resp, err := fetchClient.Do(req)
		if err != nil {
			last = err
			if ctx.Err() != nil {
				break
			}
			if attempt < len(uas)-1 {
				select {
				case <-ctx.Done():
					return FetchMeta{}, ctx.Err()
				case <-time.After(time.Duration(attempt+1) * 200 * time.Millisecond):
				}
			}
			continue
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, maxSubscriptionBytes+1))
		resp.Body.Close()
		if err != nil {
			last = err
			continue
		}
		if len(body) > maxSubscriptionBytes {
			last = fmt.Errorf("订阅内容超过 %d MB 限制", maxSubscriptionBytes>>20)
			break
		}
		if resp.StatusCode >= 400 {
			last = fmt.Errorf("HTTP %d", resp.StatusCode)
			if resp.StatusCode < 500 {
				break
			}
			if attempt < len(uas)-1 {
				select {
				case <-ctx.Done():
					return FetchMeta{}, ctx.Err()
				case <-time.After(time.Duration(attempt+1) * 200 * time.Millisecond):
				}
			}
			continue
		}
		meta := parseUserinfo(resp.Header.Get("subscription-userinfo"))
		meta.Name = extractSubName(resp, source)
		meta.Body = string(body)
		if strings.TrimSpace(meta.Body) != "" {
			return meta, nil
		}
	}
	if last == nil {
		last = fmt.Errorf("订阅为空")
	}
	return FetchMeta{}, last
}

func extractSubName(resp *http.Response, sourceURL string) string {
	// 1. Check profile-title / x-profile-title / subscription-title headers
	for _, header := range []string{"profile-title", "x-profile-title", "subscription-title"} {
		if val := strings.TrimSpace(resp.Header.Get(header)); val != "" {
			if decoded := decodeProfileTitle(val); decoded != "" {
				return cleanSubName(decoded)
			}
		}
	}

	// 2. Check Content-Disposition filename
	if cd := resp.Header.Get("content-disposition"); cd != "" {
		if filename := parseFilename(cd); filename != "" {
			return cleanSubName(filename)
		}
	}

	// 3. Fallback: Parse from URL domain or path
	if u, err := url.Parse(sourceURL); err == nil {
		host := u.Hostname()
		if host != "" {
			parts := strings.Split(host, ".")
			if len(parts) >= 2 {
				// e.g. "sub.mysub.com" -> "mysub.com" or "mysub"
				mainDomain := parts[len(parts)-2]
				if len(mainDomain) > 0 {
					return cleanSubName(strings.ToUpper(mainDomain[:1]) + mainDomain[1:])
				}
			}
			return cleanSubName(host)
		}
	}

	return "订阅"
}

func decodeProfileTitle(raw string) string {
	raw = strings.TrimSpace(raw)
	// Try URL decode
	if unescaped, err := url.QueryUnescape(raw); err == nil && unescaped != "" {
		raw = unescaped
	}
	// Try base64 decode if base64 encoded
	if b, err := base64.StdEncoding.DecodeString(raw); err == nil && len(b) > 0 {
		str := string(b)
		if strings.TrimSpace(str) != "" {
			return str
		}
	}
	return raw
}

func parseFilename(cd string) string {
	_, params, err := mime.ParseMediaType(cd)
	if err == nil {
		if fn, ok := params["filename*"]; ok && fn != "" {
			return fn
		}
		if fn, ok := params["filename"]; ok && fn != "" {
			return fn
		}
	}
	// Fallback simple search
	if idx := strings.Index(strings.ToLower(cd), "filename="); idx != -1 {
		sub := cd[idx+9:]
		sub = strings.Trim(sub, `"' `)
		if end := strings.IndexAny(sub, ";\r\n"); end != -1 {
			sub = sub[:end]
		}
		return strings.Trim(sub, `"' `)
	}
	return ""
}

func cleanSubName(name string) string {
	name = strings.TrimSpace(name)
	ext := filepath.Ext(name)
	if ext == ".yaml" || ext == ".yml" || ext == ".txt" || ext == ".json" || ext == ".conf" {
		name = strings.TrimSuffix(name, ext)
	}
	if name == "" {
		return "订阅"
	}
	return name
}

func parseUserinfo(h string) FetchMeta {
	var m FetchMeta
	for _, part := range strings.Split(h, ";") {
		part = strings.TrimSpace(part)
		kv := strings.SplitN(part, "=", 2)
		if len(kv) != 2 {
			continue
		}
		n, _ := strconv.ParseInt(strings.TrimSpace(kv[1]), 10, 64)
		switch strings.TrimSpace(kv[0]) {
		case "upload":
			m.Upload = n
		case "download":
			m.Download = n
		case "total":
			m.Total = n
		case "expire":
			m.Expire = n
		}
	}
	return m
}
