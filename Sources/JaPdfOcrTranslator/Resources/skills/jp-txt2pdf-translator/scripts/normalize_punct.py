#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""normalize_punct.py — 中文标点规范化（S6，原地改写译块）

契约出处：DESIGN-v3.3 §3.9 punctuation / F33-13。规则：

| 原文        | 规范化后 | 说明                       |
|-------------|----------|----------------------------|
| `「` `」`   | `“` `”`  | 日式直引号 → 中文双引号     |
| `『` `』`   | `‘` `’`  | 日式书名/内引号 → 中文单引号 |
| `,` `.`     | `，` `。`| 半角 → 全角（数字间不动）   |
| `!` `?` `:` `;` | `！` `？` `：` `；` | 半角 → 全角      |
| `...`（3+） | `……`     | 省略号                     |
| `--`（2+）  | `——`     | 破折号                     |

**两处保护**（否则会把代码和数据改坏）：
1. ` ``` ` / `~~~` 代码围栏内的行**一个字符都不改**（`_common.fence_line_flags`）；
2. 行内的 URL / 邮箱 / 文件路径 / 版本号 / 数字千分位与小数点先挖成占位符，
   规范化后再填回。

`--dry-run` 只统计不落盘。

stdout 的 `bracket_residue` 只统计**可规范化区**的日式括号（见 `count_brackets`）；
围栏与受保护片段里的括号按契约必须原样保留，单独计入 `bracket_protected`。

用法:
  python normalize_punct.py --state <outDir>/state [--dry-run]
  python normalize_punct.py --file a.txt --file b.txt [--dry-run]
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    EXIT_OK, EXIT_STATE, append_event, chunk_path, die, emit_json, ensure_state,
    fence_line_flags, install_excepthook, read_json, read_text, write_text_atomic,
)

#: 成对替换：日式括号 → 中文引号。顺序无关，逐字符替换。
BRACKET_MAP = {"「": "“", "」": "”", "『": "‘", "』": "’"}

#: 半角 → 全角。`,` 与 `.` 另有数字保护，见 `_PROTECT_RES`。
HALFWIDTH_MAP = {",": "，", ".": "。", "!": "！", "?": "？", ":": "：", ";": "；"}

#: 行内需要整体保护、内部标点一律不改的片段。
_PROTECT_RES: tuple[re.Pattern[str], ...] = (
    re.compile(r"[A-Za-z][A-Za-z0-9+.\-]*://\S+"),          # URL
    re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"),            # 邮箱
    re.compile(r"`[^`\n]+`"),                                # 行内代码
    re.compile(r"\b\d+(?:[.,]\d+)+\b"),                     # 3.14 / 1,000 / 1.2.3
    re.compile(r"(?<![^\s(（])(?:\.{0,2}/)?(?:[\w.-]+/)+[\w.-]+"),   # 文件路径
)

_SENTINEL = "\uf8ff"          # 私有区字符，正文中不可能出现


def _protect(line: str) -> tuple[str, list[str]]:
    """把受保护片段替换为占位符，返回 `(处理后文本, 片段表)`。"""
    saved: list[str] = []

    def stash(m: re.Match[str]) -> str:
        saved.append(m.group(0))
        return f"{_SENTINEL}{len(saved) - 1}{_SENTINEL}"

    out = line
    for pattern in _PROTECT_RES:
        out = pattern.sub(stash, out)
    return out, saved


def _restore(line: str, saved: list[str]) -> str:
    """回填占位符。

    保护片段可能嵌套（例如反引号包住一条 URL：先挖 URL，再挖行内代码），
    所以要循环回填直到不再出现哨兵，单次 `re.sub` 会漏掉内层。
    """
    if not saved:
        return line

    def unstash(m: re.Match[str]) -> str:
        index = int(m.group(1))
        return saved[index] if 0 <= index < len(saved) else m.group(0)

    pattern = re.compile(f"{_SENTINEL}(\\d+){_SENTINEL}")
    out = line
    for _ in range(len(saved) + 1):
        new_out = pattern.sub(unstash, out)
        if new_out == out:
            break
        out = new_out
    return out


def normalize_line(line: str) -> tuple[str, int]:
    """规范化单行（调用方保证该行不在围栏内），返回 `(新行, 替换次数)`。"""
    protected, saved = _protect(line)
    count = 0

    # 1) 多字符序列优先：省略号、破折号。
    protected, n = re.subn(r"\.{3,}", "……", protected)
    count += n
    protected, n = re.subn(r"-{2,}", "——", protected)
    count += n

    # 2) 日式括号 → 中文引号。
    for src, dst in BRACKET_MAP.items():
        if src in protected:
            count += protected.count(src)
            protected = protected.replace(src, dst)

    # 3) 半角标点 → 全角。数字千分位/小数点已在 _protect 里挖走。
    chars = list(protected)
    for i, ch in enumerate(chars):
        replacement = HALFWIDTH_MAP.get(ch)
        if replacement is None:
            continue
        chars[i] = replacement
        count += 1
    protected = "".join(chars)

    return _restore(protected, saved), count


def normalize_text(text: str) -> tuple[str, int]:
    """逐行规范化；围栏内的行原样透传（§10.6）。"""
    lines = text.split("\n")
    flags = fence_line_flags(text)
    out: list[str] = []
    total = 0
    for line, fenced in zip(lines, flags):
        if fenced:
            out.append(line)
            continue
        new_line, count = normalize_line(line)
        out.append(new_line)
        total += count
    return "\n".join(out), total


def count_brackets(text: str) -> tuple[int, int]:
    """统计日式括号，返回 `(可规范化区残留, 受保护区计数)`。

    PRD F33-13 的两条验收——「日式括号残留 = 0」与「围栏内标点不被改动」——
    只有在残留仅统计**可规范化区**时才可能同时成立：围栏里若写着
    ``「不要动我」``，它按契约就必须原样保留，不能算作残留。

    因此这里跳过两类区域：
    1. 代码围栏内的整行（`fence_line_flags`）；
    2. 行内受保护片段（URL / 邮箱 / 行内代码 / 版本号 / 路径）。

    受保护区里的括号数单独返回，供报告透明展示，不计入残留。
    """
    lines = text.split("\n")
    flags = fence_line_flags(text)
    residue = 0
    protected_count = 0
    for line, fenced in zip(lines, flags):
        if fenced:
            protected_count += sum(line.count(ch) for ch in BRACKET_MAP)
            continue
        stripped, saved = _protect(line)
        residue += sum(stripped.count(ch) for ch in BRACKET_MAP)
        for fragment in saved:
            protected_count += sum(fragment.count(ch) for ch in BRACKET_MAP)
    return residue, protected_count


def target_files(state: str) -> list[str]:
    """收集 `chunks/chunk_NNN_zh.txt`（按块号升序）。"""
    files: list[str] = []
    n = 1
    while True:
        path = chunk_path(state, n, zh=True)
        src = chunk_path(state, n, zh=False)
        if not os.path.isfile(path) and not os.path.isfile(src):
            break
        if os.path.isfile(path):
            files.append(path)
        n += 1
        if n > 100000:                     # 防御性上界，避免异常目录导致死循环
            break
    return files


def resolve_total_hint(state: str) -> int:
    cfg = read_json(os.path.join(state, "config.json"), None)
    if isinstance(cfg, dict) and isinstance(cfg.get("total_chunks"), int):
        return cfg["total_chunks"]
    return 0


def main(argv: list[str] | None = None) -> int:
    install_excepthook("normalize_punct.py")
    ap = argparse.ArgumentParser(
        prog="normalize_punct.py",
        description="中文标点规范化，原地改写 chunk_NNN_zh.txt（§3.9 / F33-13）")
    ap.add_argument("--state", default="", help="<outDir>/state 目录")
    ap.add_argument("--file", action="append", default=[], help="直接指定文件，可重复")
    ap.add_argument("--dry-run", dest="dry_run", action="store_true", help="只报数不写盘")
    args = ap.parse_args(argv)

    if not args.state and not args.file:
        die(1, "必须给出 --state 或至少一个 --file。")

    state = ""
    files: list[str] = []
    if args.state:
        state = ensure_state(args.state)
        files.extend(target_files(state))
    for path in args.file:
        abs_path = os.path.abspath(path)
        if not os.path.isfile(abs_path):
            die(EXIT_STATE, f"文件不存在：{abs_path}")
        if abs_path not in files:
            files.append(abs_path)

    if not files:
        hint = resolve_total_hint(state) if state else 0
        die(EXIT_STATE,
            f"未找到任何译块 chunk_NNN_zh.txt（配置块数 {hint}）。\n"
            f"  S6 需要先完成 S4 逐块翻译。")

    details: list[dict[str, Any]] = []
    changed_files = 0
    total_replacements = 0
    for path in files:
        original = read_text(path)
        normalized, count = normalize_text(original)
        if count and normalized != original:
            changed_files += 1
            if not args.dry_run:
                write_text_atomic(path, normalized)
        residue, protected_brackets = count_brackets(normalized)
        total_replacements += count
        details.append({
            "path": os.path.relpath(path, state) if state else path,
            "replacements": count,
            "bracket_residue": residue,
            "bracket_protected": protected_brackets,
        })

    if state and not args.dry_run:
        append_event(state, "punct_normalized", stage="S6", actor="script",
                     data={"files": changed_files, "replacements": total_replacements})

    emit_json({
        "ok": True,
        "dry_run": args.dry_run,
        "scanned": len(files),
        "files": changed_files,
        "replacements": total_replacements,
        "bracket_residue": sum(d["bracket_residue"] for d in details),
        "bracket_protected": sum(d["bracket_protected"] for d in details),
        "details": details,
    })
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
