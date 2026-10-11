package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

// TestAdminLibrarySubdirListAndDelete 子目录曲库：管理端点与业务端点必须同构。
// 曲库按子目录分组（一级子目录即专辑，scanLibrary 递归），管理面板的列表与
// 删除若只认根目录文件名，子目录投放的音频会「列表看不见、删除找不到」——
// 表现为曲库页能播、管理页既不可见也删不掉。
func TestAdminLibrarySubdirListAndDelete(t *testing.T) {
	dir := t.TempDir()
	s := newTestServer(t, dir)
	if err := os.MkdirAll(filepath.Join(dir, "专辑A"), 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(rel string) {
		if err := os.WriteFile(filepath.Join(dir, rel), []byte("audio"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("根目录歌.mp3")
	write(filepath.Join("专辑A", "子目录歌.mp3"))

	// 业务端点看到两首（递归扫描）。
	if err := s.refreshLibrary(); err != nil {
		t.Fatal(err)
	}
	if got := len(s.snapshot()); got != 2 {
		t.Fatalf("业务端点扫到 %d 首, want 2", got)
	}

	// 管理列表同样看到两首，且 name 为相对路径。
	rec := httptest.NewRecorder()
	s.handleAdminLibraryList(rec, httptest.NewRequest("GET", "/admin/api/v1/library?pageSize=500", nil))
	var listResp struct {
		Files []musicLibraryFile
		Total int
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &listResp); err != nil {
		t.Fatalf("list decode: %v body %s", err, rec.Body.String())
	}
	if listResp.Total != 2 {
		t.Fatalf("管理列表 total=%d, want 2 (body %s)", listResp.Total, rec.Body.String())
	}
	names := map[string]bool{}
	for _, f := range listResp.Files {
		names[f.Name] = true
	}
	if !names["根目录歌.mp3"] || !names["专辑A/子目录歌.mp3"] {
		t.Fatalf("列表 name 应为相对路径, got %v", names)
	}

	// 删除子目录文件（相对路径寻址）。
	rec = httptest.NewRecorder()
	s.handleAdminLibraryDelete(rec, httptest.NewRequest("DELETE",
		"/admin/api/v1/library?name="+url.QueryEscape("专辑A/子目录歌.mp3"), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("delete subdir: status %d body %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "专辑A", "子目录歌.mp3")); !os.IsNotExist(err) {
		t.Fatal("子目录文件应已删除")
	}

	// 路径穿越与非法形态一律拒绝（删除不可恢复，守卫必须比上传更严）。
	backslash := string([]byte{0x5c})
	for _, bad := range []string{
		"../outside.mp3", "专辑A/../../outside.mp3", "/abs/path.mp3",
		"C:" + backslash + "win.mp3", "专辑A//歌.mp3", "专辑A/./歌.mp3",
		"note.txt", "",
	} {
		rec = httptest.NewRecorder()
		s.handleAdminLibraryDelete(rec, httptest.NewRequest("DELETE",
			"/admin/api/v1/library?name="+url.QueryEscape(bad), nil))
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("delete %q: status %d body %s, want 400", bad, rec.Code, rec.Body.String())
		}
	}
}
