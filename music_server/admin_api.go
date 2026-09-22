package main

// 站内薄管理接口(/admin/api/v1/*):独立站拆分后原 workwork admin 的
// 「音乐曲库管理」与「网易云扫码登录」随站迁移至此(功能随站走)。
// 曲库上传即入库:索引 60s TTL 懒刷新,无需重启。cookie 写入
// NETEASE_COOKIE_FILE 指向的文件,neteaseClient 热加载(30s)。
//
// 安全模型:边缘 nginx 对 /admin/ 施加 basic auth(htpasswd)+ CF 回源 mTLS;
// 本组接口另设可选 MUSIC_SERVER_ADMIN_TOKEN(X-Admin-Token,常量时间比较,
// 作为边缘误配/内网横向的兜底;空 = 仅依赖边缘)。写操作按 IP 留痕。
//
// 曲库上传移植自 workwork admin internal/music(同一维护者),协议不变:
//   POST /admin/api/v1/library/upload-chunk  传单片(收齐自动合并落库)
//   GET  /admin/api/v1/library/upload-chunk?uploadId=  查询已收分片(续传)
// uploadId 由前端从文件名/大小/mtime/首 1MB 内容派生(SHA-256 hex64),服务端
// 只把它当目录名,严格校验 hex64 防路径穿越;每片携带 SHA-256 落盘前校验。

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 单文件与整个 multipart 请求的大小上限(与 workwork admin 移植前一致)。
const (
	maxMusicFileBytes = 200 << 20
	maxMusicBodyBytes = maxMusicFileBytes*2 + 8<<20
)

// 分片参数:8MB/片,最多 32 片(256MB),覆盖单文件 200MB 上限。
const (
	musicChunkBytes     = 8 << 20
	musicMaxChunks      = 32
	musicChunkBodyLimit = musicChunkBytes + 2<<20
	musicChunkTTL       = 24 * time.Hour
)

// 上传并发闸门容量:multipart 内存缓冲 4-8MB,全局限 2 位防并发上传 OOM。
const maxUploadSlots = 2

// uploadChunksDir 是分片暂存根目录(与曲库同卷 /data);var 供测试替换。
var uploadChunksDir = "/data/upload-chunks"

// adminTokenEnabled 报告是否配置了管理令牌。
func (s *musicServer) adminTokenEnabled() bool { return s.config.AdminToken != "" }

// requireAdminToken 是 /admin/api/v1/* 的兜底鉴权:配置 MUSIC_SERVER_ADMIN_TOKEN
// 后要求 X-Admin-Token 头(常量时间比较);鉴权先于任何业务逻辑。
func (s *musicServer) requireAdminToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.config.AdminToken != "" &&
			subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Admin-Token")), []byte(s.config.AdminToken)) != 1 {
			writeError(w, "管理令牌缺失或不匹配", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// acquireUploadSlot 是上传并发闸门(信号量);满员返回 false。
func acquireUploadSlot(slots chan struct{}) (func(), bool) {
	select {
	case slots <- struct{}{}:
		return func() { <-slots }, true
	default:
		return nil, false
	}
}

// ---------- 曲库:列表 / 一次性上传 / 删除 ----------

// musicLibraryFile 是列表条目。
type musicLibraryFile struct {
	Name      string `json:"name"`
	SizeBytes int64  `json:"sizeBytes"`
	ModTime   string `json:"modTime"`
}

// validMusicName 校验落盘文件名:拒绝路径分隔符与相对路径,扩展名须在白名单。
func validMusicName(name string) bool {
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
		return false
	}
	return supportedExt[strings.ToLower(filepath.Ext(name))]
}

func (s *musicServer) handleAdminLibraryList(w http.ResponseWriter, r *http.Request) {
	entries, err := os.ReadDir(s.config.LibraryDir)
	if err != nil {
		if os.IsNotExist(err) {
			writeJSON(w, http.StatusOK, map[string]any{"files": []musicLibraryFile{}})
			return
		}
		writeError(w, "读取曲库目录失败", http.StatusInternalServerError)
		log.Printf("admin library list: %v", err)
		return
	}
	files := make([]musicLibraryFile, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || !supportedExt[strings.ToLower(filepath.Ext(e.Name()))] {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		files = append(files, musicLibraryFile{
			Name:      e.Name(),
			SizeBytes: info.Size(),
			ModTime:   info.ModTime().Format(time.RFC3339),
		})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })
	// 分页:page 从 1,pageSize 默认 100 上限 500(全量曲库列表由业务 /api/songs 承载)。
	page, pageSize := 1, 100
	if p, err := strconv.Atoi(r.URL.Query().Get("page")); err == nil && p > 0 {
		page = p
	}
	if ps, err := strconv.Atoi(r.URL.Query().Get("pageSize")); err == nil && ps > 0 && ps <= 500 {
		pageSize = ps
	}
	start := (page - 1) * pageSize
	if start > len(files) {
		start = len(files)
	}
	end := start + pageSize
	if end > len(files) {
		end = len(files)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"files": files[start:end], "total": len(files), "page": page, "pageSize": pageSize,
	})
}

func (s *musicServer) handleAdminLibraryUpload(w http.ResponseWriter, r *http.Request) {
	release, ok := acquireUploadSlot(s.uploadSlots)
	if !ok {
		writeError(w, "并发上传过多，请稍后重试", http.StatusTooManyRequests)
		return
	}
	defer release()

	r.Body = http.MaxBytesReader(w, r.Body, maxMusicBodyBytes)
	if err := r.ParseMultipartForm(8 << 20); err != nil {
		writeError(w, "上传内容过大或格式不正确", http.StatusBadRequest)
		return
	}
	// 超过内存阈值的 multipart 部分落盘为临时文件,请求结束必须显式清理。
	defer func() {
		if r.MultipartForm != nil {
			_ = r.MultipartForm.RemoveAll()
		}
	}()

	headers := r.MultipartForm.File["files"]
	if len(headers) == 0 {
		writeError(w, "请选择要上传的音频文件", http.StatusBadRequest)
		return
	}
	if len(headers) > 50 {
		writeError(w, "单次最多上传 50 个文件", http.StatusBadRequest)
		return
	}

	saved := make([]string, 0, len(headers))
	skipped := make([]string, 0)
	for _, header := range headers {
		name, err := s.saveMusicUpload(header)
		if err != nil {
			skipped = append(skipped, header.Filename+"("+err.Error()+")")
			continue
		}
		saved = append(saved, name)
	}
	log.Printf("[security] music library upload saved=%d skipped=%d by=ip:%s",
		len(saved), len(skipped), clientIPFromRequest(r))
	writeJSON(w, http.StatusOK, map[string]any{"saved": saved, "skipped": skipped})
}

// saveMusicUpload 校验并保存单个上传文件,返回落盘文件名。
func (s *musicServer) saveMusicUpload(header *multipart.FileHeader) (string, error) {
	raw := strings.TrimSpace(header.Filename)
	if !validMusicName(filepath.Base(raw)) || raw != filepath.Base(raw) {
		return "", errors.New("文件名不合法")
	}
	name := filepath.Base(raw)
	if header.Size > maxMusicFileBytes {
		return "", errors.New("文件超过 200MB 上限")
	}
	src, err := header.Open()
	if err != nil {
		return "", err
	}
	defer src.Close()

	// 同名覆盖语义(重传修正版):临时文件 + fsync + rename 原子落盘。
	tmp, err := os.CreateTemp(s.config.LibraryDir, ".music-upload-*")
	if err != nil {
		return "", err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	if _, err := io.Copy(tmp, src); err != nil {
		tmp.Close()
		return "", err
	}
	// rename 前刷出 page cache:断电不会留下「文件名在、内容空」的坏文件。
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(tmpName, filepath.Join(s.config.LibraryDir, name)); err != nil {
		return "", err
	}
	return name, nil
}

func (s *musicServer) handleAdminLibraryDelete(w http.ResponseWriter, r *http.Request) {
	name := filepath.Base(strings.TrimSpace(r.URL.Query().Get("name")))
	if !validMusicName(name) {
		writeError(w, "文件名不合法", http.StatusBadRequest)
		return
	}
	if err := os.Remove(filepath.Join(s.config.LibraryDir, name)); err != nil {
		if os.IsNotExist(err) {
			writeError(w, "文件不存在", http.StatusNotFound)
			return
		}
		writeError(w, "删除失败", http.StatusInternalServerError)
		log.Printf("admin library delete: %v", err)
		return
	}
	// 文件名经 %q 转义:文件名用户可控且可含换行,裸 %s 会被 docker 日志按行
	// 拆分,伪造出以 [security] 开头的假审计记录。
	log.Printf("[security] music library delete file=%q by=ip:%s", name, clientIPFromRequest(r))
	writeJSON(w, http.StatusOK, map[string]string{"deleted": name})
}

// ---------- 曲库:分片上传 ----------

// chunkMeta 是分片会话元信息,首片到达时写入。
type chunkMeta struct {
	FileName string `json:"fileName"`
	Total    int    `json:"total"`
}

// chunkUploadError 业务校验错误,消息可直接返回客户端。
type chunkUploadError struct {
	msg  string
	code int
}

func (e *chunkUploadError) Error() string { return e.msg }

func chunkErr(msg string, code int) error { return &chunkUploadError{msg: msg, code: code} }

// validUploadID 严格 hex64,杜绝把用户可控字符串拼进路径。
func validUploadID(id string) bool {
	if len(id) != 64 {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

func chunkDir(uploadID string) string { return filepath.Join(uploadChunksDir, uploadID) }

func readChunkMeta(uploadID string) (*chunkMeta, error) {
	data, err := os.ReadFile(filepath.Join(chunkDir(uploadID), "meta.json"))
	if err != nil {
		return nil, err
	}
	var m chunkMeta
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	return &m, nil
}

// receivedChunks 列出已落盘分片序号(忽略 .part 之外的杂项)。
func receivedChunks(uploadID string) ([]int, error) {
	entries, err := os.ReadDir(chunkDir(uploadID))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	out := []int{}
	for _, e := range entries {
		idx, err := strconv.Atoi(strings.TrimSuffix(e.Name(), ".part"))
		if err != nil || e.IsDir() {
			continue
		}
		out = append(out, idx)
	}
	sort.Ints(out)
	return out, nil
}

func (s *musicServer) handleAdminChunkQuery(w http.ResponseWriter, r *http.Request) {
	uploadID := r.URL.Query().Get("uploadId")
	if !validUploadID(uploadID) {
		writeError(w, "uploadId 不合法", http.StatusBadRequest)
		return
	}
	resp := map[string]any{"received": []int{}, "total": 0, "fileName": ""}
	if meta, err := readChunkMeta(uploadID); err == nil {
		rc, err := receivedChunks(uploadID)
		if err != nil {
			writeError(w, "读取分片会话失败", http.StatusInternalServerError)
			return
		}
		resp["received"] = rc
		resp["total"] = meta.Total
		resp["fileName"] = meta.FileName
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *musicServer) handleAdminChunkUpload(w http.ResponseWriter, r *http.Request) {
	release, ok := acquireUploadSlot(s.uploadSlots)
	if !ok {
		writeError(w, "并发上传过多，请稍后重试", http.StatusTooManyRequests)
		return
	}
	defer release()

	r.Body = http.MaxBytesReader(w, r.Body, musicChunkBodyLimit)
	if err := r.ParseMultipartForm(4 << 20); err != nil {
		writeError(w, "分片内容过大或格式不正确", http.StatusBadRequest)
		return
	}
	defer func() {
		if r.MultipartForm != nil {
			_ = r.MultipartForm.RemoveAll()
		}
	}()

	uploadID := r.FormValue("uploadId")
	fileName := r.FormValue("fileName")
	total, _ := strconv.Atoi(r.FormValue("total"))
	index, _ := strconv.Atoi(r.FormValue("index"))
	chunkSHA := r.FormValue("sha256")
	if !validUploadID(uploadID) {
		writeError(w, "uploadId 不合法", http.StatusBadRequest)
		return
	}
	if total < 1 || total > musicMaxChunks || index < 0 || index >= total {
		writeError(w, "分片序号不合法", http.StatusBadRequest)
		return
	}
	// 文件名规则与一次性上传一致(拒绝路径分隔符 + 扩展名白名单)。
	if !validMusicName(fileName) {
		writeError(w, "文件名不合法(仅支持音频文件)", http.StatusBadRequest)
		return
	}
	fileHeader := r.MultipartForm.File["chunk"]
	if len(fileHeader) != 1 {
		writeError(w, "缺少分片数据", http.StatusBadRequest)
		return
	}
	if fileHeader[0].Size > musicChunkBytes {
		writeError(w, "分片超过 8MB 上限", http.StatusBadRequest)
		return
	}
	if _, err := hex.DecodeString(chunkSHA); err != nil {
		writeError(w, "分片校验值不合法", http.StatusBadRequest)
		return
	}

	if err := os.MkdirAll(chunkDir(uploadID), 0o755); err != nil {
		writeError(w, "创建分片会话失败", http.StatusInternalServerError)
		return
	}
	// 首片隐式重建会话:同名会话但布局变了(文件被修改后重传)则丢弃旧分片。
	if meta, err := readChunkMeta(uploadID); err == nil {
		if meta.Total != total || meta.FileName != fileName {
			if err := os.RemoveAll(chunkDir(uploadID)); err != nil {
				writeError(w, "重置分片会话失败", http.StatusInternalServerError)
				return
			}
			if err := os.MkdirAll(chunkDir(uploadID), 0o755); err != nil {
				writeError(w, "重置分片会话失败", http.StatusInternalServerError)
				return
			}
		}
	} else if !os.IsNotExist(err) {
		writeError(w, "读取分片会话失败", http.StatusInternalServerError)
		return
	}
	if err := atomicWriteFile(filepath.Join(chunkDir(uploadID), "meta.json"),
		mustJSON(chunkMeta{FileName: fileName, Total: total}), 0o644); err != nil {
		writeError(w, "写入分片会话失败", http.StatusInternalServerError)
		return
	}

	saved, err := s.saveChunk(uploadID, index, chunkSHA, fileHeader[0])
	if err != nil {
		var ce *chunkUploadError
		if errors.As(err, &ce) {
			writeError(w, ce.msg, ce.code)
			return
		}
		writeError(w, "分片保存失败", http.StatusInternalServerError)
		log.Printf("admin chunk upload: %v", err)
		return
	}
	rc, err := receivedChunks(uploadID)
	if err != nil {
		writeError(w, "读取分片会话失败", http.StatusInternalServerError)
		return
	}
	resp := map[string]any{"received": rc, "total": total, "complete": false}
	if len(rc) == total {
		// 收齐:合并入库(同名覆盖语义与一次性上传一致)。
		finalName, err := s.mergeChunkOnce(uploadID, total)
		if err != nil {
			var ce *chunkUploadError
			if errors.As(err, &ce) {
				writeError(w, ce.msg, ce.code)
				return
			}
			writeError(w, "分片合并失败", http.StatusInternalServerError)
			log.Printf("admin chunk merge: %v", err)
			return
		}
		log.Printf("[security] music chunk upload complete file=%q chunks=%d by=ip:%s",
			finalName, total, clientIPFromRequest(r))
		resp["complete"] = true
		resp["saved"] = finalName
	}
	if saved {
		log.Printf("music chunk upload: id=%s index=%d/%d", uploadID, index+1, total)
	}
	writeJSON(w, http.StatusOK, resp)
}

// saveChunk 校验单片 SHA-256 后原子落盘;重复片幂等(返回 saved=false),但
// 已存在分片与新片 SHA 不一致时报 409——静默接受旧分片会让断点续传把损坏
// 内容合并入库,且上传者无从得知结果与意图不符。
func (s *musicServer) saveChunk(uploadID string, index int, chunkSHA string, header *multipart.FileHeader) (bool, error) {
	partPath := filepath.Join(chunkDir(uploadID), fmt.Sprintf("%06d.part", index))
	if existing, err := os.ReadFile(partPath); err == nil {
		sum := sha256.Sum256(existing)
		if hex.EncodeToString(sum[:]) == chunkSHA {
			return false, nil
		}
		return false, chunkErr("同序号分片已存在且内容不一致,请更换 uploadId 重传", http.StatusConflict)
	} else if !os.IsNotExist(err) {
		return false, err
	}
	src, err := header.Open()
	if err != nil {
		return false, err
	}
	defer src.Close()

	tmp, err := os.CreateTemp(chunkDir(uploadID), ".chunk-*")
	if err != nil {
		return false, err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	hasher := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, hasher), src); err != nil {
		tmp.Close()
		return false, err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return false, err
	}
	if err := tmp.Close(); err != nil {
		return false, err
	}
	if got := hex.EncodeToString(hasher.Sum(nil)); got != chunkSHA {
		return false, chunkErr("分片校验失败,请重传该分片", http.StatusConflict)
	}
	if err := os.Rename(tmpName, partPath); err != nil {
		return false, err
	}
	return true, nil
}

// chunk 合并的一次性守卫:重传最后一片(如超时重试)会让多个请求同时看到
// 「收齐」并各自执行合并,先完成者清理分片目录后,其余请求对已删除目录拷贝
// 报错——文件实际已入库却返回失败。serialize + 结果缓存保证同一 uploadId
// 只合并一次;条目由延迟删除兜底回收。
var (
	chunkMergeMu     sync.Mutex
	chunkMergedNames = map[string]string{}
)

func (s *musicServer) mergeChunkOnce(uploadID string, total int) (string, error) {
	chunkMergeMu.Lock()
	defer chunkMergeMu.Unlock()
	if name, ok := chunkMergedNames[uploadID]; ok {
		return name, nil
	}
	name, err := s.mergeChunks(uploadID, total)
	if err == nil {
		chunkMergedNames[uploadID] = name
		time.AfterFunc(10*time.Minute, func() {
			chunkMergeMu.Lock()
			delete(chunkMergedNames, uploadID)
			chunkMergeMu.Unlock()
		})
	}
	return name, err
}

// mergeChunks 按序拼接全部分片,校验总大小后原子入库,清理分片目录。
func (s *musicServer) mergeChunks(uploadID string, total int) (string, error) {
	meta, err := readChunkMeta(uploadID)
	if err != nil {
		return "", err
	}
	rc, err := receivedChunks(uploadID)
	if err != nil {
		return "", err
	}
	if len(rc) != total {
		return "", chunkErr("分片不完整", http.StatusConflict)
	}
	tmp, err := os.CreateTemp(s.config.LibraryDir, ".music-merge-*")
	if err != nil {
		return "", err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	var totalBytes int64
	for _, idx := range rc {
		f, err := os.Open(filepath.Join(chunkDir(uploadID), fmt.Sprintf("%06d.part", idx)))
		if err != nil {
			tmp.Close()
			return "", err
		}
		n, err := io.Copy(tmp, f)
		f.Close()
		if err != nil {
			tmp.Close()
			return "", err
		}
		totalBytes += n
	}
	// rename 前 fsync,与 saveMusicUpload/saveChunk 的数据保护对称。
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if totalBytes > maxMusicFileBytes {
		return "", chunkErr("文件超过 200MB 上限", http.StatusBadRequest)
	}
	if err := os.Rename(tmpName, filepath.Join(s.config.LibraryDir, meta.FileName)); err != nil {
		return "", err
	}
	if err := os.RemoveAll(chunkDir(uploadID)); err != nil {
		log.Printf("music chunk merge: cleanup %s failed: %v", uploadID, err)
	}
	log.Printf("music chunk merged: id=%s name=%q bytes=%d", uploadID, meta.FileName, totalBytes)
	return meta.FileName, nil
}

// mustJSON 序列化失败直接 panic:meta 结构只含基础类型,不可能失败。
func mustJSON(v any) []byte {
	data, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return data
}

// atomicWriteFile 临时文件 + fsync + rename 原子落盘(与曲库写入数据保护对称)。
func atomicWriteFile(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".atomic-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

// cleanupExpiredChunkUploads 清理超过 TTL 的孤儿分片会话(上传中断不再继续)。
func cleanupExpiredChunkUploads() {
	entries, err := os.ReadDir(uploadChunksDir)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("music chunk cleanup: %v", err)
		}
		return
	}
	cutoff := time.Now().Add(-musicChunkTTL)
	for _, e := range entries {
		if !e.IsDir() || !validUploadID(e.Name()) {
			continue
		}
		info, err := e.Info()
		if err != nil || info.ModTime().After(cutoff) {
			continue
		}
		if err := os.RemoveAll(filepath.Join(uploadChunksDir, e.Name())); err != nil {
			log.Printf("music chunk cleanup: %s: %v", e.Name(), err)
		} else {
			log.Printf("music chunk cleanup: removed expired %s", e.Name())
		}
	}
}

// startChunkCleanupLoop 每小时执行一次过期清理,随进程退出终止。
func startChunkCleanupLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			cleanupExpiredChunkUploads()
		case <-ctx.Done():
			return
		}
	}
}

// ---------- 网易云扫码登录 ----------

const (
	// neteaseLoginSessionTTL 是二维码会话保留时长(网易二维码约 2 分钟有效)。
	neteaseLoginSessionTTL = 3 * time.Minute
)

// neteaseLoginSession 保存一次扫码会话(key 对应的二维码)。
type neteaseLoginSession struct {
	QRImg     string
	CreatedAt time.Time
}

var neteaseLoginMu sync.Mutex

// neteaseLoginSessions key -> session;过期条目惰性清理。
var neteaseLoginSessions = map[string]neteaseLoginSession{}

// extractMusicU 从扫码成功返回的 cookie 串中提取 MUSIC_U 值。
// 不用正则匹配:cookie 值可能含 _ / - / URL 编码字符(%xx),旧的正则
// `[0-9a-zA-Z]+` 会截断导致登录态不完整(扫码成功但解锁静默失败)。
// 按 cookie 语义解析:分号分段后在段内定位 MUSIC_U= 取值到段尾(兼容
// 段间逗号分隔,如 "Path=/, MUSIC_U=xxx"),再做 URL 解码。
func extractMusicU(cookie string) string {
	const prefix = "MUSIC_U="
	for _, part := range strings.Split(cookie, ";") {
		if idx := strings.Index(part, prefix); idx >= 0 {
			raw := strings.TrimSpace(part[idx+len(prefix):])
			if raw == "" {
				return ""
			}
			if dec, err := url.QueryUnescape(raw); err == nil {
				raw = dec
			}
			return raw
		}
	}
	return ""
}

func (s *musicServer) handleAdminNeteaseStart(w http.ResponseWriter, r *http.Request) {
	if !s.netease.enabled() {
		writeError(w, "netease_api 上游未配置", http.StatusServiceUnavailable)
		return
	}
	ts := time.Now().UnixMilli()
	var keyResp struct {
		Data struct {
			Unikey string `json:"unikey"`
		} `json:"data"`
	}
	if err := s.netease.getJSON(r.Context(), fmt.Sprintf("/login/qr/key?timestamp=%d", ts), &keyResp); err != nil || keyResp.Data.Unikey == "" {
		writeError(w, "获取扫码 key 失败", http.StatusBadGateway)
		return
	}
	var qrResp struct {
		Data struct {
			QRImg string `json:"qrimg"`
		} `json:"data"`
	}
	if err := s.netease.getJSON(r.Context(),
		fmt.Sprintf("/login/qr/create?key=%s&qrimg=true&timestamp=%d", url.QueryEscape(keyResp.Data.Unikey), ts), &qrResp); err != nil || qrResp.Data.QRImg == "" {
		writeError(w, "获取二维码失败", http.StatusBadGateway)
		return
	}

	neteaseLoginMu.Lock()
	// 惰性清理过期会话,防止 map 无界增长。
	for k, sess := range neteaseLoginSessions {
		if time.Since(sess.CreatedAt) > neteaseLoginSessionTTL {
			delete(neteaseLoginSessions, k)
		}
	}
	neteaseLoginSessions[keyResp.Data.Unikey] = neteaseLoginSession{
		QRImg:     qrResp.Data.QRImg,
		CreatedAt: time.Now(),
	}
	neteaseLoginMu.Unlock()

	writeJSON(w, http.StatusOK, map[string]string{"key": keyResp.Data.Unikey, "qrimg": qrResp.Data.QRImg})
}

func (s *musicServer) handleAdminNeteasePoll(w http.ResponseWriter, r *http.Request) {
	if s.config.NeteaseCookieFile == "" {
		writeError(w, "未配置 cookie 文件路径", http.StatusServiceUnavailable)
		return
	}
	key := r.URL.Query().Get("key")
	if key == "" {
		writeError(w, "缺少 key 参数", http.StatusBadRequest)
		return
	}
	neteaseLoginMu.Lock()
	_, known := neteaseLoginSessions[key]
	neteaseLoginMu.Unlock()
	if !known {
		writeError(w, "二维码已过期，请重新生成", http.StatusGone)
		return
	}

	var check struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
		Cookie  string `json:"cookie"`
		Profile struct {
			Nickname string `json:"nickname"`
		} `json:"profile"`
	}
	if err := s.netease.getJSON(r.Context(),
		fmt.Sprintf("/login/qr/check?key=%s&timestamp=%d", url.QueryEscape(key), time.Now().UnixMilli()), &check); err != nil {
		writeError(w, "上游请求失败", http.StatusBadGateway)
		return
	}
	switch check.Code {
	case 801, 802:
		writeJSON(w, http.StatusOK, map[string]any{"code": check.Code, "message": check.Message})
	case 803:
		musicU := extractMusicU(check.Cookie)
		if musicU == "" {
			log.Printf("netease login 803 without MUSIC_U cookie")
			writeError(w, "登录成功但未取得凭证，请重试", http.StatusBadGateway)
			return
		}
		// 原子写入 cookie 文件并收紧权限(凭证文件仅属主可读,uid 1001);
		// neteaseClient 检测到 mtime 变化即热加载(30s 内生效)。
		if err := os.MkdirAll(filepath.Dir(s.config.NeteaseCookieFile), 0o755); err != nil {
			writeError(w, "写入凭证失败", http.StatusInternalServerError)
			return
		}
		if err := atomicWriteFile(s.config.NeteaseCookieFile, []byte("MUSIC_U="+musicU), 0o600); err != nil {
			writeError(w, "写入凭证失败", http.StatusInternalServerError)
			return
		}
		// 会话一次性,防 key 复用。
		neteaseLoginMu.Lock()
		delete(neteaseLoginSessions, key)
		neteaseLoginMu.Unlock()
		log.Printf("[security] netease login success nickname=%q by=ip:%s",
			check.Profile.Nickname, clientIPFromRequest(r))
		writeJSON(w, http.StatusOK, map[string]any{"code": 803, "nickname": check.Profile.Nickname})
	default:
		writeError(w, fmt.Sprintf("扫码状态异常(%d)", check.Code), http.StatusBadGateway)
	}
}

// handleAdminNeteaseState 返回当前登录态:cookie 文件存在即视为已配置,并经
// 上游 login/status 取昵称(上游失败不影响已配置状态的展示)。
func (s *musicServer) handleAdminNeteaseState(w http.ResponseWriter, r *http.Request) {
	info, err := os.Stat(s.config.NeteaseCookieFile)
	if err != nil {
		if os.IsNotExist(err) {
			writeJSON(w, http.StatusOK, map[string]any{"loggedIn": false})
			return
		}
		writeError(w, "读取凭证状态失败", http.StatusInternalServerError)
		return
	}
	resp := map[string]any{
		"loggedIn":  true,
		"updatedAt": info.ModTime().Format(time.RFC3339),
	}
	var status struct {
		Profile struct {
			Nickname string `json:"nickname"`
		} `json:"profile"`
	}
	if s.netease.getJSON(r.Context(),
		fmt.Sprintf("/login/status?timestamp=%d", time.Now().UnixMilli()), &status) == nil &&
		status.Profile.Nickname != "" {
		resp["nickname"] = status.Profile.Nickname
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleAdminNeteaseLogout 删除 cookie 文件(neteaseClient 检测到文件消失即回匿名)。
func (s *musicServer) handleAdminNeteaseLogout(w http.ResponseWriter, r *http.Request) {
	if err := os.Remove(s.config.NeteaseCookieFile); err != nil && !os.IsNotExist(err) {
		writeError(w, "登出失败", http.StatusInternalServerError)
		return
	}
	log.Printf("[security] netease logout by=ip:%s", clientIPFromRequest(r))
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
