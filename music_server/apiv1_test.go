package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestAPIV1Prefix 锁定 /api/v1 规范前缀:业务路由只存在于 /api/v1/*,
// 过渡期旧别名 /api/* 已移除(404);/healthz 仅存在于根路径(探针无版本
// 概念),带前缀请求不得误挂。
func TestAPIV1Prefix(t *testing.T) {
	dir := t.TempDir()
	s := newTestServer(t, dir)
	get := func(path string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		return rec
	}

	// 业务路由:规范前缀可达(空曲库时 songs 返回空列表)
	rec := get("/api/v1/songs")
	if rec.Code != http.StatusOK {
		t.Fatalf("/api/v1/songs: status %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `"songs"`) {
		t.Fatalf("/api/v1/songs: unexpected body: %s", rec.Body.String())
	}

	// 带查询串的搜索正常路由(空曲库搜索返回 200 空列表)
	rec = get("/api/v1/songs?q=雨后")
	if rec.Code != http.StatusOK {
		t.Fatalf("/api/v1/songs?q=: status %d, want 200", rec.Code)
	}

	// 旧别名已移除:裸 /api/* 一律 404(含不带 v1 的同名业务路径)
	for _, path := range []string{"/api/songs", "/api/health", "/api/providers"} {
		if rec := get(path); rec.Code != http.StatusNotFound {
			t.Fatalf("%s: status %d, want 404 (legacy alias removed)", path, rec.Code)
		}
	}

	// 存活探针:根路径 /healthz 可用;/api/v1/healthz 不存在(探针无版本概念)
	rec = get("/healthz")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"status":"ok"`) {
		t.Fatalf("/healthz: status %d body %s", rec.Code, rec.Body.String())
	}
	if rec := get("/api/v1/healthz"); rec.Code != http.StatusNotFound {
		t.Fatalf("/api/v1/healthz: status %d, want 404", rec.Code)
	}
}
