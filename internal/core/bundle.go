package core

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"debug/macho"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const githubAPI = "https://api.github.com/repos/SagerNet/sing-box/releases"

var downloadMirrors = []string{
	"", // direct
	"https://ghproxy.net/",
	"https://ghfast.top/",
}

type CoreInfo struct {
	Ready   bool   `json:"ready"`
	Path    string `json:"path"`
	Version string `json:"version"`
	Arch    string `json:"arch"`
}

type Release struct {
	Tag        string `json:"tag"`
	Name       string `json:"name"`
	Prerelease bool   `json:"prerelease"`
	Asset      string `json:"asset"`
}

type ghRelease struct {
	TagName    string `json:"tag_name"`
	Name       string `json:"name"`
	Prerelease bool   `json:"prerelease"`
	Assets     []struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
	} `json:"assets"`
}

func darwinAssetSuffix() string {
	return "darwin-arm64.tar.gz"
}

func MirrorURL(raw, prefix string) string {
	if prefix == "" {
		return raw
	}
	return prefix + raw
}

func MatchDarwinAsset(name, arch string) bool {
	if arch != "" && arch != "arm64" {
		return false
	}
	return strings.HasSuffix(name, "darwin-arm64.tar.gz") && strings.HasPrefix(name, "sing-box-")
}

func Info(configured string) CoreInfo {
	arch := "arm64"
	bin, err := FindBinary(configured)
	if err != nil {
		return CoreInfo{Ready: false, Arch: arch}
	}
	return CoreInfo{
		Ready:   true,
		Path:    bin,
		Version: Version(configured),
		Arch:    arch,
	}
}

func httpGet(url string, timeout time.Duration) (*http.Response, error) {
	client := &http.Client{Timeout: timeout}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "aster-core-manager")
	req.Header.Set("Accept", "application/vnd.github+json")
	return client.Do(req)
}

func getJSON(urls []string, dest any) error {
	var last error
	for _, u := range urls {
		resp, err := httpGet(u, 20*time.Second)
		if err != nil {
			last = err
			continue
		}
		func() {
			defer resp.Body.Close()
			if resp.StatusCode != 200 {
				last = fmt.Errorf("%s: HTTP %d", u, resp.StatusCode)
				return
			}
			last = json.NewDecoder(resp.Body).Decode(dest)
		}()
		if last == nil {
			return nil
		}
	}
	if last == nil {
		last = fmt.Errorf("无法获取版本列表")
	}
	return last
}

func ListReleases() ([]Release, error) {
	urls := make([]string, 0, len(downloadMirrors))
	for _, m := range downloadMirrors {
		urls = append(urls, MirrorURL(githubAPI+"?per_page=15", m))
	}
	var raw []ghRelease
	if err := getJSON(urls, &raw); err != nil {
		return nil, fmt.Errorf("无法获取 GitHub 版本列表: %w", err)
	}
	suffix := darwinAssetSuffix()
	var out []Release
	for _, r := range raw {
		if r.Prerelease {
			continue
		}
		asset := ""
		for _, a := range r.Assets {
			if strings.HasSuffix(a.Name, suffix) && strings.HasPrefix(a.Name, "sing-box-") {
				asset = a.Name
				break
			}
		}
		if asset == "" {
			continue
		}
		name := r.Name
		if name == "" {
			name = r.TagName
		}
		out = append(out, Release{Tag: r.TagName, Name: name, Asset: asset})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("没有适合当前系统的内核版本")
	}
	return out, nil
}

// Download obtains a release selected by the caller. expectedSHA256 must be
// acquired from a trusted release manifest independently of the download URL;
// GitHub release metadata and download mirrors are not a trust anchor.
func Download(tag, expectedSHA256, coresDir string) (string, error) {
	expectedSHA256, err := normalizeSHA256(expectedSHA256)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(coresDir, 0o700); err != nil {
		return "", err
	}
	releases, err := ListReleases()
	if err != nil {
		return "", err
	}
	var rel *Release
	if tag == "" {
		rel = &releases[0]
	} else {
		for i := range releases {
			if releases[i].Tag == tag {
				rel = &releases[i]
				break
			}
		}
	}
	if rel == nil {
		return "", fmt.Errorf("找不到版本 %s", tag)
	}
	assetURL := fmt.Sprintf("https://github.com/SagerNet/sing-box/releases/download/%s/%s", rel.Tag, rel.Asset)
	tmp, err := os.CreateTemp("", "aster-singbox-*.tar.gz")
	if err != nil {
		return "", err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)

	var last error
	ok := false
	for _, m := range downloadMirrors {
		u := MirrorURL(assetURL, m)
		if err := downloadFile(u, tmp); err != nil {
			last = err
			_, _ = tmp.Seek(0, 0)
			_ = tmp.Truncate(0)
			continue
		}
		ok = true
		break
	}
	_ = tmp.Close()
	if !ok {
		if last == nil {
			last = fmt.Errorf("下载失败")
		}
		return "", fmt.Errorf("内核下载失败: %w", last)
	}

	binData, err := extractSingBox(tmpPath)
	if err != nil {
		return "", err
	}
	if err := verifySHA256(binData, expectedSHA256); err != nil {
		return "", fmt.Errorf("下载的内核完整性校验失败: %w", err)
	}
	ver := strings.TrimPrefix(rel.Tag, "v")
	dest := filepath.Join(coresDir, fmt.Sprintf("sing-box-%s-darwin-arm64", ver))
	if err := os.WriteFile(dest, binData, 0o755); err != nil {
		return "", err
	}
	if err := verifyBinary(dest); err != nil {
		_ = os.Remove(dest)
		return "", err
	}
	return dest, nil
}

func normalizeSHA256(expected string) (string, error) {
	expected = strings.ToLower(strings.TrimSpace(expected))
	if len(expected) != sha256.Size*2 {
		return "", fmt.Errorf("必须提供 64 位十六进制 SHA-256 校验值")
	}
	if _, err := hex.DecodeString(expected); err != nil {
		return "", fmt.Errorf("SHA-256 校验值格式无效")
	}
	return expected, nil
}

func verifySHA256(data []byte, expected string) error {
	actual := sha256.Sum256(data)
	if hex.EncodeToString(actual[:]) != expected {
		return fmt.Errorf("SHA-256 不匹配")
	}
	return nil
}

func downloadFile(url string, dest *os.File) error {
	resp, err := httpGet(url, 3*time.Minute)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
	}
	_, err = io.Copy(dest, resp.Body)
	return err
}

func extractSingBox(tarGz string) ([]byte, error) {
	f, err := os.Open(tarGz)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return nil, fmt.Errorf("不是有效的 gzip: %w", err)
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		name := filepath.Base(h.Name)
		if name == "sing-box" && h.Typeflag == tar.TypeReg {
			return io.ReadAll(tr)
		}
	}
	return nil, fmt.Errorf("压缩包里没有 sing-box 可执行文件")
}

func Import(r io.Reader, coresDir string) (string, error) {
	if err := os.MkdirAll(coresDir, 0o700); err != nil {
		return "", err
	}
	data, err := io.ReadAll(r)
	if err != nil {
		return "", err
	}
	id := fmt.Sprintf("%d", time.Now().UnixNano())
	dest := filepath.Join(coresDir, "sing-box-imported-"+id)
	if err := os.WriteFile(dest, data, 0o755); err != nil {
		return "", err
	}
	if err := verifyBinary(dest); err != nil {
		_ = os.Remove(dest)
		return "", err
	}
	return dest, nil
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

func verifyBinary(path string) error {
	if !isArm64Binary(path) {
		return fmt.Errorf("内核不是有效的 macOS ARM64 (Apple Silicon) 二进制文件")
	}
	out, err := exec.Command(path, "version").CombinedOutput()
	if err != nil {
		return fmt.Errorf("无法识别为 sing-box: %s", strings.TrimSpace(string(out)))
	}
	if !strings.Contains(strings.ToLower(string(out)), "sing-box") {
		return fmt.Errorf("无法识别为 sing-box")
	}
	return nil
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
