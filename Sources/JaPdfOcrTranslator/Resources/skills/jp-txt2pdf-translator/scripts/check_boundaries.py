#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_boundaries.py — 跨块截断句检测（S5）

扫描相邻块边界，标出「上块结尾未以句末符/收束符结束」的可疑衔接点。
只检测提示，不改文件 —— 修正由 Agent 在 S5 完成。

v3.3 变更（T02-k，最小改动）：
  - 默认 `--indir` 改为 `state/chunks`；
  - 给出 `--state` 时自动推导 `--indir` 与 `--json`，报告落在 state 根。

用法:
  python check_boundaries.py --state <outDir>/state
  python check_boundaries.py --indir state/chunks [--json state/boundary_report.json]
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    EXIT_OK, SCHEMA_VERSION, TERMINAL_CHARS, install_excepthook, now, read_text,
    write_json_atomic,
)

TERMINAL = TERMINAL_CHARS


def read_chunks(indir: str, pattern: str = 'chunk_*.txt',
                exclude: str | None = '*_zh.txt') -> list[str]:
    """按块号数值序返回源块路径；默认排除译块 `*_zh.txt`。

    v3.2 的默认 `exclude=None` 在 v3.3 会把 `chunk_001_zh.txt` 也扫进来
    （两者同处 `state/chunks/`），因此这里把排除模式设为默认值。
    """
    files = sorted(glob.glob(os.path.join(indir, pattern)),
                   key=lambda p: int(re.search(r'(\d+)', os.path.basename(p)).group(1)))
    if exclude:
        excl = set(os.path.abspath(p) for p in glob.glob(os.path.join(indir, exclude)))
        files = [f for f in files if os.path.abspath(f) not in excl]
    return files


def main(argv: list[str] | None = None) -> int:
    install_excepthook("check_boundaries.py")
    ap = argparse.ArgumentParser(
        prog="check_boundaries.py",
        description="跨块截断句检测，产出 boundary_report.json（S5）")
    ap.add_argument('--state', default=None, help="<outDir>/state；给出时自动推导 indir/json")
    ap.add_argument('--indir', default='state/chunks', help="块目录，默认 state/chunks")
    ap.add_argument('--json', default=None, help="报告输出路径")
    args = ap.parse_args(argv)

    indir = args.indir
    json_path = args.json
    if args.state:
        state = os.path.abspath(args.state)
        indir = os.path.join(state, 'chunks')
        json_path = json_path or os.path.join(state, 'boundary_report.json')

    files = read_chunks(indir)
    suspects: list[dict[str, Any]] = []
    for i in range(1, len(files)):
        prev = read_text(files[i - 1]).rstrip()
        cur = read_text(files[i]).lstrip()
        last = prev[-1] if prev else ''
        if last not in TERMINAL:
            suspects.append({
                'prev_chunk': int(re.search(r'(\d+)', os.path.basename(files[i - 1])).group(1)),
                'next_chunk': int(re.search(r'(\d+)', os.path.basename(files[i])).group(1)),
                'boundary': f'{os.path.basename(files[i - 1])} / {os.path.basename(files[i])}',
                'prev_end': prev[-40:],
                'cur_start': cur[:40],
                'issue': 'previous chunk does not end with terminal punctuation',
            })

    print(f'check_boundaries: scanned {len(files)} chunks, {len(suspects)} suspect boundary(ies)')
    for s in suspects:
        print(f"  SUSPECT {s['boundary']}: ...{s['prev_end']!r} | {s['cur_start']!r}...")

    if json_path:
        write_json_atomic(json_path, {
            'schema_version': SCHEMA_VERSION,
            'generated_at': round(now(), 3),
            'indir': os.path.abspath(indir),
            'scanned': len(files),
            'suspect_count': len(suspects),
            'suspects': suspects,
        })
        print(f'  wrote {json_path}')
    return EXIT_OK


if __name__ == '__main__':
    sys.exit(main())
