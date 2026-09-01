#!/usr/bin/env python3
"""解析 HarmonyOS debug profile (.p7b) 的签名材料信息。

用法:
  parse_profile.py <profile.p7b> [udid]

输出（无 udid 参数时）:
  单行: <not-before YYYY-MM-DD> <not-after YYYY-MM-DD> <device-count>

带 udid 参数时:
  exit 0 表示该设备已绑定，exit 1 表示未绑定（无 stdout）
"""
import datetime
import json
import re
import sys


def load_profile(path: str) -> dict:
    data = open(path, 'rb').read()
    m = re.search(rb'\{.*\}', data, re.S)
    if not m:
        raise ValueError('no JSON block in profile')
    raw = m.group(0).decode('utf-8', 'replace')
    # 签名尾部可能有非 JSON 内容，逐步截断找最长合法 JSON
    for cut in range(len(raw), 0, -1):
        try:
            return json.loads(raw[:cut])
        except Exception:
            continue
    raise ValueError('no valid JSON in profile')


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    profile = load_profile(path)
    validity = profile['validity']
    nb = datetime.datetime.fromtimestamp(validity['not-before']).strftime('%Y-%m-%d')
    na = datetime.datetime.fromtimestamp(validity['not-after']).strftime('%Y-%m-%d')
    ids = profile.get('debug-info', {}).get('device-ids', [])
    if len(sys.argv) >= 3:
        return 0 if sys.argv[2] in ids else 1
    print(f'{nb} {na} {len(ids)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
