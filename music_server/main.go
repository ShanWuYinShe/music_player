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
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"mime"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// version 由构建期注入(-ldflags -X main.version,值为仓库 git describe),
// 经 /health 与启动日志暴露,未注入时为 "dev"。
var version = "dev"

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

// Song 是对外暴露的曲目元数据。本地曲目 DurationMs 在扫描时由
// duration.go 解析容器元数据填入(解析失败为 0,由客户端在 prepared 后
// 回填);netease 源带真实时长。
// Source 标识来源(library 省略保持兼容,netease 网络源);VIP 标记网易
// 付费曲目(未配置登录 cookie 时上游只给 30~60s 试听片段,客户端据此提示)。
type Song struct {
	ID         string `json:"id"`
	Title      string `json:"title"`
	Artist     string `json:"artist"`
	Album      string `json:"album,omitempty"`
	DurationMs int64  `json:"durationMs"`
	Format     string `json:"format"`
	SizeBytes  int64  `json:"sizeBytes"`
	Source     string `json:"source,omitempty"`
	VIP        bool   `json:"vip,omitempty"`
	// titleLower/artistLower 是扫描时一次算好的小写索引,供本地搜索复用,
	// 不导出故永不进 JSON。
	titleLower  string
	artistLower string
}

// musicServer 聚合配置、限流器与带 TTL 缓存的曲库索引。
type musicServer struct {
	config  AppConfig
	limiter *ipWindowLimiter
	netease *neteaseClient

	mu        sync.RWMutex
	library   []Song
	byID      map[string]songFile
	scannedAt time.Time
	// refreshing 是后台刷新的单飞标记:过期分支同时最多起一个扫描协程。
	refreshing atomic.Bool
}

// songFile 是服务端内部条目:对外 Song 元数据 + 磁盘相对路径(流式读取用)。
// 对外只暴露 ID,磁盘路径永不离开服务进程,杜绝路径穿越。
// 本地搜索用的小写索引(titleLower/artistLower)由内嵌 Song 携带,扫描时
// 一次算好(不导出,不进 JSON)。
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
		netease: newNeteaseClient(config.NeteaseAPIBase, config.NeteaseCookie, config.NeteaseCookieFile),
	}
	if server.netease.enabled() {
		log.Printf("netease source enabled, upstream=%s (cookie=%v)",
			config.NeteaseAPIBase, config.NeteaseCookie != "")
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

	// 启动预热:后台先扫一次,失败只记日志(首请求经 snapshot 同步兜底)。
	go func() {
		if err := server.refreshLibrary(); err != nil {
			log.Printf("preload library: %v", err)
		}
	}()

	srv := &http.Server{
		Addr:              config.Addr(),
		Handler:           server.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		// handler 均不读 body，30s 覆盖头部后的残余 body drain：没有它，
		// 慢速 dribble 客户端可长期占住连接（ReadHeaderTimeout 只管到头部）。
		ReadTimeout: 30 * time.Second,
		// 空闲 keep-alive 连接限期回收;不设 WriteTimeout——长音频流式响应
		// 会被整体超时掐断。
		IdleTimeout: 120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("music_server %s listening on %s, library=%s", version, config.Addr(), config.LibraryDir)
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

// apiV1Prefix 是独立站(music.chaoset.com)部署的对外规范业务前缀
// (web-service-conventions)。内部路由仍以 /api 书写,入口把 /api/v1/x 归一为
// /api/x;旧 /api/* 为过渡期废弃别名(workwork nginx 反代与存量 App 在用),
// 客户端全量切换后一并移除。
const apiV1Prefix = "/api/v1"

// routes 注册全部路由。抽成方法供 main 与单元测试共用:
// PathValue 只有在请求经 ServeMux 路由后才有值,测试必须走完整 mux。
// 返回值经 /api/v1 归一化包装,健康探针按独立站约定补 /healthz(无版本前缀)。
func (s *musicServer) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	// /healthz:独立站约定的无鉴权存活探针(nginx /healthz 直达,不带 /api 前缀)。
	mux.HandleFunc("GET /healthz", s.handleHealth)
	// /api/health 别名:workwork 过渡反代重写为 /api/health,与 media_server
	// 对齐,公网排障可直接 curl https://<域名>/api/v1/health 拿到版本号。
	mux.HandleFunc("GET /api/health", s.handleHealth)
	mux.HandleFunc("GET /api/providers", s.requireAppToken(s.requireRateLimit(s.handleProviders)))
	mux.HandleFunc("GET /api/songs", s.requireAppToken(s.requireRateLimit(s.handleSongs)))
	mux.HandleFunc("GET /api/stream/{id}", s.requireAppToken(s.requireRateLimit(s.handleStream)))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 归一化只改写路由用的 Path,Query 不受影响。
		if rest, ok := strings.CutPrefix(r.URL.Path, apiV1Prefix); ok {
			r.URL.Path = "/api" + rest
		}
		mux.ServeHTTP(w, r)
	})
}

// handleHealth 供编排层 healthcheck 探测,不做限流。
func (s *musicServer) handleHealth(w http.ResponseWriter, r *http.Request) {
	// JSON 输出携带版本号:与 media_server 的 /health 形态对齐,排障时
	// 一条 curl 即可确认线上运行的构建。
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = fmt.Fprintf(w, `{"status":"ok","version":%q}`+"\n", version)
}

// requireAppToken 可选的应用层鉴权:配置 MUSIC_SERVER_APP_API_TOKEN 后,
// 业务端点必须携带匹配的 X-App-Token 头(与 media_server 的凭证端点同构)。
// 鉴权先于限流——无效请求不消耗限流配额,不污染限流表。token 为空(默认)
// 时不启用,保持既有行为:该服务历史上完全依赖边缘 CF mTLS,此中间件是
// 边缘误配或内网横向移动时的兜底,而不是替代。
func (s *musicServer) requireAppToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.config.AppToken == "" {
			next(w, r)
			return
		}
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("X-App-Token")), []byte(s.config.AppToken)) != 1 {
			writeError(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
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

// handleProviders 返回可用音乐源列表:内置 library 源 + 可选 netease 网络源。
// netease 源附带 loggedIn(是否已配置账号 cookie),客户端据此提示
// 「未登录时 VIP 歌曲仅试听片段」。
func (s *musicServer) handleProviders(w http.ResponseWriter, r *http.Request) {
	providers := []map[string]any{
		{"id": "library", "name": "服务器曲库", "type": "library"},
	}
	if s.netease.enabled() {
		providers = append(providers, map[string]any{
			"id": "netease", "name": "网易云(网络源)", "type": "online",
			"loggedIn": s.netease.loggedIn(),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"providers": providers})
}

// handleSongs 返回曲目列表;可选 q 模糊匹配(标题/歌手,不分大小写)、limit 分页。
// q 非空且网络源启用时,本地匹配之后追加网易搜索结果(上游失败降级仅本地)。
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
	// q 为空直接复用快照视图;搜索分支按需从小容量增长,不再按全库预分配。
	var matched []Song
	if query == "" {
		matched = songs
	} else {
		matched = make([]Song, 0, 16)
		needle := strings.ToLower(query)
		for _, song := range songs {
			if strings.Contains(song.titleLower, needle) ||
				strings.Contains(song.artistLower, needle) {
				matched = append(matched, song)
			}
		}
	}
	// 网络源结果追加在本地匹配之后;q 为空时不拉网络搜索(列表语义仍是"曲库")。
	if query != "" && s.netease.enabled() && len(matched) < limit {
		ctx, cancel := context.WithTimeout(r.Context(), neteaseUpstreamTimeout)
		online, err := s.netease.search(ctx, query, limit-len(matched))
		cancel()
		if err != nil {
			// 上游失败只降级不报错:本地结果仍然完整返回。
			log.Printf("netease search %q: %v", query, err)
		} else {
			matched = append(matched, online...)
		}
	}
	// 开箱体验:q 为空时在本地曲库之后追加网易「新歌速递」推荐——「在线」
	// 列表是"在线可播的一切"而非纯服务器目录,服务器曲库只有寥寥几首时
	// 在线页仍有内容可听(推荐结果带 VIP 标记,客户端按登录态提示试听)。
	// snapshot 返回的是与 s.library 共享底层数组的只读视图:append 前必须
	// 拷贝,否则上游结果会越过 len 写进共享数组,并发请求下构成数据竞争。
	if query == "" && s.netease.enabled() && len(matched) < limit {
		ctx, cancel := context.WithTimeout(r.Context(), neteaseUpstreamTimeout)
		matched = append(append([]Song(nil), matched...), s.netease.discover(ctx)...)
		cancel()
	}
	total := len(matched)
	if len(matched) > limit {
		matched = matched[:limit]
	}
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "songs": matched})
}

// handleStream 以 HTTP Range 流式播放曲目。id 带 ne_ 前缀走网络源代理,
// 其余为本地曲库文件,ServeContent 原生支持 Range/If-Range 等条件请求。
func (s *musicServer) handleStream(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if after, ok := strings.CutPrefix(id, neteaseIDPrefix); ok {
		if !s.netease.enabled() {
			writeError(w, "netease source disabled", http.StatusNotFound)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), neteaseUpstreamTimeout)
		streamURL, err := s.netease.resolveURL(ctx, after)
		cancel()
		if errors.Is(err, errNoStream) {
			// 无版权/VIP/区域限制:对客户端是"这首歌放不了"而非服务故障。
			writeError(w, "song not available (copyright)", http.StatusNotFound)
			return
		} else if err != nil {
			log.Printf("netease resolve %s: %v", after, err)
			writeError(w, "stream resolve failed", http.StatusBadGateway)
			return
		}
		s.netease.proxyStream(w, r, streamURL)
		return
	}
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

// snapshot 返回当前曲库切片(与 s.library 共享底层数组的只读视图,调用方
// 只做截断与遍历,追加内容前必须拷贝)。首次访问同步扫描保证首请求可用;
// 索引过期时触发后台刷新并先返回旧数据——大曲库全量扫描耗时,不让请求
// 跟着等;后台刷新单飞(同时最多一个扫描协程),刷新失败同样推进
// scannedAt(冷却一个 TTL 再试),避免失败风暴。
func (s *musicServer) snapshot() []Song {
	s.mu.RLock()
	scanned := s.scannedAt
	library := s.library
	s.mu.RUnlock()

	if scanned.IsZero() {
		// 首次访问:同步扫描,保证冷启动的首个请求能拿到曲库。
		if err := s.refreshLibraryOnce(); err != nil {
			return nil
		}
		s.mu.RLock()
		defer s.mu.RUnlock()
		return s.library
	}
	if time.Since(scanned) >= scanTTL {
		if s.refreshing.CompareAndSwap(false, true) {
			go func() {
				defer s.refreshing.Store(false)
				_ = s.refreshLibraryOnce()
			}()
		}
	}
	return library
}

// refreshLibraryOnce 刷新曲库索引:过期检查与旧缓存构建持读锁,磁盘扫描
// 在锁外执行(读请求零阻塞),完成后持写锁一次性替换索引。扫描失败保留
// 旧索引并推进时间戳(冷却一个 TTL),只记日志不报错。
func (s *musicServer) refreshLibraryOnce() error {
	s.mu.RLock()
	if !s.scannedAt.IsZero() && time.Since(s.scannedAt) < scanTTL {
		s.mu.RUnlock()
		return nil
	}
	old := buildDurationCache(s.byID)
	dir := s.config.LibraryDir
	s.mu.RUnlock()

	library, byID, err := scanLibrary(dir, old)
	s.mu.Lock()
	defer s.mu.Unlock()
	if err != nil {
		log.Printf("scan library: %v", err)
		s.scannedAt = time.Now()
		return err
	}
	s.library = library
	s.byID = byID
	s.scannedAt = time.Now()
	return nil
}

// refreshLibrary 强制同步扫描一次(启动预热/启动自检/library-review 用),
// 全量解析时长。
func (s *musicServer) refreshLibrary() error {
	library, byID, err := scanLibrary(s.config.LibraryDir, nil)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.library = library
	s.byID = byID
	s.scannedAt = time.Now()
	return nil
}

// cachedDuration 是上次索引留下的时长复用依据:大小与修改时间都未变才
// 视为同一文件,跳过容器解析。
type cachedDuration struct {
	size     int64
	modTime  time.Time
	duration int64
}

// buildDurationCache 从当前索引构建旧时长缓存(调用方须至少持读锁)。
func buildDurationCache(byID map[string]songFile) map[string]cachedDuration {
	if len(byID) == 0 {
		return nil
	}
	old := make(map[string]cachedDuration, len(byID))
	for _, e := range byID {
		old[e.relPath] = cachedDuration{size: e.SizeBytes, modTime: e.modTime, duration: e.DurationMs}
	}
	return old
}

// scanLibrary 递归扫描曲库目录,解析文件名元数据并构建 ID 索引。
// 一级子目录名作为专辑名,根目录文件专辑为空。
// old 为上次索引的时长缓存:大小与修改时间未变的文件跳过容器解析,
// 直接复用旧时长;nil 表示全量解析。
func scanLibrary(dir string, old map[string]cachedDuration) ([]Song, map[string]songFile, error) {
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
		// 跳过符号链接：曲库卷可被多方投放文件，指向库外的软链（如
		// x.mp3 -> /data/netease/cookie）会经播放端点把库外文件当音频读走。
		if info.Mode()&fs.ModeSymlink != 0 {
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
				ID:          id,
				Title:       title,
				Artist:      artist,
				Album:       album,
				Format:      strings.TrimPrefix(ext, "."),
				SizeBytes:   info.Size(),
				DurationMs:  durationFor(path, ext, info.Size(), info.ModTime(), old, relSlash),
				titleLower:  strings.ToLower(title),
				artistLower: strings.ToLower(artist),
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

// durationFor 返回文件时长:旧缓存命中(大小与修改时间未变)直接复用,
// 新增或变更的文件才解析容器元数据。
func durationFor(path, ext string, size int64, modTime time.Time, old map[string]cachedDuration, relSlash string) int64 {
	if o, ok := old[relSlash]; ok && o.size == size && o.modTime.Equal(modTime) {
		return o.duration
	}
	return probeDurationSafe(path, ext, size)
}

// probeDurationSafe 打开文件解析时长,任何失败静默返回 0(客户端 prepared
// 后仍会回填),不让单文件元数据问题阻塞曲库扫描。
func probeDurationSafe(path, ext string, size int64) int64 {
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer f.Close()
	return probeAudioDuration(f, ext, size)
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
