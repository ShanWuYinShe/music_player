package main

import "testing"

// getEnvInt 合法数字直接采用;缺失/非数字/0 与负号等非法输入一律回退默认值
// (解析按纯数字逐字符累加,前导空格与正负号都视为非法,不 trim)。
func TestGetEnvInt(t *testing.T) {
	cases := []struct {
		value    string
		fallback int
		want     int
	}{
		{"120", 60, 120},               // 合法值直接采用
		{"007", 60, 7},                 // 前导零按数值解析
		{"1234567890", 60, 1234567890}, // 大数值不截断
		{"", 60, 60},                   // 缺失回退
		{"abc", 60, 60},                // 非数字回退
		{"12a", 60, 60},                // 混入字母回退
		{"-5", 60, 60},                 // 负号非法回退
		{"+5", 60, 60},                 // 正号非法回退
		{"0", 60, 60},                  // 0 非法(须 >0)
		{"0000", 60, 60},               // 全零等价 0
		{" 42", 60, 60},                // 前导空格不 trim,非法回退
		{"4 2", 60, 60},                // 内嵌空格非法回退
	}
	for _, c := range cases {
		t.Setenv("TEST_GET_ENV_INT", c.value)
		if got := getEnvInt("TEST_GET_ENV_INT", c.fallback); got != c.want {
			t.Fatalf("getEnvInt(%q, %d) = %d, want %d", c.value, c.fallback, got, c.want)
		}
	}
	// 环境变量缺失(未 Setenv)同样回退。
	if got := getEnvInt("TEST_GET_ENV_INT_MISSING", 60); got != 60 {
		t.Fatalf("missing env = %d, want fallback 60", got)
	}
}
