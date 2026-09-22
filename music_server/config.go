package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

// AppConfig 是服务运行配置,全部来自环境变量。
type AppConfig struct {
	Host               string
	Port               string
	LibraryDir         string
	RateLimitPerMinute int
	// NeteaseAPIBase 是私有部署的 NeteaseCloudMusicApi(Enhanced)上游地址,
	// 空 = 禁用网络源(仅本地曲库)。
	NeteaseAPIBase string
	// NeteaseCookie 可选:网易账号 cookie(如 "MUSIC_U=..."),透传给上游
	// 解锁登录态曲目与完整音频(免费匿名部分曲目只有试听片段)。
	NeteaseCookie string
	// NeteaseCookieFile 可选:cookie 文件路径(管理面板扫码登录写入),
	// 热加载,优先于 NeteaseCookie。
	NeteaseCookieFile string
	// AppToken 可选:配置后全部业务端点要求 X-App-Token 头(常量时间比较),
	// 与 media_server 的 MEDIA_SERVER_APP_API_TOKEN 同构。空 = 不鉴权,
	// 保持既有行为(依赖边缘 CF mTLS);设置后作为边缘误配/内网横向的兜底。
	AppToken string
	// AdminToken 可选:/admin/api/v1/* 站内管理端点(曲库上传/网易云登录)
	// 要求 X-Admin-Token 头。空 = 仅依赖边缘 nginx basic auth(个人站默认);
	// 设置后作为边缘误配/内网横向的兜底。
	AdminToken string
}

// Addr 返回监听地址。
func (c AppConfig) Addr() string {
	return c.Host + ":" + c.Port
}

// loadAppConfig 从环境变量装配配置并做必要校验。
func loadAppConfig() (AppConfig, error) {
	config := AppConfig{
		Host:               getEnv("HOST", "0.0.0.0"),
		Port:               getEnv("PORT", "8790"),
		LibraryDir:         getEnv("LIBRARY_DIR", "/data/library"),
		RateLimitPerMinute: getEnvInt("RATE_LIMIT_PER_MINUTE", 120),
		NeteaseAPIBase:     strings.TrimRight(getEnv("NETEASE_API_BASE", ""), "/"),
		NeteaseCookie:      getEnv("NETEASE_MUSIC_COOKIE", ""),
		NeteaseCookieFile:  getEnv("NETEASE_COOKIE_FILE", ""),
		AppToken:           strings.TrimSpace(getEnv("MUSIC_SERVER_APP_API_TOKEN", "")),
		AdminToken:         strings.TrimSpace(getEnv("MUSIC_SERVER_ADMIN_TOKEN", "")),
	}
	if config.Port == "" {
		return AppConfig{}, errors.New("PORT is required")
	}
	if config.LibraryDir == "" {
		return AppConfig{}, errors.New("LIBRARY_DIR is required")
	}
	if info, err := os.Stat(config.LibraryDir); err != nil || !info.IsDir() {
		return AppConfig{}, fmt.Errorf("library dir %s unavailable: %w", config.LibraryDir, err)
	}
	return config, nil
}
