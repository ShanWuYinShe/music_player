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

	discoverMu    sync.Mutex
	discoverCache []Song
	discoverAt    time.Time
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
		// 流代理不设整体超时(长音频),仅限制上游响应头等待时间防挂死。
		stream: &http.Client{Transport: &http.Transport{
			ResponseHeaderTimeout: 15 * time.Second,
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
	return json.NewDecoder(resp.Body).Decode(out)
}

// cloudsearchSongs / songURLData 是上游响应的用到的子集。
// /cloudsearch 走新版 eapi 形态：ar=歌手数组、al=专辑对象、dt=时长(毫秒)；
// 旧版 /search 形态为 artists/album/duration。两种形态都解析，取非零者，
// 只认旧形态会把搜索结果的歌手/时长全部丢成空值(已踩坑)。
type cloudsearchSongs struct {
	Result struct {
		Songs []struct {
			ID   int64 `json:"id"`
			Name string
			Ar   []struct{ Name string } `json:"ar"`
			Al   struct{ Name string }   `json:"al"`
			Dt   int64                   `json:"dt"`

			Artists  []struct{ Name string } `json:"artists"`
			Album    struct{ Name string }   `json:"album"`
			Duration int64                   `json:"duration"`
		} `json:"songs"`
	} `json:"result"`
}

type songURLData struct {
	Data []struct {
		URL  string `json:"url"`
		Code int    `json:"code"`
	} `json:"data"`
}

// topSongResp 是上游 /top/song(新歌速递)响应的用到的子集。
type topSongResp struct {
	Data []struct {
		ID       int64 `json:"id"`
		Name     string
		Artists  []struct{ Name string } `json:"artists"`
		Album    struct{ Name string }   `json:"album"`
		Duration int64                   `json:"duration"`
	} `json:"data"`
}

// discover 返回网易「新歌速递」推荐曲目(匿名可用),供空曲库时回填在线
// 列表,让"在线"开箱即有歌。结果缓存 60s(与曲库扫描 TTL 一致),上游
// 失败降级为空(不影响请求成功)。
func (c *neteaseClient) discover(ctx context.Context) []Song {
	c.discoverMu.Lock()
	if time.Since(c.discoverAt) < scanTTL && c.discoverCache != nil {
		defer c.discoverMu.Unlock()
		return c.discoverCache
	}
	c.discoverMu.Unlock()

	var resp topSongResp
	if err := c.getJSON(ctx, "/top/song", &resp); err != nil {
		log.Printf("netease discover: %v", err)
		return nil
	}
	songs := make([]Song, 0, len(resp.Data))
	for _, item := range resp.Data {
		artists := make([]string, 0, len(item.Artists))
		for _, a := range item.Artists {
			artists = append(artists, a.Name)
		}
		songs = append(songs, Song{
			ID:         fmt.Sprintf("%s%d", neteaseIDPrefix, item.ID),
			Title:      item.Name,
			Artist:     strings.Join(artists, "/"),
			Album:      item.Album.Name,
			DurationMs: item.Duration,
			Format:     "mp3",
			Source:     "netease",
		})
	}

	c.discoverMu.Lock()
	c.discoverCache = songs
	c.discoverAt = time.Now()
	c.discoverMu.Unlock()
	return songs
}

// search 调上游 /cloudsearch 并映射为对外 Song(id 加 ne_ 前缀)。
func (c *neteaseClient) search(ctx context.Context, query string, limit int) ([]Song, error) {
	if limit <= 0 || limit > neteaseSearchCap {
		limit = neteaseSearchCap
	}
	path := fmt.Sprintf("/cloudsearch?keywords=%s&type=1&limit=%d",
		url.QueryEscape(query), limit)
	var resp cloudsearchSongs
	if err := c.getJSON(ctx, path, &resp); err != nil {
		return nil, err
	}
	songs := make([]Song, 0, len(resp.Result.Songs))
	for _, s := range resp.Result.Songs {
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
		songs = append(songs, Song{
			ID:         fmt.Sprintf("%s%d", neteaseIDPrefix, s.ID),
			Title:      s.Name,
			Artist:     strings.Join(artists, "/"),
			Album:      album,
			DurationMs: duration,
			Format:     "mp3",
			Source:     "netease",
		})
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
