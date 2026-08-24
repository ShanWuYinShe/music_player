package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// decodeJSONBody 反序列化响应体(测试专用小工具)。
func decodeJSONBody(t *testing.T, body string, out any) error {
	t.Helper()
	return json.Unmarshal([]byte(body), out)
}

// fakeNetease 起一个假 NeteaseCloudMusicApi 上游,覆盖搜索/解析/音频三段。
type fakeNetease struct {
	api    *httptest.Server // /cloudsearch 与 /song/url/v1
	audio  *httptest.Server // 模拟 CDN 音频文件
	search func(w http.ResponseWriter, r *http.Request)
}

func newFakeNetease(t *testing.T) *fakeNetease {
	t.Helper()
	f := &fakeNetease{}
	f.audio = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 模拟 CDN:支持 Range,回 Content-Range/Accept-Ranges。
		body := "0123456789abcdef"
		if rng := r.Header.Get("Range"); rng != "" {
			w.Header().Set("Content-Range", "bytes "+strings.TrimPrefix(rng, "bytes=")+"/16")
			w.Header().Set("Content-Type", "audio/mpeg")
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write([]byte(body[4:8]))
			return
		}
		w.Header().Set("Content-Type", "audio/mpeg")
		w.Header().Set("Content-Length", "16")
		_, _ = w.Write([]byte(body))
	}))
	f.api = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if f.search != nil {
			f.search(w, r)
			return
		}
		switch r.URL.Path {
		case "/cloudsearch":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"result":{"songs":[` +
				`{"id":167855,"name":"有何不可","artists":[{"name":"许嵩"}],"album":{"name":"自定义"},"duration":240000},` +
				`{"id":186016,"name":"晴天","artists":[{"name":"周杰伦"}],"album":{"name":"叶惠美"},"duration":269000}]}}`))
		case "/song/url/v1":
			id := r.URL.Query().Get("id")
			w.Header().Set("Content-Type", "application/json")
			if id == "167855" {
				_, _ = w.Write([]byte(`{"data":[{"url":"` + f.audio.URL + `/audio.mp3","code":200}]}`))
			} else {
				_, _ = w.Write([]byte(`{"data":[{"url":null,"code":404}]}`))
			}
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(f.api.Close)
	t.Cleanup(f.audio.Close)
	return f
}

func newTestServerWithNetease(t *testing.T, upstream string) *musicServer {
	t.Helper()
	server := newTestServer(t, mkLibrary(t))
	server.netease = newNeteaseClient(upstream, "", "")
	return server
}

// 搜索聚合:本地匹配在前,网易结果追加,source 字段标识来源。
func TestNeteaseSearchMerged(t *testing.T) {
	f := newFakeNetease(t)
	server := newTestServerWithNetease(t, f.api.URL)

	rec := httptest.NewRecorder()
	server.handleSongs(rec, httptest.NewRequest("GET", "/api/songs?q=晴天", nil))
	var resp struct {
		Total int    `json:"total"`
		Songs []Song `json:"songs"`
	}
	if err := decodeJSONBody(t, rec.Body.String(), &resp); err != nil {
		t.Fatal(err)
	}
	// 本地无匹配,假上游固定返回 2 条(不按 keywords 过滤)。
	if resp.Total != 2 {
		t.Fatalf("expect 2 netease songs, got %d", resp.Total)
	}
	byID := map[string]Song{}
	for _, s := range resp.Songs {
		byID[s.ID] = s
	}
	got, ok := byID["ne_186016"]
	if !ok || got.Source != "netease" {
		t.Fatalf("unexpected netease entry: %+v", resp.Songs)
	}
	if got.DurationMs != 269000 || got.Artist != "周杰伦" || got.Album != "叶惠美" {
		t.Fatalf("unexpected metadata: %+v", got)
	}

	// 命中本地 + 追加网络:q 同时匹配本地与上游。
	rec = httptest.NewRecorder()
	server.handleSongs(rec, httptest.NewRequest("GET", "/api/songs?q=晨光", nil))
	resp = struct {
		Total int    `json:"total"`
		Songs []Song `json:"songs"`
	}{} // 重置:Unmarshal 到旧 slice 时 omitempty 缺失字段会保留上次的值
	if err := decodeJSONBody(t, rec.Body.String(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Total != 3 { // 本地 1(晨光旋律) + 网易 2(假上游固定返回两条)
		t.Fatalf("expect local+netease merged, got %d", resp.Total)
	}
	if resp.Songs[0].Source != "" || resp.Songs[1].Source != "netease" {
		t.Fatalf("local first then netease: %+v", resp.Songs)
	}
}

// 上游失败降级:网络源错误不影响本地搜索结果。
func TestNeteaseSearchDegraded(t *testing.T) {
	f := newFakeNetease(t)
	f.api.Close() // 上游不可达
	server := newTestServerWithNetease(t, f.api.URL)

	rec := httptest.NewRecorder()
	server.handleSongs(rec, httptest.NewRequest("GET", "/api/songs?q=晨光", nil))
	var resp struct {
		Total int `json:"total"`
	}
	if err := decodeJSONBody(t, rec.Body.String(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Total != 1 {
		t.Fatalf("degraded search should still return local match, got %d", resp.Total)
	}
}

// 网络源曲目流:解析直链后代理转发,Range 透传回 206。
func TestNeteaseStreamProxy(t *testing.T) {
	f := newFakeNetease(t)
	server := newTestServerWithNetease(t, f.api.URL)
	mux := server.routes()

	req := httptest.NewRequest("GET", "/api/stream/ne_167855", nil)
	req.Header.Set("Range", "bytes=4-7")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusPartialContent {
		t.Fatalf("expect 206 via proxy, got %d body=%s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Content-Range"); got == "" {
		t.Fatal("Content-Range should pass through")
	}
	if rec.Body.String() != "4567" {
		t.Fatalf("expect proxied range body, got %q", rec.Body.String())
	}
}

// 无版权曲目:解析成功但上游无 url → 404(版权原因)而非 5xx。
func TestNeteaseStreamNoCopyright(t *testing.T) {
	f := newFakeNetease(t)
	server := newTestServerWithNetease(t, f.api.URL)
	mux := server.routes()

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest("GET", "/api/stream/ne_186016", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expect 404 for no-copyright song, got %d", rec.Code)
	}
}

// 源禁用时 ne_ id 一律 404;providers 不含 netease。
func TestNeteaseDisabled(t *testing.T) {
	server := newTestServer(t, mkLibrary(t)) // 未配置 netease
	if server.netease.enabled() {
		t.Fatal("nil client must be disabled")
	}
	mux := server.routes()

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest("GET", "/api/stream/ne_167855", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expect 404 when disabled, got %d", rec.Code)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest("GET", "/api/providers", nil))
	if strings.Contains(rec.Body.String(), "netease") {
		t.Fatal("providers should not list netease when disabled")
	}

	// q 搜索在禁用时也只走本地。
	rec = httptest.NewRecorder()
	server.handleSongs(rec, httptest.NewRequest("GET", "/api/songs?q=晨光", nil))
	var resp struct {
		Total int `json:"total"`
	}
	if err := decodeJSONBody(t, rec.Body.String(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Total != 1 {
		t.Fatalf("local only, got %d", resp.Total)
	}
}

// cookie 文件热加载:写入新文件后(绕过 30s 间隔强制过期)上游请求携带新值。
func TestNeteaseCookieFileHotReload(t *testing.T) {
	f := newFakeNetease(t)
	var gotCookie atomic.Value
	f.api.Config.Handler = http.NewServeMux()
	f.api.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if v := r.Header.Get("Cookie"); v != "" {
			gotCookie.Store(v)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"result":{"songs":[]}}`))
	})

	cookiePath := filepath.Join(t.TempDir(), "netease-cookie.txt")
	if err := os.WriteFile(cookiePath, []byte("MUSIC_U=v1"), 0o644); err != nil {
		t.Fatal(err)
	}
	c := newNeteaseClient(f.api.URL, "", cookiePath)
	ctx := context.Background()
	if _, err := c.search(ctx, "x", 1); err != nil {
		t.Fatal(err)
	}
	if gotCookie.Load() != "MUSIC_U=v1" {
		t.Fatalf("expect file cookie v1, got %v", gotCookie.Load())
	}

	// 更新文件 + 强制过期重读窗口。
	if err := os.WriteFile(cookiePath, []byte("MUSIC_U=v2"), 0o644); err != nil {
		t.Fatal(err)
	}
	c.mu.Lock()
	c.fileRead = time.Time{} // 绕过 30s 间隔
	c.mu.Unlock()
	if _, err := c.search(ctx, "x", 1); err != nil {
		t.Fatal(err)
	}
	if gotCookie.Load() != "MUSIC_U=v2" {
		t.Fatalf("expect hot-reloaded v2, got %v", gotCookie.Load())
	}
}

// 无 cookie 文件时回退 env 初值;文件不存在不报错。
func TestNeteaseCookieFallback(t *testing.T) {
	f := newFakeNetease(t)
	var gotCookie atomic.Value
	f.api.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if v := r.Header.Get("Cookie"); v != "" {
			gotCookie.Store(v)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"result":{"songs":[]}}`))
	})
	c := newNeteaseClient(f.api.URL, "MUSIC_U=env", filepath.Join(t.TempDir(), "missing.txt"))
	if _, err := c.search(context.Background(), "x", 1); err != nil {
		t.Fatal(err)
	}
	if gotCookie.Load() != "MUSIC_U=env" {
		t.Fatalf("expect env fallback, got %v", gotCookie.Load())
	}
}

// 空曲库回填:q 为空且本地为空时返回网易新歌推荐;本地有曲库时不掺入。
func TestNeteaseDiscoverBackfill(t *testing.T) {
	f := newFakeNetease(t)
	// 假上游补 /top/song。
	handler := f.api.Config.Handler
	f.api.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/top/song" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":[{"id":111,"name":"新歌A","artists":[{"name":"歌手甲"}],"album":{"name":"专辑"},"duration":200000}]}`))
			return
		}
		handler.ServeHTTP(w, r)
	})

	// 空曲库:q 为空 → 回填推荐。
	server := newTestServerWithNetease(t, f.api.URL)
	server.library = nil // 置空曲库
	server.byID = map[string]songFile{}
	rec := httptest.NewRecorder()
	server.handleSongs(rec, httptest.NewRequest("GET", "/api/songs", nil))
	var resp struct {
		Total int    `json:"total"`
		Songs []Song `json:"songs"`
	}
	if err := decodeJSONBody(t, rec.Body.String(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Total != 1 || resp.Songs[0].ID != "ne_111" || resp.Songs[0].Source != "netease" {
		t.Fatalf("expect discover backfill, got %s", rec.Body.String())
	}

	// 本地有曲库:q 为空 → 只回本地,不掺推荐。
	server2 := newTestServerWithNetease(t, f.api.URL)
	rec = httptest.NewRecorder()
	server2.handleSongs(rec, httptest.NewRequest("GET", "/api/songs", nil))
	resp = struct {
		Total int    `json:"total"`
		Songs []Song `json:"songs"`
	}{}
	if err := decodeJSONBody(t, rec.Body.String(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Total == 0 || resp.Songs[0].Source == "netease" {
		t.Fatalf("local library should stay pure, got %s", rec.Body.String())
	}

	// 上游 /top/song 失败:降级返回空列表(200),不报错。
	f2 := newFakeNetease(t)
	f2.api.Close()
	server3 := newTestServerWithNetease(t, f2.api.URL)
	server3.library = nil
	server3.byID = map[string]songFile{}
	rec = httptest.NewRecorder()
	server3.handleSongs(rec, httptest.NewRequest("GET", "/api/songs", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("degraded discover must still 200, got %d", rec.Code)
	}
}
