#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""merge.py — 按编号合并各块译文/原文为完整全文（S8）

v3.3 唯一变更：新增**可选**的 `--state`，给出时追加 `merged` 事件
（DESIGN §3.4 的事件表把 `merged` 的写入者指定为 merge.py）。
不给 `--state` 时行为与 v3.2 **逐字相同**，保持「沿用」承诺。

用法:
  # 合并译文（默认合并 chunk_*_zh.txt）
  python merge.py --indir state/chunks --out state/translation_full.txt --state state

  # 合并原文
  python merge.py --indir state/chunks --out state/original_full.txt \
      --pattern "chunk_*.txt" --exclude "*_zh.txt" --state state
"""
import argparse, os, re, glob, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import make_parser  # noqa: E402

def main():
    ap = make_parser()
    ap.add_argument('--indir', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--pattern', default='chunk_*_zh.txt')
    ap.add_argument('--exclude', default=None)
    ap.add_argument('--state', default=None, help='给出时追加 merged 事件（§3.4）')
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.indir, args.pattern)),
                   key=lambda p: int(re.search(r'(\d+)', os.path.basename(p)).group(1)))
    if args.exclude:
        excl = set(os.path.abspath(p) for p in glob.glob(os.path.join(args.indir, args.exclude)))
        files = [f for f in files if os.path.abspath(f) not in excl]
    parts = []
    for fn in files:
        parts.append(open(fn, encoding='utf-8').read().strip())
    text = '\n\n'.join(p for p in parts if p)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as f:
        f.write(text + '\n')
    print(f'merge: {len(files)} files -> {args.out} ({len(text)} chars)')

    if args.state and os.path.isdir(args.state):
        from _common import append_event
        append_event(args.state, 'merged', stage='S8', actor='script',
                     data={'out': os.path.abspath(args.out), 'chars': len(text)})

if __name__ == '__main__':
    main()
