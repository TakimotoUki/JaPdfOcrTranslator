#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_report.py — 交付报告汇总（S8）

契约出处：DESIGN-v3.3 T02-j / F33-14。把 `config.json`、`status.json`、
`structure.json`、`glossary.json`、`glossary_conflicts.json`、
`alignment_report.json`、`qa_issues.json`、`events.jsonl` 汇总为
`state/report.md`。

**必含七项**（F33-14 验收口径）：
  1. 块数（总数 / 完成 / 失败 / 跳过）
  2. 原文与译文字数
  3. 术语条数（锁定 / 自动分列）
  4. 冲突数（未决 / 已决）
  5. QA 问题分类计数 + 术语符合率
  6. `compliant` 结论及缺失块号
  7. 降级说明（`prescan_mode=sampled`、`pre_extract_mode=off` 等）

用法:
  python make_report.py --state <outDir>/state [--out <path>]
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    EXIT_OK, append_event, chunk_path, emit_json, ensure_state,
    install_excepthook, now, read_events, read_json, read_text,
    write_text_atomic,
)

STAGE_NAMES: dict[str, str] = {
    "S0": "初始化", "S1": "切分与结构分析", "S2": "全书预扫",
    "S3": "样本分析与风格定调", "S4": "逐块翻译", "S5": "跨块边界修复",
    "S6": "确定性质检", "S7": "一致性 QA", "S8": "合并与交付",
}

KIND_LABELS: dict[str, str] = {
    "japanese_residue": "日文残留",
    "terminology": "术语违例",
    "placeholder": "占位符",
    "number": "数字",
    "punctuation": "标点",
    "paragraph": "段落",
    "empty": "空译文",
    "suggestion": "入表建议",
}


def _int(value: Any, default: int = 0) -> int:
    return value if isinstance(value, int) else default


def _usage_lines(state: str) -> list[str]:
    """T10：汇总 `usage.json` → report.md 的「API 用量」章节（totals/by_tier/by_stage）。

    只读 usage.json；缺文件（WB 后端不跑 LLM 管线）→ 返回空列表（不渲染该章节）。
    """
    usage = read_json(os.path.join(state, "usage.json"))
    if not isinstance(usage, dict):
        return []
    totals = usage.get("totals") or {}
    lines = ["## 8. API 用量（LLM）", ""]
    lines.extend([
        "| 指标 | 值 |",
        "|---|---|",
        f"| 调用次数 | {_int(totals.get('calls'))} |",
        f"| Prompt tokens | {_int(totals.get('prompt_tokens'))} |",
        f"| Completion tokens | {_int(totals.get('completion_tokens'))} |",
        f"| Total tokens | {_int(totals.get('total_tokens'))} |",
        f"| 缓存命中 | {_int(totals.get('cache_hit_tokens'))}"
        f"（命中率 {float(totals.get('cache_hit_rate') or 0.0):.2%}） |",
        "",
    ])

    by_tier = usage.get("by_tier") or {}
    if by_tier:
        lines.extend(["按档位（by_tier）：", "", "| 档位 | 调用 | prompt | completion | total | 缓存命中率 |", "|---|---|---|---|---|---|"])
        for tier in sorted(by_tier):
            slot = by_tier[tier]
            lines.append(
                f"| {tier} | {_int(slot.get('calls'))} | {_int(slot.get('prompt_tokens'))} "
                f"| {_int(slot.get('completion_tokens'))} | {_int(slot.get('total_tokens'))} "
                f"| {float(slot.get('cache_hit_rate') or 0.0):.2%} |")
        lines.append("")

    by_stage = usage.get("by_stage") or {}
    if by_stage:
        lines.extend(["按阶段（by_stage）：", "", "| 阶段 | 调用 | total tokens |", "|---|---|---|"])
        for stage in sorted(by_stage):
            slot = by_stage[stage]
            lines.append(f"| {stage} | {_int(slot.get('calls'))} | {_int(slot.get('total_tokens'))} |")
        lines.append("")
    return lines


def count_chars(state: str, total: int, zh: bool) -> int:
    """统计全部块文本的字符数；优先用合并后的全文，缺失时逐块累加。"""
    merged = os.path.join(state, "translation_full.txt" if zh else "original_full.txt")
    if os.path.isfile(merged):
        return len(read_text(merged))
    chars = 0
    for n in range(1, total + 1):
        path = chunk_path(state, n, zh=zh)
        if os.path.isfile(path):
            chars += len(read_text(path))
    return chars


def degradation_notes(cfg: dict[str, Any], status: dict[str, Any],
                      events: list[dict[str, Any]]) -> list[str]:
    """把所有降级/跳过写成人类可读的一句话，交付时必须明示（F33-14）。"""
    notes: list[str] = []
    params = cfg.get("params") or {}

    prescan = cfg.get("prescan_mode", "full")
    if prescan == "sampled":
        indices = cfg.get("prescan_sample_indices") or []
        notes.append(
            f"全书预扫已降级为**抽样模式**：共抽取 {len(indices)} 块"
            f"（{', '.join(str(i) for i in indices[:10])}"
            f"{' …' if len(indices) > 10 else ''}），未逐块预扫。")
    elif prescan == "off":
        notes.append("全书预扫已**关闭**（`enable_prescan=false` 或走了 simple 路径）。")

    pre_mode = params.get("pre_extract_mode", "always")
    if pre_mode == "off":
        notes.append("术语预抽已降级为 **off**：F33-02 的时序合规判定默认通过，"
                     "但本次运行未在翻译前建立术语约束。")
    elif pre_mode == "firstNChunks":
        notes.append(f"术语预抽仅覆盖前 {params.get('pre_extract_first_n', 10)} 块"
                     f"（`pre_extract_mode=firstNChunks`）。")

    if cfg.get("path_mode") == "simple":
        notes.append("输入较短（≤2 块），走 **simple 路径**：跳过 S2，S3 并入 S4。")
    if params.get("enable_qa") is False:
        notes.append("一致性 QA 已关闭（`enable_qa=false`），无术语符合率数据。")
    if params.get("enable_punct_normalize") is False:
        notes.append("标点规范化已关闭（`enable_punct_normalize=false`）。")

    for ev in events:
        if ev.get("type") != "stage_skipped":
            continue
        data = ev.get("data") or {}
        stage = data.get("stage") or ev.get("stage") or "?"
        notes.append(f"阶段 {stage}（{STAGE_NAMES.get(stage, '')}）已跳过："
                     f"{data.get('reason', '未说明')}。")

    skipped = [k for k, v in (status.get("chunk_status") or {}).items() if v == "skipped"]
    if skipped:
        ordered = sorted(skipped, key=lambda s: int(s) if s.isdigit() else 0)
        notes.append(f"续跑跳过 {len(ordered)} 块："
                     f"{', '.join(ordered[:20])}{' …' if len(ordered) > 20 else ''}。")
    return notes


def build_report(state: str) -> tuple[str, dict[str, Any]]:
    cfg = read_json(os.path.join(state, "config.json"), {}) or {}
    status = read_json(os.path.join(state, "status.json"), {}) or {}
    structure = read_json(os.path.join(state, "structure.json"), {}) or {}
    glossary = read_json(os.path.join(state, "glossary.json"), {}) or {}
    conflicts_doc = read_json(os.path.join(state, "glossary_conflicts.json"), {}) or {}
    alignment = read_json(os.path.join(state, "alignment_report.json"), {}) or {}
    qa = read_json(os.path.join(state, "qa_issues.json"), {}) or {}
    boundary = read_json(os.path.join(state, "boundary_report.json"), {}) or {}
    events = read_events(state)

    total = _int(cfg.get("total_chunks")) or _int(structure.get("chunk_count")) \
        or _int(status.get("chunks_total"))
    done = _int(status.get("chunks_done"))
    failed = _int(status.get("chunks_failed"))
    skipped = _int(status.get("chunks_skipped"))

    src_chars = count_chars(state, total, zh=False)
    zh_chars = count_chars(state, total, zh=True)

    terms = [t for t in (glossary.get("terms") or []) if isinstance(t, dict)]
    locked = sum(1 for t in terms if t.get("locked"))
    auto = sum(1 for t in terms if t.get("origin") == "auto")
    user = sum(1 for t in terms if t.get("origin") == "user")

    all_conflicts = [c for c in (conflicts_doc.get("conflicts") or []) if isinstance(c, dict)]
    open_conflicts = [c for c in all_conflicts if not c.get("resolved")]

    qa_summary = qa.get("summary") or {}
    align_summary = alignment.get("summary") or {}

    compliant = status.get("compliant")
    missing_pre = missing_pre_extract(cfg, status, events)

    lines: list[str] = [
        "# 翻译交付报告",
        "",
        f"- 生成时间：{fmt_time(now())}",
        f"- 输入文件：`{cfg.get('input_path', '(未知)')}`",
        f"- 后端：`{cfg.get('backend', '(未知)')}`"
        f" ｜ skill 版本：`{cfg.get('skill_version', '(未知)')}`"
        f" ｜ app 版本：`{cfg.get('app_version', '(未知)')}`",
        f"- 执行路径：`{cfg.get('path_mode', 'full')}`"
        f" ｜ 预扫模式：`{cfg.get('prescan_mode', 'full')}`"
        f" ｜ 计划阶段：{', '.join(cfg.get('stages') or [])}",
        "",
        "## 1. 规模与进度",
        "",
        "| 指标 | 数值 |",
        "|---|---:|",
        f"| 总块数 | {total} |",
        f"| 已完成（含跳过） | {done} |",
        f"| 失败 | {failed} |",
        f"| 跳过 | {skipped} |",
        f"| 章节数 | {len(structure.get('chapters') or [])} |",
        f"| 原文字符数 | {src_chars} |",
        f"| 译文字符数 | {zh_chars} |",
        f"| 整体压缩比 | {round(zh_chars / src_chars, 4) if src_chars else 'n/a'} |",
        "",
        "## 2. 术语表",
        "",
        "| 指标 | 数值 |",
        "|---|---:|",
        f"| 术语总条数 | {len(terms)} |",
        f"| 锁定条目 | {locked} |",
        f"| 自动条目（origin=auto） | {auto} |",
        f"| 用户条目（origin=user） | {user} |",
        f"| 策略 | {glossary.get('policy', '(未知)')} |",
        f"| 冲突总数 | {len(all_conflicts)} |",
        f"| **未决冲突** | **{len(open_conflicts)}** |",
        "",
    ]

    if open_conflicts:
        lines.append("未决冲突明细（需人工裁决）：")
        lines.append("")
        lines.append("| id | 原文 | 现值 | 候选 | 块 | 阶段 |")
        lines.append("|---:|---|---|---|---:|---|")
        for c in open_conflicts[:30]:
            lines.append(
                f"| {c.get('id', '')} | {c.get('source', '')} | {c.get('existing_target', '')} "
                f"| {c.get('proposed_target', '')} | {c.get('chunk', '')} | {c.get('phase', '')} |")
        if len(open_conflicts) > 30:
            lines.append(f"| … | 其余 {len(open_conflicts) - 30} 条见 glossary_conflicts.json | | | | |")
        lines.append("")

    lines.extend([
        "## 3. 确定性质检（S6）",
        "",
        f"- 已检查块数：{_int(alignment.get('checked'))}",
        f"- 压缩比区间：{alignment.get('ratio_range', [0.55, 1.70])}",
        f"- error：{_int(align_summary.get('error'))} ｜ warn：{_int(align_summary.get('warn'))}",
        f"- 跨块边界可疑点：{_int(boundary.get('suspect_count'))}"
        f"（扫描 {_int(boundary.get('scanned'))} 块）",
        "",
    ])
    align_errors = [i for i in (alignment.get("issues") or [])
                    if isinstance(i, dict) and i.get("severity") == "error"]
    if align_errors:
        lines.append("对齐 error 明细：")
        lines.append("")
        lines.append("| 块 | 类型 | 详情 |")
        lines.append("|---:|---|---|")
        for issue in align_errors[:30]:
            detail = ", ".join(f"{k}={v}" for k, v in issue.items()
                               if k not in ("chunk", "kind", "severity"))
            lines.append(f"| {issue.get('chunk', '')} | {issue.get('kind', '')} | {detail} |")
        lines.append("")

    lines.extend([
        "## 4. 一致性 QA（S7）",
        "",
        f"- 问题总数：{_int(qa_summary.get('total'))}",
        f"- 术语应出现次数：{_int(qa_summary.get('terminology_expected'))}"
        f" ｜ 违例：{_int(qa_summary.get('terminology_violations'))}",
        f"- **术语符合率：{qa_summary.get('terminology_rate', 'n/a')}**"
        f"（F33-03 目标 ≥ 0.98）",
        "",
        "| 分类 | 数量 |",
        "|---|---:|",
    ])
    by_kind = qa_summary.get("by_kind") or {}
    for kind, label in KIND_LABELS.items():
        lines.append(f"| {label}（{kind}） | {_int(by_kind.get(kind))} |")
    by_sev = qa_summary.get("by_severity") or {}
    lines.extend([
        "",
        f"- 按严重度：error {_int(by_sev.get('error'))}"
        f" ｜ warn {_int(by_sev.get('warn'))}"
        f" ｜ info {_int(by_sev.get('info'))}",
        "",
        "## 5. 合规结论（F33-02）",
        "",
    ])

    if compliant is True:
        lines.append("- 结论：**合规** —— 每个已完成块都在翻译前完成了术语预抽。")
    elif compliant is False:
        lines.append("- 结论：**不合规** —— 存在「先翻译后抽词」或缺失预抽的块。")
    else:
        lines.append("- 结论：**未校验** —— 请运行 `state_tool.py verify --check all`。")
    if missing_pre:
        lines.append(f"- 缺失/乱序的块号：{', '.join(str(n) for n in missing_pre)}")
    else:
        lines.append("- 缺失/乱序的块号：无")
    lines.append("")

    notes = degradation_notes(cfg, status, events)
    lines.extend(["## 6. 降级与跳过说明", ""])
    if notes:
        lines.extend(f"- {note}" for note in notes)
    else:
        lines.append("- 无降级：九阶段全部按完整路径执行。")
    lines.append("")

    artifacts = status.get("artifacts") or {}
    lines.extend(["## 7. 交付物", "", "| 名称 | 路径 |", "|---|---|"])
    for key, label in (("zh_pdf", "中文 PDF"), ("ja_pdf", "日文 PDF"),
                       ("bi_pdf", "双语 PDF"), ("report", "本报告"),
                       ("glossary_csv", "术语表 CSV")):
        lines.append(f"| {label} | {artifacts.get(key) or '（未产出）'} |")
    lines.extend([
        "",
        f"- 事件总数：{len(events)} 条（`events.jsonl`）",
        f"- 最终状态：{status.get('message', '')}",
        "",
    ])

    # T10：API 用量章节（仅 LLM 管线有 usage.json 时渲染）
    lines.extend(_usage_lines(state))

    summary = {
        "total_chunks": total, "done": done, "failed": failed, "skipped": skipped,
        "src_chars": src_chars, "zh_chars": zh_chars,
        "terms": len(terms), "locked": locked, "auto": auto,
        "open_conflicts": len(open_conflicts),
        "qa_issues": _int(qa_summary.get("total")),
        "terminology_rate": qa_summary.get("terminology_rate"),
        "alignment_errors": _int(align_summary.get("error")),
        "compliant": compliant,
        "missing_pre_extract": missing_pre,
        "degradations": len(notes),
    }
    return "\n".join(lines).rstrip() + "\n", summary


def missing_pre_extract(cfg: dict[str, Any], status: dict[str, Any],
                        events: list[dict[str, Any]]) -> list[int]:
    """重跑一遍 §3.4 的时序判定，供报告独立列出缺失块号。"""
    params = cfg.get("params") or {}
    mode = params.get("pre_extract_mode", "always")
    if mode == "off":
        return []
    first_n = _int(params.get("pre_extract_first_n"), 10)
    total = _int(cfg.get("total_chunks")) or _int(status.get("chunks_total"))
    chunk_status = status.get("chunk_status") or {}

    first_pre: dict[int, int] = {}
    first_tr: dict[int, int] = {}
    for ev in events:
        chunk, seq = ev.get("chunk"), ev.get("seq")
        if not isinstance(chunk, int) or not isinstance(seq, int):
            continue
        if ev.get("type") == "glossary_pre_extract":
            if chunk not in first_pre or seq < first_pre[chunk]:
                first_pre[chunk] = seq
        elif ev.get("type") == "chunk_translated":
            if chunk not in first_tr or seq < first_tr[chunk]:
                first_tr[chunk] = seq

    bad: list[int] = []
    for n in range(1, total + 1):
        if chunk_status.get(str(n)) != "done":
            continue
        if mode == "firstNChunks" and n > first_n:
            continue
        pre, tr = first_pre.get(n), first_tr.get(n)
        if pre is None or tr is None or pre >= tr:
            bad.append(n)
    return bad


def fmt_time(epoch: float) -> str:
    import time
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(epoch))


def main(argv: list[str] | None = None) -> int:
    install_excepthook("make_report.py")
    ap = argparse.ArgumentParser(
        prog="make_report.py",
        description="汇总全部 state 产物为 report.md（F33-14）")
    ap.add_argument("--state", required=True, help="<outDir>/state 目录")
    ap.add_argument("--out", default="", help="覆盖输出路径，默认 <state>/report.md")
    args = ap.parse_args(argv)

    state = ensure_state(args.state)
    text, summary = build_report(state)
    out_path = args.out or os.path.join(state, "report.md")
    write_text_atomic(out_path, text)

    append_event(state, "report_written", stage="S8", actor="script",
                 data={"path": out_path})
    emit_json({"ok": True, "path": out_path, "chars": len(text), "summary": summary})
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
