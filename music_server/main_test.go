package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// mkLibrary 构造临时曲库目录并写入测试音频(内容不重要,扫描只看扩展名)。
func mkLibrary(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	files := map[string]string{
		"湖畔晚风 - 雨后琶音.mp3":     "a",
		"01_远山晨雾 - 晨光旋律.flac": "b",
		"夜曲.wav":              "c",
		"精选集/拾光者 - 温柔节拍.opus": "d",
		"notes.txt": "skip",
	}
	for rel, content := range files {
		full := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestScanLibrary(t *testing.T) {
	dir := mkLibrary(t)
	library, byID, err := scanLibrary(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(library) != 4 {
		t.Fatalf("expect 4 songs, got %d: %+v", len(library), library)
	}
	// 文件名解析:序号前缀剥离 + 「 - 」分割 + 一级子目录作专辑。
	byTitle := map[string]Song{}
	for _, s := range library {
		byTitle[s.Title] = s
	}
	s1, ok := byTitle["雨后琶音"]
	if !ok || s1.Artist != "湖畔晚风" || s1.Album != "" || s1.Format != "mp3" {
		t.Fatalf("bad parse root file: %+v", s1)
	}
	s2, ok := byTitle["晨光旋律"]
	if !ok || s2.Artist != "远山晨雾" {
		t.Fatalf("bad parse numbered file: %+v", s2)
	}
	s3, ok := byTitle["夜曲"]
	if !ok || s3.Artist != "" {
		t.Fatalf("bad parse no-separator file: %+v", s3)
	}
	s4, ok := byTitle["温柔节拍"]
	if !ok || s4.Artist != "拾光者" || s4.Album != "精选集" {
		t.Fatalf("bad parse nested file: %+v", s4)
	}
	if len(byID) != 4 {
		t.Fatalf("index size mismatch: %d", len(byID))
	}
	for _, s := range library {
		if _, ok := byID[s.ID]; !ok {
			t.Fatalf("missing id %s in index", s.ID)
		}
	}
}

func TestParseSongName(t *testing.T) {
	cases := []struct{ in, artist, title string }{
		{"歌手 - 歌名", "歌手", "歌名"},
		{"01_歌手 - 歌名", "歌手", "歌名"},
		{"12-歌手 - 歌名", "歌手", "歌名"},
		{"demo03_拾光者 - 温柔节拍", "拾光者", "温柔节拍"}, // music_player rawfile 约定
		{"v2_远山 - 晨曲", "远山", "晨曲"},
		{"Love_Story - x", "Love_Story", "x"}, // 前缀无数字不剥离
		{"只有歌名", "", "只有歌名"},
		{"a-b-c", "", "a-b-c"}, // 无「 - 」(带空格)分隔,整体作标题
	}
	for _, c := range cases {
		artist, title := parseSongName(c.in)
		if artist != c.artist || title != c.title {
			t.Fatalf("parseSongName(%q) = (%q,%q), want (%q,%q)", c.in, artist, title, c.artist, c.title)
		}
	}
}

func newTestServer(t *testing.T, dir string) *musicServer {
	t.Helper()
	server := &musicServer{
		config:  AppConfig{LibraryDir: dir, RateLimitPerMinute: 1000},
		limiter: newIPWindowLimiter(1000, time.Minute),
	}
	if err := server.refreshLibrary(); err != nil {
		t.Fatal(err)
	}
	return server
}

func TestHandleSongsSearchAndLimit(t *testing.T) {
	server := newTestServer(t, mkLibrary(t))

	rec := httptest.NewRecorder()
	server.handleSongs(rec, httptest.NewRequest("GET", "/api/songs?q=晨光", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	var resp struct {
		Total int    `json:"total"`
		Songs []Song `json:"songs"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Total != 1 || len(resp.Songs) != 1 || resp.Songs[0].Title != "晨光旋律" {
		t.Fatalf("search mismatch: %+v", resp)
	}

	// limit 截断:total 反映全量,songs 只返回 limit 条。
	rec = httptest.NewRecorder()
	server.handleSongs(rec, httptest.NewRequest("GET", "/api/songs?limit=2", nil))
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Total != 4 || len(resp.Songs) != 2 {
		t.Fatalf("limit mismatch: %+v", resp)
	}

	// 非法 limit 拒绝。
	rec = httptest.NewRecorder()
	server.handleSongs(rec, httptest.NewRequest("GET", "/api/songs?limit=-1", nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("invalid limit status %d", rec.Code)
	}
}

func TestHandleStreamRange(t *testing.T) {
	dir := mkLibrary(t)
	server := newTestServer(t, dir)
	library, _, err := scanLibrary(dir)
	if err != nil {
		t.Fatal(err)
	}
	var target Song
	for _, s := range library {
		if s.Title == "雨后琶音" {
			target = s
		}
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/api/stream/"+target.ID, nil)
	req.Header.Set("Range", "bytes=0-0")
	server.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusPartialContent {
		t.Fatalf("range status %d body %s", rec.Code, rec.Body.String())
	}
	if got := rec.Body.String(); got != "a" {
		t.Fatalf("range body %q", got)
	}

	// 未知 ID 404。
	rec = httptest.NewRecorder()
	server.routes().ServeHTTP(rec, httptest.NewRequest("GET", "/api/stream/deadbeefdeadbeef", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("unknown id status %d", rec.Code)
	}
}

func TestRateLimit(t *testing.T) {
	server := newTestServer(t, mkLibrary(t))
	server.limiter = newIPWindowLimiter(2, time.Minute)
	handler := server.requireRateLimit(server.handleProviders)
	for i := 0; i < 2; i++ {
		rec := httptest.NewRecorder()
		handler(rec, httptest.NewRequest("GET", "/api/providers", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("request %d status %d", i, rec.Code)
		}
	}
	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest("GET", "/api/providers", nil))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("expect 429, got %d", rec.Code)
	}
}

func TestLoadAppConfigRequiresLibrary(t *testing.T) {
	if _, err := loadAppConfig(); err == nil {
		t.Fatal("expect error when library dir missing")
	}
}
