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
// 最后回退 RemoteAddr。生产流量经 nginx(覆写 X-Real-IP),与 media_server
// 的取值顺序完全一致;仅用于限流统计,不做任何鉴权判断。
func clientIPFromRequest(r *http.Request) string {
	if ip := strings.TrimSpace(r.Header.Get("X-Real-IP")); ip != "" {
		return ip
	}
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if idx := strings.IndexByte(xff, ','); idx >= 0 {
			return strings.TrimSpace(xff[:idx])
		}
		return strings.TrimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
