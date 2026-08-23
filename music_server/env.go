package main

import "os"

// getEnv 读取环境变量,缺省返回 fallback。
// 统一从这里读环境变量,禁止散落各处的 os.Getenv 直调。
func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// getEnvInt 读取整型环境变量,缺失或非法时返回 fallback 并记日志由调用方决定。
func getEnvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		n := 0
		ok := true
		for _, r := range v {
			if r < '0' || r > '9' {
				ok = false
				break
			}
			n = n*10 + int(r-'0')
		}
		if ok && n > 0 {
			return n
		}
	}
	return fallback
}
