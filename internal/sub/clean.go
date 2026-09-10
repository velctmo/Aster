package sub

import (
	"regexp"
	"strings"

	"aster/internal/state"
)

var commonAdKeywords = []string{
	"剩余流量", "到期时间", "距离下次重置", "套餐到期", "官网", "官方网站",
	"最新网址", "客服", "群组", "tg群", "发布页", "备用", "请勿连接",
	"通知", "expire", "traffic", "reset", "bandwidth", "公告", "关注频道",
	"不支持", "请更换", "客户端：", "客户端:",
}

// IsAdOrInfoNode 识别机场常见的公告、流量提示或纯广告假节点
func IsAdOrInfoNode(name string) bool {
	lower := strings.ToLower(name)
	for _, kw := range commonAdKeywords {
		if strings.Contains(lower, kw) {
			return true
		}
	}
	return false
}

var (
	// 剔除常见的网址、群组或冗余后缀，如 " | 官网: xyz.com" 或 " - 最新网址: ..."
	reAdSuffix = regexp.MustCompile(`(?i)([\s\-\|]+(官网|网址|发布页|TG|群组|官方|地址)[\s:：].*)$`)
	// 规范化多余的空格与分隔符
	reMultipleSpaces = regexp.MustCompile(`\s{2,}`)
)

// CleanNodeName 净化节点名称，去除多余广告尾巴
func CleanNodeName(name string) string {
	name = strings.TrimSpace(name)
	name = reAdSuffix.ReplaceAllString(name, "")
	name = reMultipleSpaces.ReplaceAllString(name, " ")
	return strings.TrimSpace(name)
}

// CleanAndFilterNodes 统一对节点列表进行垃圾清洗、名称净化与正则排除过滤
func CleanAndFilterNodes(nodes []state.Node, exclude string) []state.Node {
	exclude = strings.TrimSpace(exclude)
	var re *regexp.Regexp
	if exclude != "" {
		re, _ = regexp.Compile(exclude)
	}

	out := make([]state.Node, 0, len(nodes))
	for _, n := range nodes {
		// 1. 过滤掉公告/假节点
		if IsAdOrInfoNode(n.Name) {
			continue
		}
		// 2. 正则排除匹配
		if re != nil && re.MatchString(n.Name) {
			continue
		}
		// 3. 净化节点名称
		n.Name = CleanNodeName(n.Name)
		out = append(out, n)
	}
	return out
}
