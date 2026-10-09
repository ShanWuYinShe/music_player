package main

import (
	"log"
	"os"
	"strconv"
)

// getEnv 读取环境变量,缺省返回 fallback。
// 统一从这里读环境变量,禁止散落各处的 os.Getenv 直调。
func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// getEnvInt 读取整型环境变量:缺失返回 fallback;存在但非法/非正数时记
// 警告日志后回退 fallback——如 RATE_LIMIT_PER_MINUTE=abc 被静默当成 120
// 会让排障走弯路。ParseUint 按平台 int 位宽解析,同时拒绝正负号并天然
// 拒绝手写 n*10 累加的超长数字串溢出环绕。
func getEnvInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.ParseUint(v, 10, strconv.IntSize)
	if err != nil || n == 0 {
		log.Printf("config: %s=%q invalid, using default %d", key, v, fallback)
		return fallback
	}
	return int(n)
}
