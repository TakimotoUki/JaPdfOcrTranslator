#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_alignment.py — 段落对齐与压缩比检查（S6）

契约出处：DESIGN-v3.3 §3.8。四类问题：

| kind                      | 判定                                   | severity |
|---------------------------|----------------------------------------|----------|
| `missing_file`            | `chunk_NNN_zh.txt` 不存在              | error    |
| `empty_translation`       | 译块去空白后为空                        | error    |
| `paragraph_count_mismatch`| 段落数不等（按空行分段）                | error/warn |
| `ratio_out_of_range`      | `zh_chars/src_chars` 落在 [0.55,1.70] 外 | warn     |

段落数差异分级（F33-12 要求「漏译整段必须被拦住」）：
`|delta| ≥ 2` 或 `|delta|/src_paragraphs ≥ 15%` → `error`，否则 `warn`。
单段增删（如把一个长段拆成两段）是合法的排版调整，不该拦；
连删两段或删掉 15% 以上，几乎一定是漏译。

**只要出现 error 就以退出码 5 结束**（F33-12 明确要求非零退出码），
warn 不影响退出码。

用法:
  python check_alignment.py --state <outDir>/state [--ratio-min 0.55] [--ratio-max 1.70]
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    EXIT_CHECK, EXIT_OK, EXIT_STATE, SCHEMA_VERSION, append_event, chunk_path,
    die, emit_json, ensure_state, install_excepthook, now, read_json, read_text,
    split_paragraphs, write_json_atomic,
    make_parser,)

DEFAULT_RATIO_MIN = 0.55
DEFAULT_RATIO_MAX = 1.70

#: 段落数差异升级为 error 的绝对阈值与相对阈值。
PARAGRAPH_DELTA_ABS = 2
PARAGRAPH_DELTA_RATIO = 0.15


def resolve_total(state: str) -> int:
    """块总数：优先 structure.json → config.json → status.json → 扫目录。"""
    structure = read_json(os.path.join(state, "structure.json"), None)
    if isinstance(structure, dict) and isinstance(structure.get("chunk_count"), int):
        if structure["chunk_count"] > 0:
            return structure["chunk_count"]
    cfg = read_json(os.path.join(state, "config.json"), None)
    if isinstance(cfg, dict) and isinstance(cfg.get("total_chunks"), int):
        if cfg["total_chunks"] > 0:
            return cfg["total_chunks"]
    status = read_json(os.path.join(state, "status.json"), None)
    if isinstance(status, dict) and isinstance(status.get("chunks_total"), int):
        if status["chunks_total"] > 0:
            return status["chunks_total"]
    chunk_dir = os.path.join(state, "chunks")
    if not os.path.isdir(chunk_dir):
        return 0
    count = 0
    while os.path.isfile(chunk_path(state, count + 1, zh=False)):
        count += 1
    return count


def skipped_chunks(state: str) -> set[int]:
    """`status.chunk_status` 中标记为 skipped 的块不参与对齐检查。"""
    status = read_json(os.path.join(state, "status.json"), None)
    if not isinstance(status, dict):
        return set()
    out: set[int] = set()
    for key, value in (status.get("chunk_status") or {}).items():
        if value == "skipped":
            try:
                out.add(int(key))
            except (TypeError, ValueError):
                continue
    return out


def paragraph_severity(delta: int, src_paragraphs: int) -> str:
    magnitude = abs(delta)
    if magnitude >= PARAGRAPH_DELTA_ABS:
        return "error"
    if src_paragraphs > 0 and magnitude / src_paragraphs >= PARAGRAPH_DELTA_RATIO:
        return "error"
    return "warn"


def check(state: str, total: int, ratio_min: float,
          ratio_max: float) -> dict[str, Any]:
    issues: list[dict[str, Any]] = []
    skipped = skipped_chunks(state)
    checked = 0

    for n in range(1, total + 1):
        if n in skipped:
            continue
        src_path = chunk_path(state, n, zh=False)
        zh_path = chunk_path(state, n, zh=True)
        if not os.path.isfile(src_path):
            continue                                  # 源块缺失属于 S1 的问题
        checked += 1

        if not os.path.isfile(zh_path):
            issues.append({
                "chunk": n, "kind": "missing_file",
                "path": os.path.relpath(zh_path, state), "severity": "error",
            })
            continue

        src_text = read_text(src_path)
        zh_text = read_text(zh_path)
        if not zh_text.strip():
            issues.append({"chunk": n, "kind": "empty_translation", "severity": "error"})
            continue

        src_paras = len(split_paragraphs(src_text))
        zh_paras = len(split_paragraphs(zh_text))
        if src_paras != zh_paras:
            delta = zh_paras - src_paras
            issues.append({
                "chunk": n, "kind": "paragraph_count_mismatch",
                "src_paragraphs": src_paras, "zh_paragraphs": zh_paras,
                "delta": delta, "severity": paragraph_severity(delta, src_paras),
            })

        src_chars = len(src_text.strip())
        zh_chars = len(zh_text.strip())
        if src_chars > 0:
            ratio = zh_chars / src_chars
            if ratio < ratio_min or ratio > ratio_max:
                issues.append({
                    "chunk": n, "kind": "ratio_out_of_range",
                    "src_chars": src_chars, "zh_chars": zh_chars,
                    "ratio": round(ratio, 4), "severity": "warn",
                })

    errors = sum(1 for i in issues if i["severity"] == "error")
    warns = sum(1 for i in issues if i["severity"] == "warn")
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": round(now(), 3),
        "checked": checked,
        "ratio_range": [ratio_min, ratio_max],
        "summary": {"error": errors, "warn": warns},
        "issues": issues,
    }


def main(argv: list[str] | None = None) -> int:
    install_excepthook("check_alignment.py")
    ap = make_parser(
        prog="check_alignment.py",
        description="段落对齐 / 空译文 / 压缩比检查，产出 alignment_report.json（§3.8）")
    ap.add_argument("--state", required=True, help="<outDir>/state 目录")
    ap.add_argument("--ratio-min", dest="ratio_min", type=float, default=DEFAULT_RATIO_MIN)
    ap.add_argument("--ratio-max", dest="ratio_max", type=float, default=DEFAULT_RATIO_MAX)
    ap.add_argument("--format", choices=("json", "text"), default="json")
    args = ap.parse_args(argv)

    if args.ratio_min <= 0 or args.ratio_max <= args.ratio_min:
        die(1, "--ratio-min 必须为正且小于 --ratio-max。")

    state = ensure_state(args.state)
    total = resolve_total(state)
    if total <= 0:
        die(EXIT_STATE, f"未找到任何块：{os.path.join(state, 'chunks')}\n"
                        f"  请先运行 split_text.py。")

    report = check(state, total, args.ratio_min, args.ratio_max)
    write_json_atomic(os.path.join(state, "alignment_report.json"), report)

    errors = report["summary"]["error"]
    warns = report["summary"]["warn"]
    append_event(state, "alignment_checked", stage="S6", actor="script",
                 data={"checked": report["checked"], "errors": errors, "warns": warns})

    error_chunks = sorted({i["chunk"] for i in report["issues"] if i["severity"] == "error"})
    if args.format == "text":
        sys.stdout.write(
            f"check_alignment: checked={report['checked']} errors={errors} warns={warns}\n")
        for issue in report["issues"]:
            detail = f" delta={issue['delta']}" if "delta" in issue else ""
            sys.stdout.write(
                f"  [{issue['severity']}] chunk {issue['chunk']}: {issue['kind']}{detail}\n")
    else:
        emit_json({
            "ok": errors == 0,
            "checked": report["checked"],
            "errors": errors,
            "warns": warns,
            "error_chunks": error_chunks,
            "issues": report["issues"],
            "path": os.path.join(state, "alignment_report.json"),
        })

    if errors:
        sys.stderr.write(
            f"check_alignment: {errors} 处 error（块号 {error_chunks}），"
            f"请修复后重跑。详见 alignment_report.json\n")
        return EXIT_CHECK
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
