package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestClientIPFromRequestTrustsForwardedHeadersOnlyFromPrivatePeers 锁定
// 转发头信任边界:X-Real-IP/XFF 只在直连方是内网/回环地址(nginx 的 Docker
// bridge 形态)时采信;公网直连伪造头不得旋转限流键。
func TestClientIPFromRequestTrustsForwardedHeadersOnlyFromPrivatePeers(t *testing.T) {
	newReq := func(remoteAddr, realIP, xff string) *http.Request {
		r := httptest.NewRequest(http.MethodGet, "http://srv/api/songs", nil)
		r.RemoteAddr = remoteAddr
		if realIP != "" {
			r.Header.Set("X-Real-IP", realIP)
		}
		if xff != "" {
			r.Header.Set("X-Forwarded-For", xff)
		}
		return r
	}

	cases := []struct {
		name string
		req  *http.Request
		want string
	}{
		{"内网反代:采信 X-Real-IP", newReq("172.18.0.5:40000", "203.0.113.7", ""), "203.0.113.7"},
		{"内网反代:XFF 首段", newReq("192.168.1.2:40000", "", "198.51.100.9, 10.0.0.1"), "198.51.100.9"},
		{"回环直连:采信转发头", newReq("127.0.0.1:40000", "203.0.113.7", ""), "203.0.113.7"},
		{"公网直连:忽略伪造头,回退 RemoteAddr", newReq("203.0.113.99:40000", "1.2.3.4", ""), "203.0.113.99"},
		{"非法 RemoteAddr:忽略转发头", newReq("not-an-addr", "1.2.3.4", ""), "not-an-addr"},
		{"无转发头:回退 RemoteAddr", newReq("172.18.0.5:40000", "", ""), "172.18.0.5"},
	}
	for _, c := range cases {
		if got := clientIPFromRequest(c.req); got != c.want {
			t.Fatalf("%s: clientIPFromRequest = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestIsTrustedProxyIP(t *testing.T) {
	trusted := []string{
		"127.0.0.1", "10.0.0.5", "172.16.0.1", "172.31.255.255", "192.168.0.2",
		"::1", "fd00::5", "fe80::1",
	}
	for _, ip := range trusted {
		if !isTrustedProxyIP(ip) {
			t.Fatalf("%s 应为受信内网地址", ip)
		}
	}
	untrusted := []string{"203.0.113.10", "8.8.8.8", "2001:db8::1", "", "garbage"}
	for _, ip := range untrusted {
		if isTrustedProxyIP(ip) {
			t.Fatalf("%q 不应为受信内网地址", ip)
		}
	}
}

// TestRequireAppToken 锁定可选鉴权语义:未配置 token 时完全开放(向后兼容
// 边缘 mTLS 模型);配置后缺失/错误头 401,正确头放行。
func TestRequireAppToken(t *testing.T) {
	newServer := func(token string) *musicServer {
		s := &musicServer{config: AppConfig{AppToken: token}}
		s.limiter = newIPWindowLimiter(1000, 1<<62)
		return s
	}
	handler := func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }

	// 未配置:不要求头。
	open := newServer("")
	rec := httptest.NewRecorder()
	open.requireAppToken(handler)(rec, httptest.NewRequest(http.MethodGet, "/api/songs", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("未配置 token 时应放行, got %d", rec.Code)
	}

	// 配置后:缺头/错头 401,正确头 200。
	guarded := newServer("secret-token")
	for _, tc := range []struct {
		name   string
		header string
		want   int
	}{
		{"缺失", "", http.StatusUnauthorized},
		{"错误", "wrong", http.StatusUnauthorized},
		{"正确", "secret-token", http.StatusOK},
	} {
		r := httptest.NewRequest(http.MethodGet, "/api/songs", nil)
		if tc.header != "" {
			r.Header.Set("X-App-Token", tc.header)
		}
		rec := httptest.NewRecorder()
		guarded.requireAppToken(handler)(rec, r)
		if rec.Code != tc.want {
			t.Fatalf("%s: got %d, want %d", tc.name, rec.Code, tc.want)
		}
	}
}
