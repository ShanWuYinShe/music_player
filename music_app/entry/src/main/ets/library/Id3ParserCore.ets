import { fileIo as fs } from '@kit.CoreFileKit';
import { taskpool, util } from '@kit.ArkTS';

/**
 * ID3v2 标签解析结果（无标签时字段为空）
 */
export interface Id3Tag {
  title: string;
  artist: string;
  album: string;
  /** 封面图片数据，无封面时为空 */
  coverData: Uint8Array | null;
}

const TAG_HEADER_SIZE = 10;
const MAX_TAG_SIZE = 5 * 1024 * 1024; // 防御超大内嵌封面

/**
 * mp3 ID3v2.3 / ID3v2.4 轻量解析：提取歌名/歌手/专辑/封面。
 * v2.2 及无标签文件返回空字段，由调用方用文件名兜底。
 */
export function parseId3(filePath: string): Id3Tag {
  const empty: Id3Tag = { title: '', artist: '', album: '', coverData: null };
  let file: fs.File | null = null;
  try {
    file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
    const header = new ArrayBuffer(TAG_HEADER_SIZE);
    const headerBytes = new Uint8Array(header);
    if (fs.readSync(file.fd, header) < TAG_HEADER_SIZE) {
      return empty;
    }
    if (headerBytes[0] !== 0x49 || headerBytes[1] !== 0x44 || headerBytes[2] !== 0x33) {
      return empty; // 不以 "ID3" 开头
    }
    const majorVersion = headerBytes[3];
    if (majorVersion < 3 || majorVersion > 4) {
      return empty;
    }
    const tagSize = syncSafeInt(headerBytes, 6);
    if (tagSize <= 0 || tagSize > MAX_TAG_SIZE) {
      return empty;
    }
    const tagBuffer = new ArrayBuffer(tagSize);
    const tagBytes = new Uint8Array(tagBuffer);
    if (fs.readSync(file.fd, tagBuffer) < tagSize) {
      return empty;
    }
    return parseFrames(tagBytes, majorVersion);
  } catch {
    return empty;
  } finally {
    if (file) {
      fs.closeSync(file);
    }
  }
}

/**
 * 遍历 ID3 frame 提取目标字段
 */
function parseFrames(tag: Uint8Array, version: number): Id3Tag {
  const result: Id3Tag = { title: '', artist: '', album: '', coverData: null };
  let offset = 0;
  while (offset + 10 <= tag.length) {
    const frameId = asciiString(tag, offset, 4);
    if (!/^[A-Z0-9]{4}$/.test(frameId)) {
      break; // padding 到达
    }
    let frameSize: number;
    if (version === 4) {
      frameSize = syncSafeInt(tag, offset + 4);
    } else {
      frameSize = bigEndianInt(tag, offset + 4);
    }
    const dataStart = offset + 10;
    if (frameSize <= 0 || dataStart + frameSize > tag.length) {
      break;
    }
    const payload = tag.subarray(dataStart, dataStart + frameSize);
    if (frameId === 'TIT2' && !result.title) {
      result.title = decodeTextFrame(payload);
    } else if (frameId === 'TPE1' && !result.artist) {
      result.artist = decodeTextFrame(payload);
    } else if (frameId === 'TALB' && !result.album) {
      result.album = decodeTextFrame(payload);
    } else if (frameId === 'APIC' && !result.coverData) {
      result.coverData = extractCover(payload);
    }
    offset = dataStart + frameSize;
  }
  return result;
}

/**
 * 解析 APIC frame，返回图片二进制数据
 */
function extractCover(payload: Uint8Array): Uint8Array | null {
  if (payload.length < 4) {
    return null;
  }
  const encoding = payload[0];
  // 跳过 mime（单字节 null 结尾）
  let pos = 1;
  while (pos < payload.length && payload[pos] !== 0) {
    pos++;
  }
  pos++; // mime 结尾 null
  pos++; // picture type
  // 跳过 description（编码相关：0/3 单字节 null，1/2 双字节 null）
  if (encoding === 1 || encoding === 2) {
    while (pos + 1 < payload.length && !(payload[pos] === 0 && payload[pos + 1] === 0)) {
      pos += 2;
    }
    pos += 2;
  } else {
    while (pos < payload.length && payload[pos] !== 0) {
      pos++;
    }
    pos++;
  }
  if (pos >= payload.length) {
    return null;
  }
  return payload.slice(pos);
}

/**
 * 解码文本帧：首字节为编码标记
 * 0=ISO-8859-1, 1=UTF-16(BOM), 2=UTF-16BE, 3=UTF-8
 */
function decodeTextFrame(payload: Uint8Array): string {
  if (payload.length < 2) {
    return '';
  }
  const encoding = payload[0];
  const body = payload.subarray(1);
  if (encoding === 1) {
    return decodeUtf16(body, true);
  }
  if (encoding === 2) {
    return decodeUtf16(body, false);
  }
  if (encoding === 3) {
    return stripNull(util.TextDecoder.create('utf-8').decodeWithStream(body));
  }
  // ISO-8859-1 / ASCII：逐字节映射
  let out = '';
  for (let i = 0; i < body.length; i++) {
    if (body[i] === 0) {
      break;
    }
    out += String.fromCharCode(body[i]);
  }
  return out;
}

function decodeUtf16(body: Uint8Array, allowBom: boolean): string {
  if (body.length < 2) {
    return '';
  }
  let littleEndian = false;
  let start = 0;
  if (allowBom && body[0] === 0xFF && body[1] === 0xFE) {
    littleEndian = true;
    start = 2;
  } else if (allowBom && body[0] === 0xFE && body[1] === 0xFF) {
    littleEndian = false;
    start = 2;
  }
  let out = '';
  for (let i = start; i + 1 < body.length; i += 2) {
    const code = littleEndian ? body[i] | (body[i + 1] << 8) : (body[i] << 8) | body[i + 1];
    if (code === 0) {
      break;
    }
    out += String.fromCharCode(code);
  }
  return out;
}

function syncSafeInt(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset] & 0x7F) << 21) | ((bytes[offset + 1] & 0x7F) << 14) |
    ((bytes[offset + 2] & 0x7F) << 7) | (bytes[offset + 3] & 0x7F);
}

function bigEndianInt(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
}

function asciiString(bytes: Uint8Array, offset: number, length: number): string {
  let out = '';
  for (let i = 0; i < length; i++) {
    out += String.fromCharCode(bytes[offset + i]);
  }
  return out;
}

function stripNull(text: string): string {
  const idx = text.indexOf('\u0000');
  return idx >= 0 ? text.substring(0, idx) : text;
}
