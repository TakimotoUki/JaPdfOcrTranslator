#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""reduce_digests.py — 梗概归并打包（S2 map-reduce）

把 `digests/chunk_NNN.md` 按 `--group` 条一包地拼成
`state/samples/digest_pack_KK.md`。

存在理由：200 块 × 200 字 = 4 万字梗概，一次塞进上下文既超限又会让模型
只记住开头。分包后 S2 变成两轮 map-reduce：先每包出一段小结，再把小结
汇总成 `book_synopsis.md`。

用法:
  python reduce_digests.py --state <outDir>/state [--group 20]

产物:
  <state>/samples/digest_pack_01.md, digest_pack_02.md, …
stdout: JSON 对象 {"ok":true,"packs":[…],"groups":N,"digests":M}
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    EXIT_OK, EXIT_STATE, die, emit_json, ensure_state, install_excepthook, now,
    read_text, write_text_atomic,
)

_DIGEST_RE = re.compile(r"chunk_(\d+)\.md")


def collect_digests(state: str) -> list[tuple[int, str]]:
    """返回 `[(块号, 路径)]`，按块号升序。"""
    digest_dir = os.path.join(state, "digests")
    if not os.path.isdir(digest_dir):
        return []
    found: list[tuple[int, str]] = []
    for name in os.listdir(digest_dir):
        m = _DIGEST_RE.fullmatch(name)
        if m:
            found.append((int(m.group(1)), os.path.join(digest_dir, name)))
    return sorted(found, key=lambda item: item[0])


def clear_stale_packs(state: str) -> int:
    """删除上一轮遗留的 digest_pack_*.md，避免块数变少后读到旧包。"""
    samples = os.path.join(state, "samples")
    if not os.path.isdir(samples):
        return 0
    removed = 0
    for name in sorted(os.listdir(samples)):
        if re.fullmatch(r"digest_pack_\d+\.md", name):
            try:
                os.remove(os.path.join(samples, name))
                removed += 1
            except OSError:
                continue
    return removed


def main(argv: list[str] | None = None) -> int:
    install_excepthook("reduce_digests.py")
    ap = argparse.ArgumentParser(
        prog="reduce_digests.py",
        description="把逐块梗概分组打包为 digest_pack_KK.md（S2 map-reduce）")
    ap.add_argument("--state", required=True, help="<outDir>/state 目录")
    ap.add_argument("--group", type=int, default=20, help="每包容纳的梗概数，默认 20")
    args = ap.parse_args(argv)

    if args.group <= 0:
        die(1, "--group 必须为正整数。")

    state = ensure_state(args.state)
    digests = collect_digests(state)
    if not digests:
        die(EXIT_STATE, f"未找到任何梗概文件：{os.path.join(state, 'digests')}\n"
                        f"  S2 需要先由 Agent 逐块产出 digests/chunk_NNN.md。")

    clear_stale_packs(state)

    packs: list[dict[str, Any]] = []
    total_chars = 0
    for pack_no, start in enumerate(range(0, len(digests), args.group), 1):
        group = digests[start:start + args.group]
        first, last = group[0][0], group[-1][0]
        lines = [
            f"# 梗概包 {pack_no:02d}（第 {first}–{last} 块）",
            "",
            f"- 覆盖块数：{len(group)}",
            "",
            "> 说明：以下为逐块中文梗概。请先归纳本包的情节主线、登场人物与",
            "> 关键设定，输出一段不超过 400 字的小结，供后续汇总为全书简介。",
            "",
        ]
        for index, path in group:
            body = read_text(path).strip()
            total_chars += len(body)
            lines.append(f"## 第 {index} 块")
            lines.append("")
            lines.append(body if body else "（本块梗概为空）")
            lines.append("")
        out_path = os.path.join(state, "samples", f"digest_pack_{pack_no:02d}.md")
        write_text_atomic(out_path, "\n".join(lines).rstrip() + "\n")
        packs.append({"pack": pack_no, "path": out_path,
                      "first_chunk": first, "last_chunk": last,
                      "digests": len(group)})

    emit_json({
        "ok": True,
        "packs": packs,
        "groups": len(packs),
        "digests": len(digests),
        "chars": total_chars,
        "group_size": args.group,
        "generated_at": round(now(), 3),
    })
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
