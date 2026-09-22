package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestAdminLibraryUploadListDelete 直传→列表→删除全链路:上传即入库
// (刷新后可见)、非法名拒绝、删除后消失。
func TestAdminLibraryUploadListDelete(t *testing.T) {
	dir := t.TempDir()
	s := newTestServer(t, dir)

	// 文件名守卫直接单测:multipart 解析层(Go)已对 filename 做 basename
	// 消毒,传输层到不了穿越分支;validMusicName 作为纵深防御仍在处理器内。
	for _, name := range []string{"../evil.mp3", "a/b.mp3", "..", "", "song.txt"} {
		if validMusicName(name) {
			t.Fatalf("validMusicName(%q) = true, want false", name)
		}
	}
	for _, name := range []string{"雨后琶音.mp3", "a - b.FLAC", "x.m4a"} {
		if !validMusicName(name) {
			t.Fatalf("validMusicName(%q) = false, want true", name)
		}
	}

	// 非白名单扩展名拒绝。
	rec := httptest.NewRecorder()

	// 非白名单扩展名拒绝。
	rec = httptest.NewRecorder()
	multipartBody(t, rec, s, "/admin/api/v1/library/upload", func(w *multipart.Writer) {
		fw, _ := w.CreateFormFile("files", "song.txt")
		fw.Write([]byte("x"))
	})
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "skipped") {
		t.Fatalf("invalid ext: status %d body %s", rec.Code, rec.Body.String())
	}

	// 合法上传 → 保存成功。
	rec = httptest.NewRecorder()
	multipartBody(t, rec, s, "/admin/api/v1/library/upload", func(w *multipart.Writer) {
		fw, _ := w.CreateFormFile("files", "测试歌手 - 雨后琶音.mp3")
		fw.Write([]byte("ID3audio"))
	})
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"saved"`) {
		t.Fatalf("upload: status %d body %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "测试歌手 - 雨后琶音.mp3")); err != nil {
		t.Fatalf("file not saved: %v", err)
	}

	// 刷新后列表可见。
	if err := s.refreshLibrary(); err != nil {
		t.Fatal(err)
	}
	rec = httptest.NewRecorder()
	s.handleAdminLibraryList(rec, httptest.NewRequest("GET", "/admin/api/v1/library", nil))
	var listResp struct {
		Files []musicLibraryFile `json:"files"`
		Total int                `json:"total"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &listResp); err != nil || listResp.Total != 1 {
		t.Fatalf("list: status %d body %s err %v", rec.Code, rec.Body.String(), err)
	}

	// 删除 → 消失。
	rec = httptest.NewRecorder()
	s.handleAdminLibraryDelete(rec, httptest.NewRequest("DELETE", "/admin/api/v1/library?name="+url.QueryEscape("测试歌手 - 雨后琶音.mp3"), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("delete: status %d body %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "测试歌手 - 雨后琶音.mp3")); !os.IsNotExist(err) {
		t.Fatalf("file should be gone")
	}
}

// TestAdminChunkUploadFlow 分片上传全流程:两片收齐自动合并;重复片幂等;
// 同序号内容不一致 409;无会话续传查询返回空。
func TestAdminChunkUploadFlow(t *testing.T) {
	dir := t.TempDir()
	s := newTestServer(t, dir)
	old := uploadChunksDir
	uploadChunksDir = t.TempDir()
	defer func() { uploadChunksDir = old }()

	uploadID := strings.Repeat("ab", 32)
	chunk1 := []byte(strings.Repeat("A", 8))
	chunk2 := []byte(strings.Repeat("B", 8))
	sum := func(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
	total := 2

	sendChunk := func(index int, data []byte, sha string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		multipartBody(t, rec, s, "/admin/api/v1/library/upload-chunk", func(w *multipart.Writer) {
			_ = w.WriteField("uploadId", uploadID)
			_ = w.WriteField("fileName", "歌手 - 曲子.flac")
			_ = w.WriteField("total", fmt.Sprint(total))
			_ = w.WriteField("index", fmt.Sprint(index))
			_ = w.WriteField("sha256", sha)
			fw, _ := w.CreateFormFile("chunk", "part")
			fw.Write(data)
		})
		return rec
	}

	// 分片 0。
	rec := sendChunk(0, chunk1, sum(chunk1))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"complete":false`) {
		t.Fatalf("chunk0: status %d body %s", rec.Code, rec.Body.String())
	}
	// 重复片幂等(续传场景)。
	rec = sendChunk(0, chunk1, sum(chunk1))
	if rec.Code != http.StatusOK {
		t.Fatalf("chunk0 idempotent: status %d body %s", rec.Code, rec.Body.String())
	}
	// 同序号内容不一致 → 409。
	rec = sendChunk(0, []byte("corrupted!"), sum([]byte("corrupted!")))
	if rec.Code != http.StatusConflict {
		t.Fatalf("chunk0 conflict: status %d body %s", rec.Code, rec.Body.String())
	}
	// 分片 1 → 收齐自动合并,complete=true。
	rec = sendChunk(1, chunk2, sum(chunk2))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"complete":true`) {
		t.Fatalf("chunk1: status %d body %s", rec.Code, rec.Body.String())
	}

	// 合并产物按序拼接且入库。
	got, err := os.ReadFile(filepath.Join(dir, "歌手 - 曲子.flac"))
	if err != nil {
		t.Fatalf("merged file missing: %v", err)
	}
	if string(got) != string(chunk1)+string(chunk2) {
		t.Fatalf("merged content mismatch: %q", got)
	}
	// 分片目录已清理。
	if _, err := os.Stat(chunkDir(uploadID)); !os.IsNotExist(err) {
		t.Fatalf("chunk dir should be removed")
	}
	// 索引刷新后业务侧可见。
	if err := s.refreshLibrary(); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, song := range s.snapshot() {
		if song.Title == "曲子" {
			found = true
		}
	}
	if !found {
		t.Fatalf("merged song not indexed")
	}
}

// TestAdminChunkQueryUnknown 无会话的续传查询返回空列表而非错误。
func TestAdminChunkQueryUnknown(t *testing.T) {
	s := newTestServer(t, t.TempDir())
	rec := httptest.NewRecorder()
	s.handleAdminChunkQuery(rec, httptest.NewRequest("GET", "/admin/api/v1/library/upload-chunk?uploadId="+strings.Repeat("cd", 32), nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"received":[]`) {
		t.Fatalf("query: status %d body %s", rec.Code, rec.Body.String())
	}
	// 非法 uploadId 400。
	rec = httptest.NewRecorder()
	s.handleAdminChunkQuery(rec, httptest.NewRequest("GET", "/admin/api/v1/library/upload-chunk?uploadId=../evil", nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("invalid id: status %d", rec.Code)
	}
}

// TestRequireAdminToken 配置令牌后缺头 401,匹配头放行;未配置时放行。
func TestRequireAdminToken(t *testing.T) {
	s := newTestServer(t, t.TempDir())
	s.config.AdminToken = "secret"
	handler := s.requireAdminToken(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest("GET", "/", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("no header: status %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("X-Admin-Token", "wrong")
	handler(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong header: status %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	req = httptest.NewRequest("GET", "/", nil)
	req.Header.Set("X-Admin-Token", "secret")
	handler(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("valid header: status %d", rec.Code)
	}
}

// TestExtractMusicU 锁定 cookie 串中 MUSIC_U 的提取:含 URL 编码字符、
// 段间逗号分隔、值内 _ 与 - 均不得截断;缺失返回空。
func TestExtractMusicU(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"MUSIC_U=abc123", "abc123"},
		{"MUSIC_U=abc_def-ghi", "abc_def-ghi"},
		{"MUSIC_U=a%20b", "a b"},
		{"Path=/, MUSIC_U=xyz", "xyz"},
		{"os=pc; MUSIC_U=123; Path=/", "123"},
		{"MUSIC_U=", ""},
		{"other=1", ""},
	}
	for _, c := range cases {
		if got := extractMusicU(c.in); got != c.want {
			t.Fatalf("extractMusicU(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// multipartBody 以 multipart/form-data 发起 POST 请求并路由到完整 mux。
func multipartBody(t *testing.T, rec *httptest.ResponseRecorder, s *musicServer, path string, fill func(w *multipart.Writer)) {
	t.Helper()
	pr, pw := io.Pipe()
	w := multipart.NewWriter(pw)
	go func() {
		fill(w)
		w.Close()
		pw.CloseWithError(nil)
	}()
	req := httptest.NewRequest("POST", path, pr)
	req.Header.Set("Content-Type", w.FormDataContentType())
	s.routes().ServeHTTP(rec, req)
}
