#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""split_text.py — 解码 + 智能分块 + 结构分析（S1）

按「章节标题优先 + 段落边界 + 句子完整 + 字符上限」切分，切分点永远落在
段落之间或完整句子之后，绝不拦腰截断句子。

v3.3 增强（DESIGN §3.5 / T02-d）：
  - `--out` 语义改为 **state 目录**（原为 work 目录）；
  - 新增 `structure.json`：章节边界、段落索引、字符数、句末完整性、块哈希；
  - 保留 `manifest.json`（v3.2 兼容）；
  - 切分完成后回填 `config.total_chunks` 并派生 `path_mode`/`prescan_mode`/`stages`；
  - 追加 `split_done` 事件（`chunks`, `total_chars`）。

用法:
  python split_text.py --input ja_combined.txt --out <outDir>/state [--target 4000] [--maxp 8000]

产物:
  <state>/chunks/chunk_NNN.txt
  <state>/manifest.json    {"count": N, "files": [...], "target": .., "maxp": ..}
  <state>/structure.json   §3.5
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    EXIT_OK, EXIT_STATE, SCHEMA_VERSION, TERMINAL_CHARS, append_event, die,
    emit_json, ensure_state_writable, install_excepthook, now, read_text,
    sha256_text, split_paragraphs, write_json_atomic, write_text_atomic,
    make_parser,)

CHAPTER_RE = re.compile(
    r'^\s*(第[一二三四五六七八九十\d]+[章節回部]|'
    r'[0-9]+\.\s*「|'
    r'[０-９]+\.|'
    r'[一二三四五六七八九十百]+、|'
    r'はじめに|まえがき|あとがき|おわりに|目次|参考文献|付録|'
    r'结语|参考文献\s*$|前言\s*$)'
)

#: 句末 / 收束符集合。与 `check_boundaries.py`、`check_alignment.py` 共用
#: `_common.TERMINAL_CHARS`，避免三处各写一份导致判定不一致。
TERMINAL = TERMINAL_CHARS


def split_sentences(para: str) -> list[str]:
    """按句末符切句；切不动时整段返回，保证永不丢内容。"""
    parts = re.split(r'(?<=[。．.！？!?…』】」）)])', para)
    out = [p.strip() for p in parts if p.strip()]
    return out or [para]


def is_chapter(para: str) -> bool:
    """短行 + 章节正则命中才算标题，避免把正文首句误判为章节。"""
    s = para.strip()
    if not s or len(s) > 60:
        return False
    return bool(CHAPTER_RE.match(s))


def chunk_text(paras: list[str], target: int, maxp: int) -> list[dict[str, Any]]:
    """把段落列表切成块，返回带元信息的块列表。

    每个元素：`{"text", "start_paragraph", "is_chapter_head", "chapter_title"}`。
    `start_paragraph` 是该块首段在 `paras` 中的 0-based 下标（§3.5）。
    """
    chunks: list[dict[str, Any]] = []
    cur: list[str] = []
    cur_len = 0
    cur_start = 0

    def flush() -> None:
        nonlocal cur, cur_len, cur_start
        if cur:
            chunks.append({
                "text": "\n\n".join(cur),
                "start_paragraph": cur_start,
                "is_chapter_head": False,
                "chapter_title": None,
            })
            cur = []
            cur_len = 0

    for pidx, para in enumerate(paras):
        length = len(para)
        if is_chapter(para):
            flush()
            chunks.append({
                "text": para,
                "start_paragraph": pidx,
                "is_chapter_head": True,
                "chapter_title": para.strip(),
            })
            continue
        if length > maxp:
            # 超长段落降级为按句切分；这些子块共享同一个段落下标。
            flush()
            cur_start = pidx
            for sent in split_sentences(para):
                if cur and cur_len + len(sent) > target:
                    flush()
                    cur_start = pidx
                cur.append(sent)
                cur_len += len(sent)
            flush()
            continue
        if cur and cur_len + length > target:
            flush()
        if not cur:
            cur_start = pidx
        cur.append(para)
        cur_len += length
    flush()
    return chunks


def build_structure(source_path: str, text: str, blocks: list[dict[str, Any]],
                    target: int, maxp: int) -> dict[str, Any]:
    """组装 §3.5 的 `structure.json`。"""
    chapters: list[dict[str, Any]] = []
    chunk_entries: list[dict[str, Any]] = []
    chapter_index = 0

    for i, block in enumerate(blocks, 1):
        body: str = block["text"]
        if block["is_chapter_head"]:
            chapter_index += 1
            chapters.append({
                "index": chapter_index,
                "title": block["chapter_title"] or "",
                "start_chunk": i,
                "start_paragraph": block["start_paragraph"],
            })
        stripped = body.strip()
        prev_body: str = blocks[i - 2]["text"].rstrip() if i >= 2 else ""
        chunk_entries.append({
            "index": i,
            "file": f"chunks/chunk_{i:03d}.txt",
            "chars": len(body),
            # 段落数用 _common.split_paragraphs 计算，与 check_alignment.py
            # 完全同源，否则 S6 的段落数比对会永远对不上（§10.6）。
            "paragraphs": len(split_paragraphs(body)),
            "chapter_index": chapter_index if chapter_index else 0,
            "is_chapter_head": bool(block["is_chapter_head"]),
            "starts_mid_sentence": bool(prev_body) and prev_body[-1] not in TERMINAL,
            "ends_mid_sentence": bool(stripped) and stripped[-1] not in TERMINAL,
            "sha256": sha256_text(body),
        })

    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": round(now(), 3),
        "source_path": os.path.abspath(source_path),
        "total_chars": len(text),
        "chunk_count": len(blocks),
        "target": target,
        "maxp": maxp,
        "chapters": chapters,
        "chunks": chunk_entries,
    }


def main(argv: list[str] | None = None) -> int:
    install_excepthook("split_text.py")
    ap = make_parser(
        prog="split_text.py",
        description="解码 + 智能分块 + 结构分析（DESIGN-v3.3 §3.5）")
    ap.add_argument('--input', required=True, help="日文 txt 路径")
    ap.add_argument('--out', default='state', help="state 目录（v3.3 语义）")
    ap.add_argument('--target', type=int, default=4000)
    ap.add_argument('--maxp', type=int, default=8000)
    ap.add_argument('--format', choices=('text', 'json'), default='text',
                    help="text=人类可读一行摘要；json=机器可读对象")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.input):
        die(EXIT_STATE, f"输入文件不存在：{args.input}")
    if args.target <= 0 or args.maxp <= 0:
        die(1, "--target 与 --maxp 必须为正整数。")

    state = ensure_state_writable(args.out)
    text = read_text(args.input)
    paras = split_paragraphs(text)
    blocks = chunk_text(paras, args.target, args.maxp)

    out_dir = os.path.join(state, 'chunks')
    os.makedirs(out_dir, exist_ok=True)
    files: list[str] = []
    for i, block in enumerate(blocks, 1):
        path = os.path.join(out_dir, f'chunk_{i:03d}.txt')
        write_text_atomic(path, block["text"] + "\n")
        files.append(path)

    manifest = {'count': len(blocks), 'files': files,
                'target': args.target, 'maxp': args.maxp}
    write_json_atomic(os.path.join(state, 'manifest.json'), manifest)

    structure = build_structure(args.input, text, blocks, args.target, args.maxp)
    write_json_atomic(os.path.join(state, 'structure.json'), structure)

    # 回填 config.total_chunks / path_mode / prescan_mode / stages（§3.2）。
    backfill: dict[str, Any] = {"updated": False}
    if os.path.isfile(os.path.join(state, "config.json")):
        try:
            from state_tool import StateStore     # 同目录脚本，零第三方依赖
            backfill = StateStore(state).backfill_split(len(blocks))
        except ImportError:
            backfill = {"updated": False, "reason": "state_tool_unavailable"}

    append_event(state, "split_done", stage="S1", actor="script",
                 data={"chunks": len(blocks), "total_chars": len(text)})

    payload = {
        "ok": True,
        "chunks": len(blocks),
        "total_chars": len(text),
        "chapters": len(structure["chapters"]),
        "paragraphs": len(paras),
        "target": args.target,
        "maxp": args.maxp,
        "state": state,
        "structure": os.path.join(state, "structure.json"),
        "manifest": os.path.join(state, "manifest.json"),
        "config_backfill": backfill,
    }
    if args.format == 'json':
        emit_json(payload)
    else:
        sys.stdout.write(
            f"split_text: {len(blocks)} chunks -> {out_dir} "
            f"(target={args.target}, maxp={args.maxp}, chars={len(text)}, "
            f"chapters={len(structure['chapters'])})\n")
    return EXIT_OK


if __name__ == '__main__':
    sys.exit(main())
