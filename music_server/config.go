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
	// 解锁登录态曲目(免费匿名只能播免费曲目)。
	NeteaseCookie string
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
