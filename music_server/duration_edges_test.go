package main

import (
	"encoding/binary"
	"testing"
)

// putBE32 写 4 字节大端整数(测试内构造 box 用)。
func putBE32(v uint32) []byte {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], v)
	return b[:]
}

// mvhdBox 构造一个 mvhd box 内容(version 0 或 1)。
func mvhdBox(version byte, timescale, duration uint64) []byte {
	var buf []byte
	if version == 0 {
		// size(4) + "mvhd" + version+flags(4) + ctime/mtime(8) + ts(4) + dur(4) + 余量(80)
		buf = append(buf, putBE32(120)...)
		buf = append(buf, "mvhd"...)
		buf = append(buf, 0)
		buf = append(buf, make([]byte, 3)...)
		buf = append(buf, make([]byte, 8)...)
		buf = append(buf, putBE32(uint32(timescale))...)
		buf = append(buf, putBE32(uint32(duration))...)
		buf = append(buf, make([]byte, 80)...)
		return buf
	}
	// version 1:ctime/mtime(16) + ts(4) + dur(8)
	buf = append(buf, putBE32(132)...)
	buf = append(buf, "mvhd"...)
	buf = append(buf, 1)
	buf = append(buf, make([]byte, 3)...)
	buf = append(buf, make([]byte, 16)...)
	buf = append(buf, putBE32(uint32(timescale))...)
	var d [8]byte
	binary.BigEndian.PutUint64(d[:], duration)
	buf = append(buf, d[:]...)
	buf = append(buf, make([]byte, 60)...)
	return buf
}

// TestMp4DurationMvhdVersion1 64 位 duration 形态(version 1):此前未覆盖,
// 超过 32 位表示范围的时长只有该形态能表达。
func TestMp4DurationMvhdVersion1(t *testing.T) {
	var buf []byte
	buf = append(buf, make([]byte, 8)...) // ftun 占位:moov 前的杂项
	buf = append(buf, mvhdBox(1, 1000, 12345678)...)
	f := writeTestFile(t, "v1.m4a", buf)
	if got := probeAudioDuration(f, ".m4a", int64(len(buf))); got != 12345678 {
		t.Fatalf("v1 mvhd expect 12345678ms, got %d", got)
	}
}

// TestMp4DurationMoovAtTail 流式写出的文件 moov 在尾部:头部 256KB 找不到
// 时必须回扫尾部 4MB(此前该分支未覆盖)。
func TestMp4DurationMoovAtTail(t *testing.T) {
	var buf []byte
	buf = append(buf, make([]byte, 300*1024)...) // 300KB 前导杂项(大于头部读窗)
	buf = append(buf, mvhdBox(0, 1000, 42424)...)
	f := writeTestFile(t, "tail.m4a", buf)
	if got := probeAudioDuration(f, ".m4a", int64(len(buf))); got != 42424 {
		t.Fatalf("tail moov expect 42424ms, got %d", got)
	}
}

// TestScanMvhdAdvancesPastBadCandidates "mvhd" 出现在无效位置时必须逐字节
// 推进继续找,而不是直接放弃——把真 mvhd 藏在一段伪 mvhd 字节之后。
func TestScanMvhdAdvancesPastBadCandidates(t *testing.T) {
	var buf []byte
	// 伪候选:mvhd 后紧跟的 version 会把解析引向越界/非法,应被跳过
	buf = append(buf, putBE32(8)...)
	buf = append(buf, "mvhd"...)
	buf = append(buf, mvhdBox(0, 1000, 9000)...)
	f := writeTestFile(t, "adv.m4a", buf)
	if got := probeAudioDuration(f, ".m4a", int64(len(buf))); got != 9000 {
		t.Fatalf("expect to find the real mvhd (9000ms), got %d", got)
	}
}

// TestMp4DurationRejectsBadValues timescale/duration 为 0 或全 1(流式占位)
// 时必须返回 0(未知),不能除零或给出天文数字。
func TestMp4DurationRejectsBadValues(t *testing.T) {
	cases := []struct {
		name    string
		ts, dur uint64
	}{
		{"zero timescale", 0, 10000},
		{"zero duration", 1000, 0},
		{"v0 all-ones duration", 1000, 0xFFFFFFFF}, // 流式占位
	}
	for _, c := range cases {
		var buf []byte
		buf = append(buf, mvhdBox(0, c.ts, c.dur)...)
		f := writeTestFile(t, "bad_"+c.name+".m4a", buf)
		if got := probeAudioDuration(f, ".m4a", int64(len(buf))); got != 0 {
			t.Fatalf("%s: expect 0, got %d", c.name, got)
		}
	}
}

// TestWavDurationChunkWalkTraps wav chunk 遍历的三个陷阱:未知块跳过、
// chunkLen=0 防死循环、fmt 在 data 之后仍能读到。
// putLE32 写 4 字节小端整数(RIFF/wav 全部为小端)。
func putLE32(v uint32) []byte {
	var b [4]byte
	binary.LittleEndian.PutUint32(b[:], v)
	return b[:]
}

// TestWavDurationChunkWalkTraps wav chunk 遍历:未知块跳过、零长块不再中断
// 遍历(实测发现并修复的 bug)、fmt 在 data 之后拿不到 byteRate。all LE。
func TestWavDurationChunkWalkTraps(t *testing.T) {
	build := func(fmtAfterData bool, listLen uint32) []byte {
		var buf []byte
		buf = append(buf, "RIFF"...)
		buf = append(buf, putLE32(0)...) // 总长占位(解析不读)
		buf = append(buf, "WAVE"...)
		writeFmt := func() {
			buf = append(buf, "fmt "...)
			buf = append(buf, putLE32(16)...)
			// fmt data 前 8 字节是 audioFormat/channels/sampleRate,byteRate 在偏移 8
			buf = append(buf, make([]byte, 8)...)
			buf = append(buf, putLE32(176400)...)
			buf = append(buf, make([]byte, 4)...)
		}
		if !fmtAfterData {
			writeFmt()
		}
		// LIST 块(未知块,须跳过;listLen 可为 0——合法零长块)
		buf = append(buf, "LIST"...)
		buf = append(buf, putLE32(listLen)...)
		if listLen > 0 {
			buf = append(buf, make([]byte, listLen)...)
		}
		buf = append(buf, "data"...)
		buf = append(buf, putLE32(1764000)...) // 10s
		if fmtAfterData {
			writeFmt()
		}
		return buf
	}
	// 常规:fmt 在 data 前
	f := writeTestFile(t, "w1.wav", build(false, 8))
	if got := probeAudioDuration(f, ".wav", int64(1<<20)); got != 10000 {
		t.Fatalf("normal wav expect 10000ms, got %d", got)
	}
	// 零长 LIST(合法零长块):应跳过继续找 data,而不是中断整趟遍历
	// (修复前 chunkLen==0 直接 break,已入库音频的时长恒为 0)
	f3 := writeTestFile(t, "w3.wav", build(false, 0))
	if got := probeAudioDuration(f3, ".wav", int64(1<<20)); got != 10000 {
		t.Fatalf("zero-len LIST must be skipped, expect 10000ms, got %d", got)
	}
	// fmt 在 data 之后:解析在 data 处 break,拿不到 byteRate → 0(如实固定现状)
	f2 := writeTestFile(t, "w2.wav", build(true, 8))
	if got := probeAudioDuration(f2, ".wav", int64(1<<20)); got != 0 {
		t.Fatalf("fmt-after-data expect 0 (byteRate unread), got %d", got)
	}
}
func TestMp3DurationID3v2OnlyGarbageTagSize(t *testing.T) {
	var buf []byte
	buf = append(buf, "ID3"...)
	buf = append(buf, 3, 0) // v2.3
	buf = append(buf, 0)    // flags
	// syncsafe size = 0x7F*1<<21,声明远超文件实际大小
	buf = append(buf, 0x7F, 0x7F, 0x7F, 0x7F)
	f := writeTestFile(t, "hugeid3.mp3", buf)
	if got := probeAudioDuration(f, ".mp3", int64(len(buf))); got != 0 {
		t.Fatalf("oversized ID3v2 expect 0, got %d", got)
	}
}
