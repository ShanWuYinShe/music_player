package main

// 音频时长解析：零依赖读取各容器格式的头部/尾部元数据，估算曲目时长。
// 设计约束：
//   - 只读文件头/尾少量字节（≤64KB），大文件（无损整轨几百 MB）成本可控；
//   - 解析失败一律返回 0（未知），不阻塞扫描——客户端 prepared 后仍会回填；
//   - mp3 CBR 是估算（(大小-标签)/平均码率），VBR 优先 Xing/Info 帧数精确值；
//     flac(STREAMINFO)/m4a(mvhd)/wav(fmt+data) 均为容器精确值；ogg/opus 取
//     最后一页 granulepos（精确）。
//
// 各格式位域解析参考公开容器规范（ID3v2 / MPEG audio header / FLAC
// format / ISO 14496-12 / RIFF / Ogg framing）。

import (
	"bytes"
	"encoding/binary"
	"io"
	"os"
)

// probeAudioDuration 返回音频文件时长（毫秒）；解析失败返回 0。
// f 由调用方打开并负责关闭，实现内部只做 Read/Seek。
func probeAudioDuration(f *os.File, ext string, size int64) int64 {
	switch ext {
	case ".mp3":
		return mp3Duration(f, size)
	case ".flac":
		return flacDuration(f)
	case ".m4a", ".mp4", ".aac":
		return mp4Duration(f, size)
	case ".wav":
		return wavDuration(f)
	case ".ogg", ".oga", ".opus":
		return oggDuration(f)
	default:
		return 0
	}
}

// readAtFull 读取 [off, off+len) 全部字节；越界/错误返回 nil。
func readAtFull(f *os.File, off int64, n int) []byte {
	buf := make([]byte, n)
	got, err := f.ReadAt(buf, off)
	if err != nil && err != io.EOF {
		return nil
	}
	if got < n {
		return buf[:got]
	}
	return buf
}

// ---- mp3 ----

// mpeg1Layer3Bitrates MPEG1 Layer3 码率表（kbps，index 0 无效）。
var mpeg1Layer3Bitrates = [16]int{0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0}

// mpeg2Layer3Bitrates MPEG2/2.5 Layer3 码率表。
var mpeg2Layer3Bitrates = [16]int{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0}

// mpegSampleRates [version][index]；version: 0=MPEG2.5, 1=保留, 2=MPEG2, 3=MPEG1。
var mpegSampleRates = [4][3]int{
	{11025, 12000, 8000},  // MPEG2.5
	{0, 0, 0},             // 保留
	{22050, 24000, 16000}, // MPEG2
	{44100, 48000, 32000}, // MPEG1
}

// mp3Duration：跳过 ID3v2 找第一帧，优先 Xing/Info 帧数精确时长，
// 否则 CBR 估算。ID3v1 尾标签（128B）从大小中扣除。
func mp3Duration(f *os.File, size int64) int64 {
	head := readAtFull(f, 0, 64*1024)
	if head == nil {
		return 0
	}
	audioStart := int64(0)
	audioEnd := size
	// ID3v2: "ID3" ver ver flags size(4, syncsafe)
	if len(head) > 10 && head[0] == 'I' && head[1] == 'D' && head[2] == '3' {
		sz := int64(head[6]&0x7f)<<21 | int64(head[7]&0x7f)<<14 |
			int64(head[8]&0x7f)<<7 | int64(head[9]&0x7f)
		audioStart = 10 + sz
	}
	// ID3v1: 尾部 "TAG" + 125 字节
	tail := readAtFull(f, size-128, 128)
	if len(tail) == 128 && tail[0] == 'T' && tail[1] == 'A' && tail[2] == 'G' {
		audioEnd = size - 128
	}
	if audioStart >= audioEnd || audioStart >= int64(len(head)) {
		return 0
	}
	// 找帧同步 0xFF Ex（允许最多跳过少量垃圾字节）
	frameOff := int64(-1)
	for i := int(audioStart); i+4 <= len(head); i++ {
		if head[i] == 0xFF && head[i+1]&0xE0 == 0xE0 && head[i+1]&0x06 != 0 {
			frameOff = int64(i)
			break
		}
	}
	if frameOff < 0 {
		return 0
	}
	h := head[frameOff : frameOff+4]
	ver := (h[1] >> 3) & 0x03   // 3=MPEG1 2=MPEG2 0=MPEG2.5
	layer := (h[1] >> 1) & 0x03 // 1=Layer3
	brIdx := (h[2] >> 4) & 0x0F // 码率索引
	srIdx := (h[2] >> 2) & 0x03 // 采样率索引
	if ver == 1 || layer != 1 || brIdx == 0 || brIdx == 15 || srIdx == 3 {
		return 0
	}
	sampleRate := mpegSampleRates[ver][srIdx]
	if sampleRate == 0 {
		return 0
	}
	// Layer3 每帧样本数：MPEG1=1152，MPEG2/2.5=576
	samplesPerFrame := 1152
	if ver != 3 {
		samplesPerFrame = 576
	}
	bitrateKbps := mpeg1Layer3Bitrates[brIdx]
	if ver != 3 {
		bitrateKbps = mpeg2Layer3Bitrates[brIdx]
	}
	// Xing/Info 帧计数（VBR 精确）：偏移依赖声道模式（MPEG1 立体声 36，单声道 21；MPEG2 21/13）
	channelMode := h[3] >> 6
	xingOff := 21
	if ver == 3 && channelMode != 3 {
		xingOff = 36
	} else if ver != 3 && channelMode != 3 {
		xingOff = 21
	} else if ver != 3 {
		xingOff = 13
	}
	if int(frameOff)+xingOff+8 < len(head) {
		tag := head[frameOff+int64(xingOff) : frameOff+int64(xingOff)+4]
		if string(tag) == "Xing" || string(tag) == "Info" {
			flags := binary.BigEndian.Uint32(head[frameOff+int64(xingOff)+4:])
			if flags&0x01 != 0 { // frames 字段存在
				frames := binary.BigEndian.Uint32(head[frameOff+int64(xingOff)+8:])
				return int64(frames) * int64(samplesPerFrame) * 1000 / int64(sampleRate)
			}
		}
	}
	// CBR 估算
	audioBytes := audioEnd - frameOff
	if audioBytes <= 0 || bitrateKbps == 0 {
		return 0
	}
	return audioBytes * 8 * 1000 / int64(bitrateKbps*1000)
}

// ---- flac ----

// flacDuration 解析 STREAMINFO：sampleRate(20bit) + totalSamples(36bit)。
func flacDuration(f *os.File) int64 {
	head := readAtFull(f, 0, 128)
	if head == nil || len(head) < 42 {
		return 0
	}
	if string(head[0:4]) != "fLaC" {
		return 0
	}
	// 第一个 metadata block 应为 STREAMINFO(type 0)
	blockHeader := head[4]
	blockType := blockHeader & 0x7F
	blockLen := int(head[5])<<16 | int(head[6])<<8 | int(head[7])
	if blockType != 0 || blockLen < 18 || 8+blockLen > len(head) {
		return 0
	}
	info := head[8 : 8+blockLen]
	// 布局：18 字节 = minBS(2) maxBS(2) minFS(3) maxFS(3) 后接
	// sampleRate 20bit | channels 3bit | bps 5bit | totalSamples 36bit
	v := binary.BigEndian.Uint64(info[10:18])
	sampleRate := int64(v >> 44)
	totalSamples := int64(v & 0xFFFFFFFFF)
	if sampleRate == 0 || totalSamples == 0 {
		return 0
	}
	return totalSamples * 1000 / sampleRate
}

// ---- m4a/mp4 ----

// mp4Duration 遍历顶层 box 找 moov→mvhd；moov 可能在文件尾（正常写完的
// 文件在头，流式写出的在尾），先读头部 256KB，找不到再扫尾部 4MB。
func mp4Duration(f *os.File, size int64) int64 {
	if d := scanMvhd(readAtFull(f, 0, 256*1024)); d > 0 {
		return d
	}
	tailStart := size - 4*1024*1024
	if tailStart < 0 {
		tailStart = 0
	}
	return scanMvhd(readAtFull(f, tailStart, int(size-tailStart)))
}

// mvhdMarker 是 mp4 盒类型标记,scanMvhd 用 bytes.Index 跳跃定位。
var mvhdMarker = []byte("mvhd")

// scanMvhd 在字节流中定位 "mvhd" 并解析 timescale/duration（版本 0/1）。
// 外层门槛按版本 0 的最小 body(20B)放行,版本 1 在分支内再校验长度。
// 逐个候选位置推进(off=i+1),与原逐字节扫描语义一致,只是用 Index 跳过
// 无标记区间。
func scanMvhd(b []byte) int64 {
	for off := 0; off+24 <= len(b); {
		i := bytes.Index(b[off:], mvhdMarker)
		if i < 0 {
			return 0
		}
		i += off
		if i+24 > len(b) {
			return 0
		}
		body := b[i+4:]
		version := body[0]
		if version == 1 {
			if len(body) >= 32 {
				timescale := binary.BigEndian.Uint32(body[20:24])
				duration := binary.BigEndian.Uint64(body[24:32])
				if timescale > 0 && duration > 0 {
					return int64(duration) * 1000 / int64(timescale)
				}
			}
		} else {
			timescale := binary.BigEndian.Uint32(body[12:16])
			duration := binary.BigEndian.Uint32(body[16:20])
			if timescale > 0 && duration > 0 && duration != 0xFFFFFFFF {
				return int64(duration) * 1000 / int64(timescale)
			}
		}
		off = i + 1
	}
	return 0
}

// ---- wav ----

// wavDuration 解析 RIFF：fmt 块 byteRate + data 块大小。
func wavDuration(f *os.File) int64 {
	head := readAtFull(f, 0, 512)
	if head == nil || len(head) < 44 {
		return 0
	}
	if string(head[0:4]) != "RIFF" || string(head[8:12]) != "WAVE" {
		return 0
	}
	var byteRate uint32
	var dataSize uint32
	pos := 12
	for pos+8 <= len(head) {
		id := string(head[pos : pos+4])
		chunkLen := int(binary.LittleEndian.Uint32(head[pos+4 : pos+8]))
		if id == "fmt " && pos+8+16 <= len(head) {
			byteRate = binary.LittleEndian.Uint32(head[pos+16 : pos+20])
		}
		if id == "data" {
			dataSize = binary.LittleEndian.Uint32(head[pos+4 : pos+8])
			break
		}
		pos += 8 + chunkLen
		if chunkLen == 0 || chunkLen > len(head) {
			break
		}
	}
	if byteRate == 0 || dataSize == 0 {
		return 0
	}
	return int64(dataSize) * 1000 / int64(byteRate)
}

// ---- ogg/opus ----

// oggPageMarker 是 Ogg 页同步标记,尾页回扫用 bytes.LastIndex 定位。
var oggPageMarker = []byte("OggS")

// oggDuration：尾页 granulepos 即总样本数，除以采样率。
// opus 头声明 48000 恒定；vorbis 采样率在首页 identification header。
func oggDuration(f *os.File) int64 {
	const tailLen = 128 * 1024
	buf := readAtFull(f, 0, 512)
	if buf == nil || len(buf) < 35 || string(buf[0:4]) != "OggS" {
		return 0
	}
	sampleRate := int64(48000) // opus 默认
	if len(buf) > 35+10 && string(buf[28:35]) == "\x01vorbis" {
		// vorbis identification header: 版本后 4 字节采样率(LE)
		sampleRate = int64(binary.LittleEndian.Uint32(buf[39:43]))
	}
	if sampleRate == 0 {
		return 0
	}
	var size int64
	if info, err := f.Seek(0, io.SeekEnd); err == nil {
		size = info
	}
	if size == 0 {
		return 0
	}
	start := size - tailLen
	if start < 0 {
		start = 0
	}
	tail := readAtFull(f, start, int(size-start))
	// 从尾向前找最后一个 granulepos 非零的 "OggS" 页头,granulepos 在页头
	// offset 6（8 字节 LE）;用 LastIndex 逐页回退,语义与原逐字节回扫一致。
	rest := tail
	for len(rest) >= 14 {
		i := bytes.LastIndex(rest, oggPageMarker)
		if i < 0 {
			break
		}
		if i+14 <= len(rest) {
			if granule := int64(binary.LittleEndian.Uint64(rest[i+6 : i+14])); granule > 0 {
				return granule * 1000 / sampleRate
			}
		}
		rest = rest[:i]
	}
	return 0
}
