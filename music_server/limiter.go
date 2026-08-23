package main

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

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
		l.entries[key] = &ipWindow{start: now, count: 1}
		// 惰性清理过期条目,防止长期运行下 map 无限增长。
		if len(l.entries) > 1024 {
			for k, e := range l.entries {
				if now.Sub(e.start) >= l.window {
					delete(l.entries, k)
				}
			}
		}
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
