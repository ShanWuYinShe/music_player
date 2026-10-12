package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// resetLoginSessions 清空全局扫码会话表,避免用例间串扰。
func resetLoginSessions() {
	neteaseLoginMu.Lock()
	neteaseLoginSessions = map[string]neteaseLoginSession{}
	neteaseLoginMu.Unlock()
}

// TestAdminNeteaseLoginFlow 扫码登录全流程:start 取 key/二维码并登记会话;
// poll 拿到 803 后把 MUSIC_U 原子写入 cookie 文件(权限 0600)并消费会话
// (二维码一次性,防 key 复用)。
func TestAdminNeteaseLoginFlow(t *testing.T) {
	resetLoginSessions()
	var checkCode atomic.Int64
	checkCode.Store(801)
	var checkCookie atomic.Value
	checkCookie.Store("")

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/login/qr/key":
			_, _ = w.Write([]byte(`{"data":{"unikey":"uni-abc"}}`))
		case "/login/qr/create":
			if got := r.URL.Query().Get("key"); got != "uni-abc" {
				t.Errorf("qr/create key = %q, want uni-abc", got)
			}
			_, _ = w.Write([]byte(`{"data":{"qrimg":"data:image/png;base64,AAA"}}`))
		case "/login/qr/check":
			_, _ = fmt.Fprintf(w, `{"code":%d,"message":"m","cookie":%q,"profile":{"nickname":"听歌的人"}}`,
				checkCode.Load(), checkCookie.Load().(string))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	cookiePath := filepath.Join(t.TempDir(), "netease-cookie.txt")
	server := newTestServer(t, mkLibrary(t))
	server.config.NeteaseCookieFile = cookiePath
	server.netease = newNeteaseClient(srv.URL, "", "")

	// 1) start:返回 key 与二维码
	rec := httptest.NewRecorder()
	server.handleAdminNeteaseStart(rec, httptest.NewRequest("GET", "/admin/api/v1/netease/login/start", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("start: status %d body %s", rec.Code, rec.Body.String())
	}
	var startResp struct {
		Key   string `json:"key"`
		QRImg string `json:"qrimg"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &startResp); err != nil {
		t.Fatalf("start decode: %v body %s", err, rec.Body.String())
	}
	if startResp.Key != "uni-abc" || startResp.QRImg == "" {
		t.Fatalf("start resp = %+v", startResp)
	}

	// 2) poll 待扫码(801):200 且不落凭证
	rec = httptest.NewRecorder()
	server.handleAdminNeteasePoll(rec, httptest.NewRequest("GET", "/x?key=uni-abc", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"code":801`) {
		t.Fatalf("poll 801: status %d body %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(cookiePath); !os.IsNotExist(err) {
		t.Fatal("cookie file must not exist before 803")
	}

	// 3) poll 扫码成功(803):写凭证,权限 0600,值经 URL 解码
	checkCode.Store(803)
	checkCookie.Store("MUSIC_U=tok%2Fen%3D; Path=/")
	rec = httptest.NewRecorder()
	server.handleAdminNeteasePoll(rec, httptest.NewRequest("GET", "/x?key=uni-abc", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"nickname":"听歌的人"`) {
		t.Fatalf("poll 803: status %d body %s", rec.Code, rec.Body.String())
	}
	data, err := os.ReadFile(cookiePath)
	if err != nil {
		t.Fatalf("cookie file: %v", err)
	}
	if string(data) != "MUSIC_U=tok/en=" {
		t.Fatalf("cookie content = %q, want MUSIC_U=tok/en=", string(data))
	}
	info, err := os.Stat(cookiePath)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("cookie perm = %o, want 600", perm)
	}

	// 4) 会话一次性:同一 key 再 poll → 410
	rec = httptest.NewRecorder()
	server.handleAdminNeteasePoll(rec, httptest.NewRequest("GET", "/x?key=uni-abc", nil))
	if rec.Code != http.StatusGone {
		t.Fatalf("reused key: status %d, want 410", rec.Code)
	}
}

// TestAdminNeteaseLoginGuards 登录端点前置守卫:上游未启用/未配 cookie 文件/
// 缺 key/未知 key 的错误码。
func TestAdminNeteaseLoginGuards(t *testing.T) {
	resetLoginSessions()
	// 上游未启用(netease 为 nil)→ 四个端点一律 503
	disabled := newTestServer(t, mkLibrary(t))
	disabled.config.NeteaseCookieFile = filepath.Join(t.TempDir(), "c.txt")
	for name, h := range map[string]http.HandlerFunc{
		"start":  disabled.handleAdminNeteaseStart,
		"poll":   disabled.handleAdminNeteasePoll,
		"state":  disabled.handleAdminNeteaseState,
		"logout": disabled.handleAdminNeteaseLogout,
	} {
		rec := httptest.NewRecorder()
		h(rec, httptest.NewRequest("GET", "/x", nil))
		if rec.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s with disabled upstream: status %d, want 503", name, rec.Code)
		}
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"unikey":"k"},"code":801}`))
	}))
	defer srv.Close()
	enabled := newTestServer(t, mkLibrary(t))
	enabled.netease = newNeteaseClient(srv.URL, "", "")

	// 已启用但未配置 cookie 文件 → poll/logout 503
	enabled.config.NeteaseCookieFile = ""
	rec := httptest.NewRecorder()
	enabled.handleAdminNeteasePoll(rec, httptest.NewRequest("GET", "/x?key=k", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("poll without cookie file: status %d, want 503", rec.Code)
	}
	rec = httptest.NewRecorder()
	enabled.handleAdminNeteaseLogout(rec, httptest.NewRequest("POST", "/x", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("logout without cookie file: status %d, want 503", rec.Code)
	}

	// poll 缺 key → 400;未知 key → 410
	enabled.config.NeteaseCookieFile = filepath.Join(t.TempDir(), "c.txt")
	rec = httptest.NewRecorder()
	enabled.handleAdminNeteasePoll(rec, httptest.NewRequest("GET", "/x", nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("poll without key: status %d, want 400", rec.Code)
	}
	rec = httptest.NewRecorder()
	enabled.handleAdminNeteasePoll(rec, httptest.NewRequest("GET", "/x?key=nope", nil))
	if rec.Code != http.StatusGone {
		t.Fatalf("poll unknown key: status %d, want 410", rec.Code)
	}
}

// TestAdminNeteaseLoginUpstreamErrors 上游异常的错误码与"不写坏凭证"保证。
func TestAdminNeteaseLoginUpstreamErrors(t *testing.T) {
	resetLoginSessions()
	var mode atomic.Value
	mode.Store("empty-key")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch mode.Load().(string) {
		case "empty-key":
			_, _ = w.Write([]byte(`{"data":{"unikey":""}}`))
		case "empty-qr":
			if r.URL.Path == "/login/qr/key" {
				_, _ = w.Write([]byte(`{"data":{"unikey":"k1"}}`))
				return
			}
			_, _ = w.Write([]byte(`{"data":{"qrimg":""}}`))
		default: // 803 但 cookie 里没有 MUSIC_U
			_, _ = w.Write([]byte(`{"code":803,"cookie":"OTHER=x"}`))
		}
	}))
	defer srv.Close()

	cookiePath := filepath.Join(t.TempDir(), "c.txt")
	server := newTestServer(t, mkLibrary(t))
	server.netease = newNeteaseClient(srv.URL, "", "")
	server.config.NeteaseCookieFile = cookiePath

	rec := httptest.NewRecorder()
	server.handleAdminNeteaseStart(rec, httptest.NewRequest("GET", "/x", nil))
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("empty unikey: status %d, want 502", rec.Code)
	}

	mode.Store("empty-qr")
	rec = httptest.NewRecorder()
	server.handleAdminNeteaseStart(rec, httptest.NewRequest("GET", "/x", nil))
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("empty qrimg: status %d, want 502", rec.Code)
	}

	mode.Store("803-no-musicu")
	neteaseLoginMu.Lock()
	neteaseLoginSessions = map[string]neteaseLoginSession{"k9": {QRImg: "x", CreatedAt: time.Now()}}
	neteaseLoginMu.Unlock()
	rec = httptest.NewRecorder()
	server.handleAdminNeteasePoll(rec, httptest.NewRequest("GET", "/x?key=k9", nil))
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("803 without MUSIC_U: status %d, want 502", rec.Code)
	}
	if _, err := os.Stat(cookiePath); !os.IsNotExist(err) {
		t.Fatal("must not write a credential file when MUSIC_U is missing")
	}
}

// TestAdminNeteaseStateAndLogout 登录态查询与登出:文件存在即 loggedIn 并带
// 上游昵称;登出删文件且幂等(文件已不存在仍返回 ok)。
func TestAdminNeteaseStateAndLogout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/login/status" {
			_, _ = w.Write([]byte(`{"profile":{"nickname":"某用户"}}`))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()
	cookiePath := filepath.Join(t.TempDir(), "netease-cookie.txt")
	server := newTestServer(t, mkLibrary(t))
	server.netease = newNeteaseClient(srv.URL, "", "")
	server.config.NeteaseCookieFile = cookiePath

	// 未登录(文件不存在)→ loggedIn:false
	rec := httptest.NewRecorder()
	server.handleAdminNeteaseState(rec, httptest.NewRequest("GET", "/x", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"loggedIn":false`) {
		t.Fatalf("state before login: status %d body %s", rec.Code, rec.Body.String())
	}

	// 写入凭证 → loggedIn:true 且带昵称
	if err := os.WriteFile(cookiePath, []byte("MUSIC_U=z"), 0o600); err != nil {
		t.Fatal(err)
	}
	rec = httptest.NewRecorder()
	server.handleAdminNeteaseState(rec, httptest.NewRequest("GET", "/x", nil))
	body := rec.Body.String()
	if rec.Code != http.StatusOK || !strings.Contains(body, `"loggedIn":true`) ||
		!strings.Contains(body, `"nickname":"某用户"`) {
		t.Fatalf("state after login: status %d body %s", rec.Code, body)
	}

	// 登出 → 文件删除;再次登出幂等
	rec = httptest.NewRecorder()
	server.handleAdminNeteaseLogout(rec, httptest.NewRequest("POST", "/x", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("logout: status %d body %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(cookiePath); !os.IsNotExist(err) {
		t.Fatal("cookie file should be removed after logout")
	}
	rec = httptest.NewRecorder()
	server.handleAdminNeteaseLogout(rec, httptest.NewRequest("POST", "/x", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("logout idempotent: status %d", rec.Code)
	}
}

// TestCleanupExpiredChunkUploads 孤儿分片清理:超过 TTL 的会话目录删除,
// 未过期保留,非法目录名(非 hex64)不动。
func TestCleanupExpiredChunkUploads(t *testing.T) {
	old := uploadChunksDir
	uploadChunksDir = t.TempDir()
	defer func() { uploadChunksDir = old }()

	expired := strings.Repeat("ab", 32)
	fresh := strings.Repeat("cd", 32)
	mk := func(name string, age time.Duration) string {
		path := filepath.Join(uploadChunksDir, name)
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
		ts := time.Now().Add(-age)
		if err := os.Chtimes(path, ts, ts); err != nil {
			t.Fatal(err)
		}
		return path
	}
	expiredPath := mk(expired, musicChunkTTL+time.Hour)
	freshPath := mk(fresh, time.Minute)
	junkPath := mk("not-an-upload-id", musicChunkTTL+time.Hour)

	cleanupExpiredChunkUploads()

	if _, err := os.Stat(expiredPath); !os.IsNotExist(err) {
		t.Fatal("expired session dir should be removed")
	}
	if _, err := os.Stat(freshPath); err != nil {
		t.Fatalf("fresh session dir must be kept: %v", err)
	}
	if _, err := os.Stat(junkPath); err != nil {
		t.Fatalf("non-hex dir must be kept: %v", err)
	}
}

// TestAdminTokenEnabled 管理令牌开关。
func TestAdminTokenEnabled(t *testing.T) {
	server := newTestServer(t, mkLibrary(t))
	if server.adminTokenEnabled() {
		t.Fatal("adminTokenEnabled() = true without token")
	}
	server.config.AdminToken = "s3cret"
	if !server.adminTokenEnabled() {
		t.Fatal("adminTokenEnabled() = false with token")
	}
}
