package main

// netease 网络源:经私有部署的 NeteaseCloudMusicApi(Enhanced)上游
// (npm 包 @neteasecloudmusicapienhanced/api,容器内网部署)聚合搜索与
// 流解析。设计约束:
//   - 上游不可达/接口失败时降级为仅本地曲库,绝不影响既有 library 能力;
//   - 对外曲目 id 加 "ne_" 前缀与本地 hex id 区分,stream 路由按前缀分发;
//   - 音频流由本服务反向代理转发(用户选定方案):上游直链带时效签名且
//     防盗链策略不定,客户端直连失败率高;代理同时隐藏上游细节。
//
// 匿名上游只能播免费曲目且部分只有 30~60s 试听片段;配置网易账号 cookie
// (登录态)后返回完整音频。cookie 两个来源:env NETEASE_MUSIC_COOKIE(初始
// 值)与 NETEASE_COOKIE_FILE 指向的文件(管理面板扫码登录后写入,30s 内
// 热加载生效,文件优先)。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// neteaseIDPrefix 对外曲目 id 前缀;strip 后即上游歌曲数字 id。
const neteaseIDPrefix = "ne_"

// neteaseSearchCap 每次搜索最多聚合的网易结果数,避免结果被单一源淹没。
const neteaseSearchCap = 30

// neteaseUpstreamTimeout 搜索/解析上游超时;流代理不设整体超时
// (长音频),仅用 Transport 级连接超时。
const neteaseUpstreamTimeout = 8 * time.Second

// errNoStream 表示上游解析成功但该曲目无可用播放地址(无版权/VIP/区域)。
var errNoStream = errors.New("no stream url")

// neteaseClient 封装上游调用。
type neteaseClient struct {
	base string
	// cookieFile 非 nil 时优先读取文件(管理面板扫码登录写入),每
	// cookieReloadInterval 检查一次 mtime 热加载;env 初值作回退。
	cookieFile string
	cookie     string
	// api 用于搜索/解析的小超时请求;stream 用独立长超时 Transport。
	api    *http.Client
	stream *http.Client

	mu           sync.Mutex
	fileMod      time.Time
	fileRead     time.Time
	fileValue    string
	hasFileValue bool

	discoverMu     sync.Mutex
	discoverCache  []Song
	discoverAt     time.Time
	discoverCached bool
	discoverFailAt time.Time

	// searchCache 是网易搜索的短 TTL 缓存(key=query|limit);searchFail 为
	// 同 key 的失败冷却;searchInflight 为同 query 并发单飞(手写,不引依赖)。
	searchMu       sync.Mutex
	searchCache    map[string]searchCacheEntry
	searchFail     map[string]time.Time
	searchInflight map[string]*searchCall
}

// searchCacheTTL 是搜索缓存有效期;searchFailCooldown 是搜索失败冷却期;
// searchCacheMaxEntries 是缓存条数上限,超限整体丢弃重建(防无界增长)。
const (
	searchCacheTTL        = 90 * time.Second
	searchFailCooldown    = 60 * time.Second
	searchCacheMaxEntries = 64
)

// searchCacheEntry 是单条搜索缓存。
type searchCacheEntry struct {
	songs []Song
	at    time.Time
}

// searchCall 是单飞中的一次上游搜索:等 done 关闭后读 songs/err;同时
// 监听 ctx,调用方取消不阻塞。
type searchCall struct {
	done  chan struct{}
	songs []Song
	err   error
}

// cookieReloadInterval 是 cookie 文件的重读检查间隔。
const cookieReloadInterval = 30 * time.Second

func newNeteaseClient(base, cookie, cookieFile string) *neteaseClient {
	if base == "" {
		return nil
	}
	return &neteaseClient{
		base:       base,
		cookieFile: cookieFile,
		cookie:     cookie,
		api:        &http.Client{Timeout: neteaseUpstreamTimeout},
		// 流代理不设整体超时(长音频),仅限制上游响应头等待时间防挂死;
		// 连接池复用上游 keep-alive 连接,无行为变化。
		stream: &http.Client{Transport: &http.Transport{
			ResponseHeaderTimeout: 15 * time.Second,
			MaxIdleConns:          32,
			MaxIdleConnsPerHost:   8,
			IdleConnTimeout:       90 * time.Second,
		}},
	}
}

// currentCookie 返回生效 cookie:文件(热加载)优先,env 初值为回退;
// 文件被删除(如登出)后同样回退 env。读取失败保留旧值并记日志,
// 绝不让热加载故障打断播放。
func (c *neteaseClient) currentCookie() string {
	if c.cookieFile == "" {
		return c.cookie
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if time.Since(c.fileRead) < cookieReloadInterval {
		return c.effectiveCookieLocked()
	}
	c.fileRead = time.Now()
	if info, err := os.Stat(c.cookieFile); err == nil {
		if !info.ModTime().Equal(c.fileMod) {
			data, err := os.ReadFile(c.cookieFile)
			if err != nil {
				log.Printf("netease cookie read: %v", err)
			} else {
				c.fileMod = info.ModTime()
				c.fileValue = strings.TrimSpace(string(data))
				c.hasFileValue = true
				log.Printf("netease cookie reloaded (%d bytes)", len(c.fileValue))
			}
		}
	} else {
		// 文件消失:清文件态,回退 env(部署初始或登出后的匿名/初值状态)。
		c.fileMod = time.Time{}
		c.fileValue = ""
		c.hasFileValue = false
	}
	return c.effectiveCookieLocked()
}

// effectiveCookieLocked 调用方须持 mu。
func (c *neteaseClient) effectiveCookieLocked() string {
	if c.hasFileValue {
		return c.fileValue
	}
	return c.cookie
}

// enabled 报告网络源是否启用。
func (c *neteaseClient) enabled() bool {
	return c != nil && c.base != ""
}

// loggedIn 报告是否已配置账号 cookie(文件或 env 任一非空)。
// 已登录时上游返回完整音频;未登录时付费曲目只有 30~60s 试听片段。
func (c *neteaseClient) loggedIn() bool {
	return c.enabled() && c.currentCookie() != ""
}

// isVIPFee 判定网易曲目 fee 是否付费曲目:1=VIP 专享,4=付费专辑,
// 0=免费,8=非会员免费(限低音质)。付费曲目未登录时上游只发试听片段,
// 标记 VIP 让客户端给出「试听」提示。
func isVIPFee(fee int) bool {
	return fee == 1 || fee == 4
}

// getJSON 请求上游接口并解析 JSON(匿名或带配置 cookie)。
func (c *neteaseClient) getJSON(ctx context.Context, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+path, nil)
	if err != nil {
		return err
	}
	if cookie := c.currentCookie(); cookie != "" {
		req.Header.Set("Cookie", cookie)
	}
	resp, err := c.api.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("upstream %s: %s", path, resp.Status)
	}
	// 2MB 上限防异常大响应撑内存;超限截断后 Decode 失败,走既有上游错误降级。
	return json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(out)
}

// cloudsearchSong 是上游曲目条目的通用子集:/cloudsearch、/playlist/
// track/all 的 songs 同构。新版 eapi 形态：ar=歌手数组、al=专辑对象、
// dt=时长(毫秒)；旧版 /search 形态为 artists/album/duration。两种形态
// 都解析，取非零者，只认旧形态会把搜索结果的歌手/时长全部丢成空值(已踩坑)。
type cloudsearchSong struct {
	ID   int64 `json:"id"`
	Name string
	Ar   []struct{ Name string } `json:"ar"`
	Al   struct{ Name string }   `json:"al"`
	Dt   int64                   `json:"dt"`
	// Fee 顶层付费标记;privilege.fee 为同值的权限位形态,取非零者。
	Fee       int `json:"fee"`
	Privilege struct {
		Fee int `json:"fee"`
	} `json:"privilege"`

	Artists  []struct{ Name string } `json:"artists"`
	Album    struct{ Name string }   `json:"album"`
	Duration int64                   `json:"duration"`
}

// cloudsearchSongs / songURLData / playlistTrackAllResp 是上游响应的
// 用到的子集。
type cloudsearchSongs struct {
	Result struct {
		Songs []cloudsearchSong `json:"songs"`
	} `json:"result"`
}

// playlistTrackAllResp 是上游 /playlist/track/all(歌单全部曲目)响应的
// 用到的子集,songs 条目与 /cloudsearch 同构。
type playlistTrackAllResp struct {
	Songs []cloudsearchSong `json:"songs"`
}

type songURLData struct {
	Data []struct {
		URL  string `json:"url"`
		Code int    `json:"code"`
	} `json:"data"`
}

// toExternalSong 把上游曲目条目映射为对外 Song(id 加 ne_ 前缀),供
// 搜索与榜单发现共用。
func toExternalSong(s cloudsearchSong) Song {
	ar := s.Ar
	if len(ar) == 0 {
		ar = s.Artists // 旧形态回退
	}
	artists := make([]string, 0, len(ar))
	for _, a := range ar {
		artists = append(artists, a.Name)
	}
	duration := s.Dt
	if duration <= 0 {
		duration = s.Duration // 旧形态回退
	}
	album := s.Al.Name
	if album == "" {
		album = s.Album.Name // 旧形态回退
	}
	fee := s.Fee
	if fee == 0 {
		fee = s.Privilege.Fee // 权限位形态回退
	}
	return Song{
		ID:         fmt.Sprintf("%s%d", neteaseIDPrefix, s.ID),
		Title:      s.Name,
		Artist:     strings.Join(artists, "/"),
		Album:      album,
		DurationMs: duration,
		Format:     "mp3",
		Source:     "netease",
		VIP:        isVIPFee(fee),
	}
}

// neteaseHotPlaylistID 是网易官方「热歌榜」歌单 id(约 200 首在榜热歌,
// 播放量验证的大众曲目)。
const neteaseHotPlaylistID = 3778678

// neteaseDiscoverLimit 单次发现拉取的热歌榜条数(榜前 100)。
const neteaseDiscoverLimit = 100

// discover 返回网易「热歌榜」在榜曲目(匿名可用),供空搜索时回填在线
// 列表,让"在线"开箱即有歌。热歌榜是官方播放量运营榜,内容为大众验证
// 过的在榜热歌;旧的「新歌速递」/top/song 是无筛选的新发行流水,大量
// 小众投放与翻唱混音混杂,推荐观感差,已替换。结果缓存 60s(与曲库扫描
// TTL 一致,含空结果),上游失败降级为空(不影响请求成功)并进入同长度
// 的失败冷却期,避免上游故障时每个空列表请求都反复打上游。discoverCached
// 显式区分「已缓存(含空)」与「未缓存」,与失败冷却是正交的两份状态。
func (c *neteaseClient) discover(ctx context.Context) []Song {
	c.discoverMu.Lock()
	if c.discoverCached && time.Since(c.discoverAt) < scanTTL {
		defer c.discoverMu.Unlock()
		return c.discoverCache
	}
	failCooling := time.Since(c.discoverFailAt) < scanTTL
	c.discoverMu.Unlock()
	if failCooling {
		return nil
	}

	path := fmt.Sprintf("/playlist/track/all?id=%d&limit=%d",
		neteaseHotPlaylistID, neteaseDiscoverLimit)
	var resp playlistTrackAllResp
	if err := c.getJSON(ctx, path, &resp); err != nil {
		log.Printf("netease discover: %v", err)
		c.discoverMu.Lock()
		c.discoverFailAt = time.Now()
		c.discoverMu.Unlock()
		return nil
	}
	songs := make([]Song, 0, len(resp.Songs))
	for _, item := range resp.Songs {
		songs = append(songs, toExternalSong(item))
	}

	c.discoverMu.Lock()
	c.discoverCache = songs
	c.discoverAt = time.Now()
	c.discoverCached = true
	c.discoverMu.Unlock()
	return songs
}

// search 调上游 /cloudsearch 并映射为对外 Song(id 加 ne_ 前缀)。
// 结果按 query|limit 短 TTL 缓存,同 query 并发单飞只打一次上游,
// 失败进入 60s 冷却(冷却期内直接报错,由调用方降级为仅本地结果)。
func (c *neteaseClient) search(ctx context.Context, query string, limit int) ([]Song, error) {
	if limit <= 0 || limit > neteaseSearchCap {
		limit = neteaseSearchCap
	}
	key := query + "|" + strconv.Itoa(limit)

	c.searchMu.Lock()
	if e, ok := c.searchCache[key]; ok && time.Since(e.at) < searchCacheTTL {
		songs := e.songs
		c.searchMu.Unlock()
		return songs, nil
	}
	if t, ok := c.searchFail[key]; ok && time.Since(t) < searchFailCooldown {
		c.searchMu.Unlock()
		return nil, fmt.Errorf("netease search %q cooling down", query)
	}
	if call, ok := c.searchInflight[key]; ok {
		c.searchMu.Unlock()
		select {
		case <-call.done:
			return call.songs, call.err
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	call := &searchCall{done: make(chan struct{})}
	if c.searchInflight == nil {
		c.searchInflight = make(map[string]*searchCall)
	}
	c.searchInflight[key] = call
	c.searchMu.Unlock()

	songs, err := c.searchUpstream(ctx, query, limit)

	c.searchMu.Lock()
	delete(c.searchInflight, key)
	if err != nil {
		if c.searchFail == nil {
			c.searchFail = make(map[string]time.Time)
		}
		c.searchFail[key] = time.Now()
	} else {
		if c.searchCache == nil || len(c.searchCache) >= searchCacheMaxEntries {
			c.searchCache = make(map[string]searchCacheEntry, searchCacheMaxEntries)
		}
		c.searchCache[key] = searchCacheEntry{songs: songs, at: time.Now()}
		delete(c.searchFail, key)
	}
	call.songs, call.err = songs, err
	close(call.done)
	c.searchMu.Unlock()
	return songs, err
}

// searchUpstream 实际打一次上游 /cloudsearch 并映射结果。
func (c *neteaseClient) searchUpstream(ctx context.Context, query string, limit int) ([]Song, error) {
	path := fmt.Sprintf("/cloudsearch?keywords=%s&type=1&limit=%d",
		url.QueryEscape(query), limit)
	var resp cloudsearchSongs
	if err := c.getJSON(ctx, path, &resp); err != nil {
		return nil, err
	}
	songs := make([]Song, 0, len(resp.Result.Songs))
	for _, s := range resp.Result.Songs {
		songs = append(songs, toExternalSong(s))
	}
	return songs, nil
}

// resolveURL 调上游 /song/url/v1 解析播放直链(带时效签名,即取即用)。
func (c *neteaseClient) resolveURL(ctx context.Context, songID string) (string, error) {
	path := fmt.Sprintf("/song/url/v1?id=%s&level=exhigh", url.QueryEscape(songID))
	var resp songURLData
	if err := c.getJSON(ctx, path, &resp); err != nil {
		return "", err
	}
	if len(resp.Data) == 0 || resp.Data[0].URL == "" {
		return "", errNoStream
	}
	return resp.Data[0].URL, nil
}

// proxyStream 反向代理上游音频流:透传 Range/返回头与状态码,逐块拷贝。
// 直链域名不做白名单(签名 URL 即凭证),但仅允许 http(s) 防任意 scheme。
func (c *neteaseClient) proxyStream(w http.ResponseWriter, r *http.Request, streamURL string) {
	parsed, err := url.Parse(streamURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		writeError(w, "invalid stream url", http.StatusBadGateway)
		return
	}
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, streamURL, nil)
	if err != nil {
		writeError(w, "stream request failed", http.StatusBadGateway)
		return
	}
	// Range 原样透传,其余头不透传(上游按 CDN 习惯自带 Content-* 响应头)。
	if rng := r.Header.Get("Range"); rng != "" {
		req.Header.Set("Range", rng)
	}
	resp, err := c.stream.Do(req)
	if err != nil {
		log.Printf("netease stream upstream: %v", err)
		writeError(w, "stream upstream failed", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	for _, h := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}
