package main

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

// writeTestFile 在临时目录写文件并返回 *os.File 路径与句柄。
func writeTestFile(t *testing.T, name string, data []byte) *os.File {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return f
}

// mp3 CBR 估算：128kbps × N 字节 ≈ bytes/16000 ms。
func TestMp3DurationCBR(t *testing.T) {
	audio := make([]byte, 160000)               // 10s @128kbps
	copy(audio, []byte{0xFF, 0xFB, 0x90, 0x00}) // MPEG1 L3 128kbps 44100Hz 立体声
	f := writeTestFile(t, "a.mp3", audio)
	got := probeAudioDuration(f, ".mp3", 160000)
	// 估算值允许 ±2% 容差
	if got < 9800 || got > 10200 {
		t.Fatalf("expect ~10000ms CBR, got %d", got)
	}
}

// mp3 带 ID3v2/ID3v1 标签：标签字节不计入音频时长。
func TestMp3DurationWithTags(t *testing.T) {
	id3v2 := append([]byte("ID3"), []byte{3, 0, 0, 0, 0, 0, 0, 100}...) // 头10B+body100B
	audio := make([]byte, 160000)
	copy(audio, []byte{0xFF, 0xFB, 0x90, 0x00})
	id3v1 := append([]byte("TAG"), make([]byte, 125)...)
	data := append(append(id3v2, audio...), id3v1...)
	f := writeTestFile(t, "b.mp3", data)
	got := probeAudioDuration(f, ".mp3", int64(len(data)))
	if got < 9800 || got > 10200 {
		t.Fatalf("expect ~10000ms (tags excluded), got %d", got)
	}
}

// mp3 VBR Xing 帧数精确时长。
func TestMp3DurationXing(t *testing.T) {
	frame := make([]byte, 417)
	copy(frame, []byte{0xFF, 0xFB, 0x90, 0x00}) // MPEG1 L3 44100 立体声 → Xing@36
	copy(frame[36:], "Xing")
	binary.BigEndian.PutUint32(frame[40:], 0x01) // flags: frames 存在
	binary.BigEndian.PutUint32(frame[44:], 382)  // 382 帧 × 1152 / 44100 ≈ 9.98s
	f := writeTestFile(t, "c.mp3", frame)
	got := probeAudioDuration(f, ".mp3", 417)
	if got < 9900 || got > 10100 {
		t.Fatalf("expect ~9980ms Xing, got %d", got)
	}
}

// flac STREAMINFO 精确时长。
func TestFlacDuration(t *testing.T) {
	var buf []byte
	buf = append(buf, "fLaC"...)
	buf = append(buf, 0x80, 0, 0, 34)      // last+type=STREAMINFO, len=34
	buf = append(buf, make([]byte, 10)...) // minBS/maxBS/minFS/maxFS
	v := uint64(44100)<<44 | 441000        // 44100Hz × 441000 samples = 10s
	for i := 7; i >= 0; i-- {
		buf = append(buf, byte(v>>(8*uint(i))))
	}
	buf = append(buf, make([]byte, 16)...) // STREAMINFO 剩余字段(MD5 等)
	f := writeTestFile(t, "a.flac", buf)
	got := probeAudioDuration(f, ".flac", int64(len(buf)))
	if got < 9990 || got > 10010 {
		t.Fatalf("expect ~10000ms, got %d", got)
	}
}

// m4a mvhd 时长（扫描流中 mvhd 标记）。
func TestMp4Duration(t *testing.T) {
	var buf []byte
	buf = append(buf, []byte{0, 0, 0, 32}...) // box size
	buf = append(buf, "mvhd"...)
	buf = append(buf, 0)                  // version 0
	buf = append(buf, make([]byte, 3)...) // flags
	buf = append(buf, make([]byte, 8)...) // creation/modification
	var tmp [4]byte
	binary.BigEndian.PutUint32(tmp[:], 1000) // timescale
	buf = append(buf, tmp[:]...)
	binary.BigEndian.PutUint32(tmp[:], 10000) // 10s
	buf = append(buf, tmp[:]...)
	buf = append(buf, make([]byte, 8)...) // rate/volume 等余量
	f := writeTestFile(t, "a.m4a", buf)
	got := probeAudioDuration(f, ".m4a", int64(len(buf)))
	if got != 10000 {
		t.Fatalf("expect 10000ms, got %d", got)
	}
}

// wav fmt.byteRate + data.size。
func TestWavDuration(t *testing.T) {
	var buf []byte
	buf = append(buf, "RIFF"...)
	var tmp [4]byte
	binary.LittleEndian.PutUint32(tmp[:], 100)
	buf = append(buf, tmp[:]...)
	buf = append(buf, "WAVEfmt "...)
	binary.LittleEndian.PutUint32(tmp[:], 16)
	buf = append(buf, tmp[:]...)
	fmtChunk := make([]byte, 16)
	binary.LittleEndian.PutUint16(fmtChunk[0:], 1) // PCM
	binary.LittleEndian.PutUint16(fmtChunk[2:], 2) // stereo
	binary.LittleEndian.PutUint32(fmtChunk[4:], 44100)
	binary.LittleEndian.PutUint32(fmtChunk[8:], 176400) // byteRate
	buf = append(buf, fmtChunk...)
	buf = append(buf, "data"...)
	binary.LittleEndian.PutUint32(tmp[:], 1764000) // 10s
	buf = append(buf, tmp[:]...)
	buf = append(buf, make([]byte, 64)...)
	f := writeTestFile(t, "a.wav", buf)
	got := probeAudioDuration(f, ".wav", int64(len(buf)))
	if got != 10000 {
		t.Fatalf("expect 10000ms, got %d", got)
	}
}

// ogg/opus 尾页 granulepos（48000Hz 恒定）。
func TestOggDuration(t *testing.T) {
	head := make([]byte, 512)
	copy(head, "OggS")
	var tail []byte
	tail = append(tail, make([]byte, 485)...) // 页与头拉开距离,确保向前扫描命中尾页
	page := make([]byte, 27)
	copy(page, "OggS")
	binary.LittleEndian.PutUint64(page[6:], 480000) // 10s @48kHz
	tail = append(tail, page...)
	data := append(append([]byte{}, head...), tail...)
	f := writeTestFile(t, "a.opus", data)
	got := probeAudioDuration(f, ".opus", int64(len(data)))
	if got != 10000 {
		t.Fatalf("expect 10000ms, got %d", got)
	}
}

// 垃圾输入与未知格式一律返回 0,不报错。
func TestDurationGarbageInput(t *testing.T) {
	f := writeTestFile(t, "x.mp3", []byte("not an mp3 at all"))
	if got := probeAudioDuration(f, ".mp3", 19); got != 0 {
		t.Fatalf("garbage mp3 expect 0, got %d", got)
	}
	f2 := writeTestFile(t, "x.flac", []byte("garbage"))
	if got := probeAudioDuration(f2, ".flac", 7); got != 0 {
		t.Fatalf("garbage flac expect 0, got %d", got)
	}
	f3 := writeTestFile(t, "x.xyz", []byte("anything"))
	if got := probeAudioDuration(f3, ".xyz", 8); got != 0 {
		t.Fatalf("unknown ext expect 0, got %d", got)
	}
}

// 真实服务器曲库样本(如有):周杰伦-你听得到.mp3 无法离线构造,时长解析
// 覆盖由上面合成结构保证;线上验证在部署后做。
