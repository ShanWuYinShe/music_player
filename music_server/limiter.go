package main

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// maxLimiterEntries 是限流表条目上限。走 Cloudflare 时 clientIP 是真实客户端
// IPv6,攻击者可用海量源地址制造新 key;惰性清理只删过期条目,新鲜攻击 IP
// 会让 entries 无界增长。超限后新 key 直接按限流拒绝(已有条目判定不受影响),
// 与 media_server 同款守卫(两仓实现按约定同步改)。
const maxLimiterEntries = 100000

// ipWindowLimiter 是固定窗口 per-IP 限流器(实现与 media_server 保持一致,
// 该子模块无法被 import,故按同构实现复制;改动两处时需同步)。
type ipWindowLimiter struct {
	limit   int
	window  time.Duration
	mu      sync.Mutex
	entries map[string]*ipWindow
}

type ipWindow struct {
	start time.Time
	count int
}

func newIPWindowLimiter(limit int, window time.Duration) *ipWindowLimiter {
	return &ipWindowLimiter{limit: limit, window: window, entries: make(map[string]*ipWindow)}
}

func (l *ipWindowLimiter) allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	w, ok := l.entries[key]
	if !ok || now.Sub(w.start) >= l.window {
		// 容量守卫:表满时先清理过期条目,仍满则拒绝新 key(不影响已有
		// 条目的判定),消除 IPv6 源地址旋转下的无界内存增长。
		if len(l.entries) >= maxLimiterEntries {
			for k, e := range l.entries {
				if now.Sub(e.start) >= l.window {
					delete(l.entries, k)
				}
			}
			if len(l.entries) >= maxLimiterEntries {
				return false
			}
		}
		l.entries[key] = &ipWindow{start: now, count: 1}
		return true
	}
	w.count++
	return w.count <= l.limit
}

// clientIPFromRequest 依次取 X-Real-IP、X-Forwarded-For 首段,
// 最后回退 RemoteAddr。转发头只在直连方是内网/回环地址(即 nginx 所在的
// Docker bridge)时才采信:若服务被直接暴露到公网,任意外部客户端伪造
// X-Real-IP 即可旋转限流键绕过 per-IP 限流——服务无鉴权时该绕过约等于
// 绕过全部防线。取值顺序与 media_server 保持一致。
func clientIPFromRequest(r *http.Request) string {
	remote := remoteIP(r.RemoteAddr)
	if ip := strings.TrimSpace(r.Header.Get("X-Real-IP")); ip != "" && isTrustedProxyIP(remote) {
		return ip
	}
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" && isTrustedProxyIP(remote) {
		if idx := strings.IndexByte(xff, ','); idx >= 0 {
			return strings.TrimSpace(xff[:idx])
		}
		return strings.TrimSpace(xff)
	}
	return remote
}

// remoteIP 从 RemoteAddr 取主机部分,解析失败原样返回。
func remoteIP(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	return host
}

// isTrustedProxyIP 判断直连方是否位于内网(Docker bridge 网段属于 RFC1918
// 私有区间)。公网直连时转发头一律不采信。
func isTrustedProxyIP(ipStr string) bool {
	ip := net.ParseIP(strings.TrimSpace(ipStr))
	if ip == nil {
		return false
	}
	if ip.IsLoopback() || ip.IsPrivate() {
		return true
	}
	// IPv6 ULA fc00::/7(IsPrivate 已覆盖)之外,链路本地 fe80::/10 也是
	// 容器间直连的常见形态。
	if ip.IsLinkLocalUnicast() {
		return true
	}
	return false
}
