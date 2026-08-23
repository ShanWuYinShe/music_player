// music_server 是在线音乐目录与流媒体服务:从本地曲库目录(LIBRARY_DIR)扫描
// 音频文件,提供源列表、曲目列表/搜索与 HTTP Range 流式播放。
// 不做任何上游第三方 API 调用——曲目来源完全由运维向曲库目录投放音频文件,
// 元数据从文件名解析(约定「歌手 - 歌名.ext」,兼容「序号_歌手 - 歌名.ext」)。
//
// 认证模型与 media_server 一致:边缘 Cloudflare mTLS 已挡住匿名流量,
// nginx 以固定前缀 /api/music/ 反代并去前缀转发;服务内只做 per-IP 限流。
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"mime"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// 曲库扫描缓存时长:目录变化最迟一个 TTL 生效,避免每次请求都遍历磁盘。
const scanTTL = 60 * time.Second

// 列表/搜索单页默认与上限:无界 limit 会让一次请求序列化整个曲库。
const defaultPageLimit = 200

const maxPageLimit = 500

// 搜索关键词最大字节数:超长一律拒绝,与 media_server 同理由。
const maxSearchQueryBytes = 128

// supportedExt 是可入库的音频扩展名(小写,含点)。
var supportedExt = map[string]bool{
	".mp3": true, ".wav": true, ".flac": true, ".m4a": true,
	".ogg": true, ".oga": true, ".aac": true, ".opus": true,
}

// Song 是对外暴露的曲目元数据。DurationMs 恒为 0:音频时长解析成本高
// (mp3 需逐帧扫描),由客户端在 prepared 后自行回填(与 HarmonyOS 端
// music_player 的既有行为一致)。
type Song struct {
	ID         string `json:"id"`
	Title      string `json:"title"`
	Artist     string `json:"artist"`
	Album      string `json:"album,omitempty"`
	DurationMs int64  `json:"durationMs"`
	Format     string `json:"format"`
	SizeBytes  int64  `json:"sizeBytes"`
}

// musicServer 聚合配置、限流器与带 TTL 缓存的曲库索引。
type musicServer struct {
	config  AppConfig
	limiter *ipWindowLimiter

	mu        sync.RWMutex
	library   []Song
	byID      map[string]songFile
	scannedAt time.Time
}

// songFile 是服务端内部条目:对外 Song 元数据 + 磁盘相对路径(流式读取用)。
// 对外只暴露 ID,磁盘路径永不离开服务进程,杜绝路径穿越。
type songFile struct {
	Song
	relPath string
	modTime time.Time
}

func main() {
	libraryReview := flag.Bool("library-review", false, "扫描曲库并打印解析结果后退出(运维自检用)")
	flag.Parse()

	config, err := loadAppConfig()
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	server := &musicServer{
		config:  config,
		limiter: newIPWindowLimiter(config.RateLimitPerMinute, time.Minute),
	}
	if *libraryReview {
		if err := server.refreshLibrary(); err != nil {
			log.Fatalf("scan library: %v", err)
		}
		server.mu.RLock()
		for _, song := range server.library {
			fmt.Printf("%s\t%s\t%s\n", song.ID, song.Artist, song.Title)
		}
		server.mu.RUnlock()
		fmt.Fprintf(os.Stderr, "共 %d 首\n", len(server.library))
		return
	}

	srv := &http.Server{
		Addr:              config.Addr(),
		Handler:           server.routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("music_server listening on %s, library=%s", config.Addr(), config.LibraryDir)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	<-ctx.Done()
	log.Printf("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}

// routes 注册全部路由。抽成方法供 main 与单元测试共用:
// PathValue 只有在请求经 ServeMux 路由后才有值,测试必须走完整 mux。
func (s *musicServer) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /api/providers", s.requireRateLimit(s.handleProviders))
	mux.HandleFunc("GET /api/songs", s.requireRateLimit(s.handleSongs))
	mux.HandleFunc("GET /api/stream/{id}", s.requireRateLimit(s.handleStream))
	return mux
}

// handleHealth 供编排层 healthcheck 探测,不做限流。
func (s *musicServer) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// requireRateLimit 对业务端点统一施加 per-IP 限流。
func (s *musicServer) requireRateLimit(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.limiter.allow(clientIPFromRequest(r)) {
			writeError(w, "rate limit exceeded", http.StatusTooManyRequests)
			return
		}
		next(w, r)
	}
}

// handleProviders 返回可用音乐源列表。当前只有内置 library 源;
// 未来聚合第三方 API 时在此追加 provider 条目。
func (s *musicServer) handleProviders(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"providers": []map[string]string{
			{"id": "library", "name": "服务器曲库", "type": "library"},
		},
	})
}

// handleSongs 返回曲目列表;可选 q 模糊匹配(标题/歌手,不分大小写)、limit 分页。
func (s *musicServer) handleSongs(w http.ResponseWriter, r *http.Request) {
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if len(query) > maxSearchQueryBytes {
		writeError(w, "query too long", http.StatusBadRequest)
		return
	}
	limit := defaultPageLimit
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		n, err := parsePositiveInt(raw)
		if err != nil || n > maxPageLimit {
			writeError(w, "invalid limit", http.StatusBadRequest)
			return
		}
		limit = n
	}

	songs := s.snapshot()
	matched := make([]Song, 0, len(songs))
	if query == "" {
		matched = songs
	} else {
		needle := strings.ToLower(query)
		for _, song := range songs {
			if strings.Contains(strings.ToLower(song.Title), needle) ||
				strings.Contains(strings.ToLower(song.Artist), needle) {
				matched = append(matched, song)
			}
		}
	}
	total := len(matched)
	if len(matched) > limit {
		matched = matched[:limit]
	}
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "songs": matched})
}

// handleStream 以 HTTP Range 流式播放曲目。ServeContent 原生支持
// Range/If-Range/If-Modified-Since,配合 nginx proxy_buffering off 逐段下发。
func (s *musicServer) handleStream(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	s.mu.RLock()
	entry, ok := s.byID[id]
	s.mu.RUnlock()
	if !ok {
		writeError(w, "song not found", http.StatusNotFound)
		return
	}
	full := filepath.Join(s.config.LibraryDir, filepath.FromSlash(entry.relPath))
	f, err := os.Open(full)
	if err != nil {
		// 曲库文件可能在扫描后被移走:对客户端只报 not found,细节进日志。
		log.Printf("open %s: %v", entry.relPath, err)
		writeError(w, "song not found", http.StatusNotFound)
		return
	}
	defer f.Close()

	ctype := mime.TypeByExtension(strings.ToLower(filepath.Ext(entry.relPath)))
	if ctype != "" {
		w.Header().Set("Content-Type", ctype)
	}
	http.ServeContent(w, r, filepath.Base(entry.relPath), entry.modTime, f)
}

// snapshot 返回当前曲库切片(必要时先刷新);返回值是共享底层数组的只读视图,
// 调用方只做截断与遍历,不得修改元素。
func (s *musicServer) snapshot() []Song {
	s.mu.RLock()
	if time.Since(s.scannedAt) < scanTTL {
		defer s.mu.RUnlock()
		return s.library
	}
	s.mu.RUnlock()

	s.mu.Lock()
	defer s.mu.Unlock()
	// 双重检查:等锁期间可能已被其他请求刷新。
	if time.Since(s.scannedAt) >= scanTTL {
		library, byID, err := scanLibrary(s.config.LibraryDir)
		if err != nil {
			// 扫描失败时保留旧索引继续服务,只记日志。
			log.Printf("scan library: %v", err)
		} else {
			s.library = library
			s.byID = byID
			s.scannedAt = time.Now()
		}
	}
	return s.library
}

// refreshLibrary 强制扫描一次(启动自检/library-review 用)。
func (s *musicServer) refreshLibrary() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	library, byID, err := scanLibrary(s.config.LibraryDir)
	if err != nil {
		return err
	}
	s.library = library
	s.byID = byID
	s.scannedAt = time.Now()
	return nil
}

// scanLibrary 递归扫描曲库目录,解析文件名元数据并构建 ID 索引。
// 一级子目录名作为专辑名,根目录文件专辑为空。
func scanLibrary(dir string) ([]Song, map[string]songFile, error) {
	byID := make(map[string]songFile)
	library := make([]Song, 0, 64)
	err := filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			if path == dir {
				return err
			}
			log.Printf("walk %s: %v", path, err)
			return nil
		}
		if d.IsDir() {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		if !supportedExt[ext] {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			log.Printf("stat %s: %v", path, err)
			return nil
		}
		rel, err := filepath.Rel(dir, path)
		if err != nil {
			log.Printf("rel %s: %v", path, err)
			return nil
		}
		relSlash := filepath.ToSlash(rel)
		sum := sha256.Sum256([]byte(relSlash))
		id := hex.EncodeToString(sum[:])[:16]
		artist, title := parseSongName(strings.TrimSuffix(filepath.Base(path), filepath.Ext(path)))
		album := ""
		if i := strings.IndexByte(relSlash, '/'); i >= 0 {
			album = relSlash[:i]
		}
		entry := songFile{
			Song: Song{
				ID:        id,
				Title:     title,
				Artist:    artist,
				Album:     album,
				Format:    strings.TrimPrefix(ext, "."),
				SizeBytes: info.Size(),
			},
			relPath: relSlash,
			modTime: info.ModTime(),
		}
		byID[id] = entry
		library = append(library, entry.Song)
		return nil
	})
	if err != nil {
		return nil, nil, err
	}
	sort.Slice(library, func(i, j int) bool {
		if library[i].Title != library[j].Title {
			return library[i].Title < library[j].Title
		}
		return library[i].ID < library[j].ID
	})
	return library, byID, nil
}

// parseSongName 从去扩展名的文件名解析歌手与标题:
//   - 先剥离可选的批量命名序号前缀(如「01_」「demo03_」「v2-」),与
//     music_player rawfile 的「demoXX_歌手 - 歌名.ext」约定兼容;
//   - 「歌手 - 歌名」按第一个「 - 」分割;
//   - 无分隔符时整体作为标题,歌手为空。
func parseSongName(base string) (artist, title string) {
	name := stripSerialPrefix(strings.TrimSpace(base))
	sep := strings.Index(name, " - ")
	if sep < 0 {
		return "", name
	}
	return strings.TrimSpace(name[:sep]), strings.TrimSpace(name[sep+3:])
}

// stripSerialPrefix 剥离「字母(可选)+数字(必含)+ _ 或 - 」形式的序号前缀。
// 前缀必须含数字才剥离:「01_」「demo03_」「v2-」命中;普通单词如
// 「Love_Story」的前缀不含数字,保持原样避免误伤。
func stripSerialPrefix(name string) string {
	i := strings.IndexAny(name, "_-")
	if i <= 0 {
		return name
	}
	prefix := name[:i]
	hasDigit := false
	for _, r := range prefix {
		switch {
		case r >= '0' && r <= '9':
			hasDigit = true
		case (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z'):
			// 字母允许出现在序号前(demo03/v2 等)。
		default:
			return name
		}
	}
	if !hasDigit {
		return name
	}
	return strings.TrimSpace(name[i+1:])
}

// writeError 输出业务错误(消息可返回客户端)。
func writeError(w http.ResponseWriter, msg string, code int) {
	writeJSON(w, code, map[string]string{"error": msg})
}

// writeInternalError 只返回固定文案,真实错误进日志,避免泄露内部状态。
func writeInternalError(w http.ResponseWriter, err error) {
	log.Printf("internal error: %v", err)
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "Internal error"})
}

func writeJSON(w http.ResponseWriter, code int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(payload)
}

func parsePositiveInt(raw string) (int, error) {
	n := 0
	for _, r := range raw {
		if r < '0' || r > '9' {
			return 0, fmt.Errorf("invalid number %q", raw)
		}
		n = n*10 + int(r-'0')
		if n > 1<<30 {
			return 0, fmt.Errorf("number too large")
		}
	}
	if n <= 0 {
		return 0, fmt.Errorf("must be positive")
	}
	return n, nil
}
