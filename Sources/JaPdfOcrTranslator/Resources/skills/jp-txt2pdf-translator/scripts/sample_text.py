#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sample_text.py — 抽样打包（S3 输入）

从已切分的块里按「首 / 中 / 末」均匀抽 N 块，每块截取前 `--chars` 个字符
（按段落边界对齐，不腰斩句子），打包为 `state/samples/sample_pack.md`。

存在理由：S3「样本分析与风格定调」只需要看见全书的语域跨度（开场铺陈、
中段对白、结尾收束），把整本塞进上下文既昂贵又会稀释注意力。

用法:
  python sample_text.py --state <outDir>/state [--n 3] [--chars 3000]

产物:
  <state>/samples/sample_pack.md
stdout: JSON 对象 {"ok":true,"path":…,"chunks":[1,24,48],"chars":…}
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    EXIT_OK, EXIT_STATE, chunk_path, die, emit_json, ensure_state,
    install_excepthook, now, read_json, read_text, split_paragraphs,
    write_text_atomic,
)


def available_chunks(state: str) -> list[int]:
    """优先读 `structure.json`；缺失时回退扫描 `chunks/chunk_NNN.txt`。"""
    structure = read_json(os.path.join(state, "structure.json"), None)
    if isinstance(structure, dict):
        entries = structure.get("chunks")
        if isinstance(entries, list) and entries:
            found = [e.get("index") for e in entries
                     if isinstance(e, dict) and isinstance(e.get("index"), int)]
            if found:
                return sorted(found)

    chunk_dir = os.path.join(state, "chunks")
    if not os.path.isdir(chunk_dir):
        return []
    numbers: list[int] = []
    for name in os.listdir(chunk_dir):
        m = re.fullmatch(r"chunk_(\d+)\.txt", name)
        if m:
            numbers.append(int(m.group(1)))
    return sorted(numbers)


def pick_indices(chunks: list[int], n: int) -> list[int]:
    """在块号序列上均匀取 n 个位置，n=3 时正好是首 / 中 / 末。"""
    total = len(chunks)
    if total == 0 or n <= 0:
        return []
    if n >= total:
        return list(chunks)
    if n == 1:
        return [chunks[0]]
    step = (total - 1) / (n - 1)
    picked = sorted({chunks[int(round(k * step))] for k in range(n)})
    return picked


def excerpt(text: str, limit: int) -> str:
    """按段落边界截取不超过 `limit` 字符的片段；单段超限时才硬截。"""
    paras = split_paragraphs(text)
    if not paras:
        return text[:limit].strip()
    out: list[str] = []
    used = 0
    for para in paras:
        if out and used + len(para) > limit:
            break
        out.append(para)
        used += len(para) + 2
        if used >= limit:
            break
    if not out:
        return paras[0][:limit].strip()
    return "\n\n".join(out)


def position_label(index: int, chunks: list[int]) -> str:
    if not chunks:
        return "样本"
    if index == chunks[0]:
        return "开篇"
    if index == chunks[-1]:
        return "结尾"
    return "中段"


def main(argv: list[str] | None = None) -> int:
    install_excepthook("sample_text.py")
    ap = argparse.ArgumentParser(
        prog="sample_text.py",
        description="按首/中/末抽样打包为 samples/sample_pack.md（S3 输入）")
    ap.add_argument("--state", required=True, help="<outDir>/state 目录")
    ap.add_argument("--n", type=int, default=3, help="抽样块数，默认 3")
    ap.add_argument("--chars", type=int, default=3000, help="每块截取字符上限")
    ap.add_argument("--out", default="", help="覆盖输出路径，默认 samples/sample_pack.md")
    args = ap.parse_args(argv)

    if args.n <= 0:
        die(1, "--n 必须为正整数。")
    if args.chars <= 0:
        die(1, "--chars 必须为正整数。")

    state = ensure_state(args.state)
    chunks = available_chunks(state)
    if not chunks:
        die(EXIT_STATE, f"未找到任何 chunk_NNN.txt：{os.path.join(state, 'chunks')}\n"
                        f"  请先运行 split_text.py。")

    picked = pick_indices(chunks, args.n)
    sections: list[str] = [
        "# 样本包（S3 风格定调输入）",
        "",
        f"- 总块数：{len(chunks)}",
        f"- 抽样块：{', '.join(str(i) for i in picked)}",
        f"- 每块截取上限：{args.chars} 字符",
        "",
        "> 说明：以下片段为原文节选，用于判定语域、人称、口癖与标点风格。",
        "> 仅供分析，**不要**在本阶段产出译文。",
        "",
    ]

    total_chars = 0
    used: list[dict[str, Any]] = []
    for index in picked:
        path = chunk_path(state, index, zh=False)
        if not os.path.isfile(path):
            continue
        body = excerpt(read_text(path), args.chars)
        total_chars += len(body)
        used.append({"chunk": index, "chars": len(body),
                     "position": position_label(index, chunks)})
        sections.append(f"## 第 {index} 块 · {position_label(index, chunks)}")
        sections.append("")
        sections.append(body)
        sections.append("")

    if not used:
        die(EXIT_STATE, "抽样命中的块文件全部缺失，无法生成样本包。")

    out_path = args.out or os.path.join(state, "samples", "sample_pack.md")
    write_text_atomic(out_path, "\n".join(sections).rstrip() + "\n")

    emit_json({
        "ok": True,
        "path": out_path,
        "chunks": [item["chunk"] for item in used],
        "samples": used,
        "chars": total_chars,
        "total_chunks": len(chunks),
        "generated_at": round(now(), 3),
    })
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
