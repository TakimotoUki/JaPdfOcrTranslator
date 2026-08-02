#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""qa_consistency.py — 一致性 QA（S7）

契约出处：DESIGN-v3.3 §3.9 / F33-03。五类扫描 + 两个副作用：

扫描（`kind` 值域见 §3.9）：
  1. `japanese_residue`  译文里残留假名 `[\\u3040-\\u30FF]`（排除代码围栏）
  2. `terminology`       源块命中术语 source，但译块里 target 出现次数不足
  3. `placeholder`       `{…}` / `%s` / `<tag>` 数量与源块不一致
  4. `number`            源块出现的数字在译块中缺失
  5. `punctuation`       日式括号残留、半角标点残留
  另有 `empty`（译块为空）、`paragraph`（段落数不等）、
  `suggestion`（policy A 下「疑似应入表」的只读建议，severity=info）

副作用：
  - 产出 `qa_issues.json`（§3.9），含 `terminology_rate`；
  - **回填 `glossary.json` 的 `hits`**（每条术语在全书源文中的出现次数）；
  - 追加 `qa_done` 事件（`issues`, `by_kind{}`, `term_rate`）。

术语符合率口径（F33-03 要求 ≥0.98）：
    terminology_expected   = Σ 每块每条命中术语在**源文**中的出现次数
    terminology_violations = Σ max(0, 源文出现次数 − 译文中 target 出现次数)
    terminology_rate       = 1 − violations / expected      （expected=0 时记 1.0）

用法:
  python qa_consistency.py --state <outDir>/state [--fail-on {none|error}]
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import unicodedata
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    EXIT_CHECK, EXIT_OK, EXIT_STATE, SCHEMA_VERSION, append_event, chunk_path,
    die, emit_json, ensure_state, file_lock, install_excepthook,
    merged_occurrence_count, norm_text, now, read_json, read_text, source_spans,
    split_paragraphs, strip_fenced, term_match_sources, write_json_atomic,
    make_parser,)

#: 假名区间（§3.9 明确给定）。汉字不算残留 —— 中文译文本来就有汉字。
KANA_RE = re.compile(r"[\u3040-\u30FF]")

#: 占位符三类。
PLACEHOLDER_RES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("brace", re.compile(r"\{[^{}\n]{0,40}\}")),
    ("printf", re.compile(r"%[-+ #0]?\d*(?:\.\d+)?[sdifgxXeEc]")),
    ("tag", re.compile(r"<[A-Za-z/][^<>\n]{0,40}>")),
)

#: 数字（NFKC 归一化后的 ASCII 数字串）。
NUMBER_RE = re.compile(r"\d+")

#: 日式括号残留 + 半角标点残留。
JP_BRACKETS = ("「", "」", "『", "』")
HALFWIDTH_PUNCT = (",", ".", "!", "?", ";", ":")

#: policy A 的入表建议：连续 3+ 片假名，且在全书出现 ≥3 次。
KATAKANA_RUN_RE = re.compile(r"[\u30A1-\u30FA\u30FC]{3,}")
SUGGESTION_MIN_OCCURRENCES = 3
SUGGESTION_MAX_ITEMS = 20

SEVERITY_ORDER = {"error": 0, "warn": 1, "info": 2}


def resolve_total(state: str) -> int:
    structure = read_json(os.path.join(state, "structure.json"), None)
    if isinstance(structure, dict) and isinstance(structure.get("chunk_count"), int):
        if structure["chunk_count"] > 0:
            return structure["chunk_count"]
    cfg = read_json(os.path.join(state, "config.json"), None)
    if isinstance(cfg, dict) and isinstance(cfg.get("total_chunks"), int):
        if cfg["total_chunks"] > 0:
            return cfg["total_chunks"]
    count = 0
    while os.path.isfile(chunk_path(state, count + 1, zh=False)):
        count += 1
    return count


def skipped_chunks(state: str) -> set[int]:
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


def line_of(text: str, needle: str) -> tuple[int, str]:
    """返回 `needle` 首次出现的 1-based 行号与该行摘录；找不到返回 `(0, "")`。"""
    if not needle:
        return 0, ""
    for i, line in enumerate(text.split("\n"), 1):
        if needle in line:
            stripped = line.strip()
            excerpt = stripped if len(stripped) <= 60 else stripped[:57] + "…"
            return i, excerpt
    return 0, ""


def count_occurrences(source: str, normalized: str) -> int:
    return merged_occurrence_count(source_spans(source, normalized))


class QAScanner:
    """把五类扫描聚在一个对象里，避免每类各读一遍磁盘。"""

    def __init__(self, state: str, terms: list[Any], conflicts: list[Any]):
        self.state = state
        self.terms = terms
        self.conflicts = conflicts
        self.issues: list[dict[str, Any]] = []
        self.next_id = 1
        self.hits: dict[str, int] = {t.source: 0 for t in terms}
        self.expected = 0
        self.violations = 0
        self.katakana_counter: dict[str, int] = {}

    def add(self, kind: str, severity: str, chunk: int | None = None,
            **extra: Any) -> None:
        issue: dict[str, Any] = {"id": self.next_id, "kind": kind, "severity": severity}
        if chunk is not None:
            issue["chunk"] = chunk
        issue.update(extra)
        self.issues.append(issue)
        self.next_id += 1

    # ── 单块扫描 ──────────────────────────────────────────────────────
    def scan_chunk(self, n: int) -> None:
        src_path = chunk_path(self.state, n, zh=False)
        zh_path = chunk_path(self.state, n, zh=True)
        if not os.path.isfile(src_path):
            return
        src_text = read_text(src_path)
        self._collect_katakana(src_text)

        if not os.path.isfile(zh_path):
            self.add("empty", "error", n, note="译块文件缺失",
                     path=os.path.relpath(zh_path, self.state))
            self._count_expected_only(src_text)
            return
        zh_text = read_text(zh_path)
        if not zh_text.strip():
            self.add("empty", "error", n, note="译块为空")
            self._count_expected_only(src_text)
            return

        zh_body = strip_fenced(zh_text)          # 围栏内不参与任何扫描
        src_body = strip_fenced(src_text)

        self._scan_japanese_residue(n, zh_text, zh_body)
        self._scan_terminology(n, src_body, zh_text, zh_body)
        self._scan_placeholder(n, src_body, zh_body)
        self._scan_number(n, src_body, zh_body)
        self._scan_punctuation(n, zh_text, zh_body)
        self._scan_paragraph(n, src_text, zh_text)

    def _count_expected_only(self, src_text: str) -> None:
        """译块缺失时，命中的术语全部计为违例，避免符合率被虚高。"""
        normalized = norm_text(strip_fenced(src_text))
        for term in self.terms:
            occ = self._term_occurrences(term, normalized)
            if occ:
                self.hits[term.source] = self.hits.get(term.source, 0) + occ
                self.expected += occ
                self.violations += occ

    def _term_occurrences(self, term: Any, normalized_src: str) -> int:
        spans: list[tuple[int, int]] = []
        for key in term_match_sources(term):
            if key:
                spans.extend(source_spans(key, normalized_src))
        return merged_occurrence_count(spans)

    # ── 1. 日文残留 ───────────────────────────────────────────────────
    def _scan_japanese_residue(self, n: int, zh_text: str, zh_body: str) -> None:
        for i, line in enumerate(zh_body.split("\n"), 1):
            found = KANA_RE.findall(line)
            if not found:
                continue
            stripped = line.strip()
            excerpt = stripped if len(stripped) <= 60 else stripped[:57] + "…"
            self.add("japanese_residue", "error", n, line=i,
                     found="".join(sorted(set(found)))[:20],
                     count=len(found), excerpt=excerpt,
                     suggestion="该行仍有假名，请确认是否漏译或应保留为专有名词")

    # ── 2. 术语违例 ───────────────────────────────────────────────────
    def _scan_terminology(self, n: int, src_body: str, zh_text: str,
                          zh_body: str) -> None:
        normalized_src = norm_text(src_body)
        normalized_zh = norm_text(zh_body)
        for term in self.terms:
            occ = self._term_occurrences(term, normalized_src)
            if occ <= 0:
                continue
            self.hits[term.source] = self.hits.get(term.source, 0) + occ
            self.expected += occ
            actual = count_occurrences(term.target, normalized_zh) if term.target else 0
            if actual >= occ:
                continue
            missing = occ - actual
            self.violations += missing
            found = self._guess_wrong_rendering(term, normalized_zh, zh_body)
            line, excerpt = line_of(zh_text, found or term.source)
            self.add("terminology", "error", n, line=line,
                     source=term.source, expected=term.target, found=found,
                     occurrences=occ, matched=actual, missing=missing,
                     excerpt=excerpt,
                     suggestion=f"改为「{term.target}」")

    def _guess_wrong_rendering(self, term: Any, normalized_zh: str,
                               zh_body: str) -> str:
        """从冲突表里找「本该被拒绝却出现在译文中」的候选译名，用作 `found`。"""
        for c in self.conflicts:
            if c.source != term.source:
                continue
            for candidate in (c.proposed_target, c.existing_target):
                if not candidate or candidate == term.target:
                    continue
                if count_occurrences(candidate, normalized_zh) > 0:
                    return candidate
        if count_occurrences(term.source, normalized_zh) > 0:
            return term.source            # 原文原样残留在译文里
        return ""

    # ── 3. 占位符 ─────────────────────────────────────────────────────
    def _scan_placeholder(self, n: int, src_body: str, zh_body: str) -> None:
        for label, pattern in PLACEHOLDER_RES:
            src_items = pattern.findall(src_body)
            zh_items = pattern.findall(zh_body)
            if len(src_items) == len(zh_items):
                continue
            self.add("placeholder", "error", n, kind_detail=label,
                     src_count=len(src_items), zh_count=len(zh_items),
                     found=", ".join(sorted(set(src_items))[:5]),
                     suggestion=f"占位符 {label} 数量不一致，请逐一核对后补齐")

    # ── 4. 数字 ───────────────────────────────────────────────────────
    def _scan_number(self, n: int, src_body: str, zh_body: str) -> None:
        src_numbers = NUMBER_RE.findall(unicodedata.normalize("NFKC", src_body))
        zh_numbers = NUMBER_RE.findall(unicodedata.normalize("NFKC", zh_body))
        pool: dict[str, int] = {}
        for value in zh_numbers:
            pool[value] = pool.get(value, 0) + 1
        missing: list[str] = []
        for value in src_numbers:
            if pool.get(value, 0) > 0:
                pool[value] -= 1
            else:
                missing.append(value)
        if not missing:
            return
        self.add("number", "warn", n,
                 found=", ".join(missing[:8]), count=len(missing),
                 suggestion="源文中的数字在译文里缺失，请确认是否改写为汉字数字")

    # ── 5. 标点 ───────────────────────────────────────────────────────
    def _scan_punctuation(self, n: int, zh_text: str, zh_body: str) -> None:
        residue = {ch: zh_body.count(ch) for ch in JP_BRACKETS if ch in zh_body}
        if residue:
            line, excerpt = line_of(zh_text, next(iter(residue)))
            self.add("punctuation", "warn", n, line=line,
                     found="".join(residue.keys()),
                     count=sum(residue.values()), excerpt=excerpt,
                     suggestion="日式括号残留，请运行 normalize_punct.py")
        half = {ch: zh_body.count(ch) for ch in HALFWIDTH_PUNCT if zh_body.count(ch)}
        if half:
            self.add("punctuation", "info", n,
                     found="".join(half.keys()), count=sum(half.values()),
                     suggestion="存在半角标点，若非专有名词/数字请全角化")

    # ── 段落数 ────────────────────────────────────────────────────────
    def _scan_paragraph(self, n: int, src_text: str, zh_text: str) -> None:
        src_paras = len(split_paragraphs(src_text))
        zh_paras = len(split_paragraphs(zh_text))
        if src_paras == zh_paras:
            return
        self.add("paragraph", "warn", n,
                 src_paragraphs=src_paras, zh_paragraphs=zh_paras,
                 delta=zh_paras - src_paras,
                 suggestion="段落数与源文不一致，详见 alignment_report.json")

    # ── 建议（policy A 专用，只读）────────────────────────────────────
    def _collect_katakana(self, src_text: str) -> None:
        for token in KATAKANA_RUN_RE.findall(strip_fenced(src_text)):
            self.katakana_counter[token] = self.katakana_counter.get(token, 0) + 1

    def emit_suggestions(self) -> None:
        """情形 A 下给出「疑似应入表但未入表」的只读建议（Q2 决策）。"""
        known: set[str] = set()
        for term in self.terms:
            for key in term_match_sources(term):
                if key:
                    known.add(norm_text(key))
        candidates = [
            (token, count) for token, count in self.katakana_counter.items()
            if count >= SUGGESTION_MIN_OCCURRENCES and norm_text(token) not in known
        ]
        candidates.sort(key=lambda item: (-item[1], item[0]))
        for token, count in candidates[:SUGGESTION_MAX_ITEMS]:
            self.add("suggestion", "info", None, source=token, occurrences=count,
                     suggestion=f"「{token}」全书出现 {count} 次但不在术语表中，"
                                f"当前策略为 A（用户表逐字执行），仅作提示不自动入表")


def backfill_hits(state: str, hits: dict[str, int]) -> int:
    """把全书命中次数写回 `glossary.json`。

    走 `GlossaryStore` 而不是自己改 JSON —— `glossary.json` 的写语义只有
    `glossary_tool.py` 一份实现（决策 D2），这里复用同一个类即视为同一写者。
    """
    if not hits:
        return 0
    try:
        from glossary_tool import GlossaryStore
    except ImportError:
        return 0
    updated = 0
    with file_lock(state, "glossary"):
        store = GlossaryStore(state)
        if not store.exists():
            return 0
        store.load(required=False)
        for term in store.all_terms():
            value = hits.get(term.source)
            if value is None or term.hits == value:
                continue
            term.hits = value
            updated += 1
        if updated:
            store.save()
    return updated


def main(argv: list[str] | None = None) -> int:
    install_excepthook("qa_consistency.py")
    ap = make_parser(
        prog="qa_consistency.py",
        description="一致性 QA，产出 qa_issues.json 并回填术语 hits（§3.9 / F33-03）")
    ap.add_argument("--state", required=True, help="<outDir>/state 目录")
    ap.add_argument("--fail-on", dest="fail_on", choices=("none", "error"),
                    default="none",
                    help="error=存在 error 级问题时退 5（默认 none，QA 只报告不阻断）")
    ap.add_argument("--min-term-rate", dest="min_term_rate", type=float, default=0.0,
                    help="术语符合率下限，低于则退 5（默认 0 表示不校验）")
    args = ap.parse_args(argv)

    state = ensure_state(args.state)
    total = resolve_total(state)
    if total <= 0:
        die(EXIT_STATE, f"未找到任何块：{os.path.join(state, 'chunks')}\n"
                        f"  请先运行 split_text.py 并完成翻译。")

    terms: list[Any] = []
    conflicts: list[Any] = []
    policy = "C"
    try:
        from glossary_tool import GlossaryStore
        store = GlossaryStore(state)
        if store.exists():
            store.load(required=False)
            terms = store.all_terms()
            conflicts = store.conflicts()
            policy = store.policy
    except ImportError:
        pass

    scanner = QAScanner(state, terms, conflicts)
    skipped = skipped_chunks(state)
    for n in range(1, total + 1):
        if n in skipped:
            continue
        scanner.scan_chunk(n)
    if policy == "A":
        scanner.emit_suggestions()

    by_kind: dict[str, int] = {}
    by_severity: dict[str, int] = {}
    for issue in scanner.issues:
        by_kind[issue["kind"]] = by_kind.get(issue["kind"], 0) + 1
        by_severity[issue["severity"]] = by_severity.get(issue["severity"], 0) + 1
    for kind in ("japanese_residue", "terminology", "placeholder", "number",
                 "punctuation", "paragraph", "empty", "suggestion"):
        by_kind.setdefault(kind, 0)
    for severity in ("error", "warn", "info"):
        by_severity.setdefault(severity, 0)

    rate = 1.0 if scanner.expected == 0 else \
        max(0.0, 1.0 - scanner.violations / scanner.expected)
    issues = sorted(scanner.issues,
                    key=lambda i: (SEVERITY_ORDER.get(i["severity"], 9),
                                   i.get("chunk") or 0, i["id"]))

    report = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": round(now(), 3),
        "summary": {
            "total": len(issues),
            "by_kind": by_kind,
            "by_severity": by_severity,
            "terminology_expected": scanner.expected,
            "terminology_violations": scanner.violations,
            "terminology_rate": round(rate, 4),
        },
        "issues": issues,
    }
    write_json_atomic(os.path.join(state, "qa_issues.json"), report)

    updated = backfill_hits(state, scanner.hits)
    append_event(state, "qa_done", stage="S7", actor="script",
                 data={"issues": len(issues), "by_kind": by_kind,
                       "term_rate": round(rate, 4)})

    emit_json({
        "ok": True,
        "issues": len(issues),
        "by_kind": by_kind,
        "by_severity": by_severity,
        "terminology_expected": scanner.expected,
        "terminology_violations": scanner.violations,
        "terminology_rate": round(rate, 4),
        "hits_backfilled": updated,
        "policy": policy,
        "path": os.path.join(state, "qa_issues.json"),
    })

    if args.min_term_rate > 0 and rate < args.min_term_rate:
        sys.stderr.write(
            f"qa_consistency: 术语符合率 {rate:.4f} 低于下限 {args.min_term_rate:.4f}\n")
        return EXIT_CHECK
    if args.fail_on == "error" and by_severity.get("error", 0) > 0:
        sys.stderr.write(
            f"qa_consistency: 存在 {by_severity['error']} 个 error 级问题\n")
        return EXIT_CHECK
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
