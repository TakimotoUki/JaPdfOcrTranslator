#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""glossary_tool.py — 术语库唯一写入口（v3.3 的心脏）

契约出处：DESIGN-v3.3 §4.1–§4.9。**本文件是 `glossary.json` 与
`glossary_conflicts.json` 的唯一写者**（决策 D2）：Swift 侧只读不写，
两个翻译后端都通过子进程调用本脚本，从而保证 upsert 三态、locked 优先级、
别名合并、NFKC 词边界匹配这些语义**永不漂移**。

九个子命令：
    init      初始化术语库（幂等，续跑的关键）
    upsert    写入术语（唯一写路径，§4.2 判定表）
    hits      命中裁剪（§4.3 匹配算法）
    render    渲染完整提示词块（两后端注入术语约束的唯一函数）
    conflicts 冲突查询
    resolve   冲突裁决
    export    导出（csv2 / csv5 / json）
    import    导入外部术语
    stats     统计

退出码（§4.0）：0 成功（含「部分条目被拒绝」）/ 1 用法错 / 2 IO 或锁错 /
3 输入 JSON 畸形 / 4 未初始化或目标不存在 / 5 检查未通过。
"""

from __future__ import annotations

import argparse
import csv
import io
import os
import sys
from dataclasses import dataclass, field, asdict
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    DEFAULT_TERM_TYPE, EXIT_CHECK, EXIT_INPUT, EXIT_OK, EXIT_STATE, EXIT_USAGE,
    SCHEMA_VERSION, append_event, conflicts_path, chunk_path, die, emit_json,
    ensure_state, file_lock, glossary_path, install_excepthook, norm_text, now,
    normalize_term_type, read_json, read_stdin_json, read_text, source_matches,
    term_match_sources, write_json_atomic, write_text_atomic,
    make_parser,
    UsageErrorParser,)

POLICIES = ("A", "B", "C", "D")

#: 策略段文案（DESIGN §7.2）。
#: **必须与 Swift 侧 `GlossaryPolicy.promptText` 逐字一致** —— 这是 F33-03
#: 术语符合率能跨后端比较的前提，T04 会做 `diff` 交叉验收。
POLICY_PROMPTS: dict[str, str] = {
    "A": """【术语表策略｜情形 A：用户表锁定 · 禁止新增】
1. 下方术语表由用户提供，是本次翻译的最高权威。表中每一条的中文译名必须逐字执行，
   任何情况下不得改写、简化、意译、加注或调整用字。
2. 表中未列出的专名（人名、地名、组织名、作品内术语等），沿用其在前文译文中首次出现的
   译法，保持全书一致；不得另起新译名。
3. 本次不建立、不扩充自动术语表。禁止调用 glossary_tool.py upsert 新增词条。
4. 若你认为某个未入表的专名应当入表，不要改表 —— 通过
   `state_tool.py event --type glossary_suggestion --chunk N --json '{"source":"…","target":"…"}'`
   留下只读建议，由用户事后裁决。""",
    "B": """【术语表策略｜情形 B：用户表锁定 + 自动补充（默认）】
1. 术语表分两组，优先级严格有别：
   · 【锁定词条】(locked) —— 用户提供，优先级最高，必须逐字执行，任何情况下不得改写。
   · 【自动词条】(auto)   —— 软件维护，遇到新专名请补入；已有条目优先沿用现值。
2. 两组冲突时**无条件服从锁定词条**。你给出的任何与锁定词条不同的译名都会被系统丢弃
   并记为违例（rejected_by_lock），出现在最终质量报告里。
3. 【硬性时序】翻译第 N 块**之前**，必须先对该块源文做术语预抽取并写库：
   `glossary_tool.py upsert --state <state> --chunk N --phase pre --stdin`
   即使一条新词都没有，也必须以 {"terms":[]} 调用一次 —— 这是流程合规的唯一证据。
4. 翻译时只使用系统给出的【本块命中术语】子集；未命中的词条与本块无关，不要硬塞进译文。
5. 翻译完成后，用「原文 + 译文」回抽校准实际采用的译名：`--phase post --chunk N`。
6. 不得对已存在的 source 提出新译名。若确有充分理由，也只记冲突、不改表。""",
    "C": """【术语表策略｜情形 C：全自动术语表（默认）】
1. 用户未提供术语表。你必须**自行建立并持续维护**一份术语表，作为全书译名一致性的唯一口径。
2. 同一专名全书必须使用同一译名。首次确定的译法即为基准，后文不得改译。
3. 【硬性时序】翻译第 N 块**之前**，必须先对该块源文做术语预抽取并写库：
   `glossary_tool.py upsert --state <state> --chunk N --phase pre --stdin`
   即使一条新词都没有，也必须以 {"terms":[]} 调用一次。
4. 翻译完成后回抽校准：`--phase post --chunk N`，依据译文中**实际采用**的写法填 target，
   不要凭空创造译名。
5. 应当入表：人名、地名、组织名、作品内专有术语、招式名、物品名、设定名；
   同一实体的称呼变体（昵称／敬称／职称／亲属称呼／外号，应作为独立条目而非仅放 aliases）；
   需全书统一的口癖、咒语、标语、固定台词。
   不应入表：普通寒暄、通用词汇、一次性修辞、普通语气词。
6. 同一 source 出现不同译名时，系统**保留现值并记冲突**，绝不静默覆盖；请优先沿用现值。""",
    "D": """【术语表策略｜情形 D：不维护术语表】
本次运行不建立术语表，也不做术语一致性校验。请仅凭上下文保持译名前后一致。
（用户已在设置中关闭「自动生成/补充术语表」且未提供自定义术语表。）""",
}

#: CSV 表头识别用的候选列名（两栏 / 五栏自动识别）。
_HEADER_FIRST = {"日语", "日文", "原文", "source", "japanese", "ja"}
_HEADER_SECOND = {"中文", "译名", "译文", "target", "chinese", "zh"}

#: csv5 的「来源」列取值 ↔ origin 枚举。
_ORIGIN_CN = {"user": "用户", "auto": "自动"}
_CN_ORIGIN = {"用户": "user", "自动": "auto"}


# ══════════════════════════════════════════════════════════════════════════
# 数据结构（DESIGN §3.6 / §3.7）
# ══════════════════════════════════════════════════════════════════════════

@dataclass
class GlossaryTerm:
    """`glossary.json.terms[]` 的一条（§3.6，11 个语义字段 + 2 个时间戳）。"""

    source: str
    target: str
    reading: str = ""
    type: str = DEFAULT_TERM_TYPE
    gender: str = ""
    aliases: list[str] = field(default_factory=list)
    note: str = ""
    origin: str = "auto"          # user | auto
    locked: bool = False          # origin=user ⇒ locked=true
    status: str = "ok"            # ok | conflict
    first_chunk: int | None = None
    hits: int = 0
    created_at: float = 0.0
    updated_at: float = 0.0

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "GlossaryTerm":
        """从 JSON 对象构造，未知/缺失字段一律取默认值（向前兼容）。"""
        aliases = d.get("aliases") or []
        if not isinstance(aliases, list):
            aliases = []
        first_chunk = d.get("first_chunk")
        if isinstance(first_chunk, bool) or not isinstance(first_chunk, int):
            first_chunk = None
        ts = float(d.get("created_at") or 0.0)
        return cls(
            source=str(d.get("source") or ""),
            target=str(d.get("target") or ""),
            reading=str(d.get("reading") or ""),
            type=normalize_term_type(d.get("type")),
            gender=str(d.get("gender") or ""),
            aliases=[str(a) for a in aliases if str(a).strip()],
            note=str(d.get("note") or ""),
            origin="user" if d.get("origin") == "user" else "auto",
            locked=bool(d.get("locked")),
            status="conflict" if d.get("status") == "conflict" else "ok",
            first_chunk=first_chunk,
            hits=int(d.get("hits") or 0),
            created_at=ts,
            updated_at=float(d.get("updated_at") or ts),
        )

    def to_dict(self) -> dict[str, Any]:
        """按 §3.6 的字段顺序序列化（字段名与顺序都是契约的一部分）。"""
        return {
            "source": self.source,
            "target": self.target,
            "reading": self.reading,
            "type": self.type,
            "gender": self.gender,
            "aliases": list(self.aliases),
            "note": self.note,
            "origin": self.origin,
            "locked": self.locked,
            "status": self.status,
            "first_chunk": self.first_chunk,
            "hits": self.hits,
            "created_at": round(self.created_at, 3),
            "updated_at": round(self.updated_at, 3),
        }


@dataclass
class Conflict:
    """`glossary_conflicts.json.conflicts[]` 的一条（§3.7）。"""

    id: int
    source: str
    existing_target: str
    proposed_target: str
    chunk: int | None = None
    phase: str = "manual"         # pre | post | import | manual
    resolved: bool = False
    resolution: str = ""          # "" | rejected_by_lock | resolved_by_user
                                  # | resolved_by_agent | superseded
    resolved_by: str = ""         # system | user | agent
    created_at: float = 0.0
    resolved_at: float = 0.0

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Conflict":
        chunk = d.get("chunk")
        if isinstance(chunk, bool) or not isinstance(chunk, int):
            chunk = None
        return cls(
            id=int(d.get("id") or 0),
            source=str(d.get("source") or ""),
            existing_target=str(d.get("existing_target") or ""),
            proposed_target=str(d.get("proposed_target") or ""),
            chunk=chunk,
            phase=str(d.get("phase") or "manual"),
            resolved=bool(d.get("resolved")),
            resolution=str(d.get("resolution") or ""),
            resolved_by=str(d.get("resolved_by") or ""),
            created_at=float(d.get("created_at") or 0.0),
            resolved_at=float(d.get("resolved_at") or 0.0),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "source": self.source,
            "existing_target": self.existing_target,
            "proposed_target": self.proposed_target,
            "chunk": self.chunk,
            "phase": self.phase,
            "resolved": self.resolved,
            "resolution": self.resolution,
            "resolved_by": self.resolved_by,
            "created_at": round(self.created_at, 3),
            "resolved_at": round(self.resolved_at, 3),
        }


# ══════════════════════════════════════════════════════════════════════════
# 术语库
# ══════════════════════════════════════════════════════════════════════════

class GlossaryStore:
    """`glossary.json` + `glossary_conflicts.json` 的内存视图与事务写回。

    使用模式（§4.0 原子性）——**单次子命令 = 一个事务**：

        with file_lock(state, "glossary"):
            store = GlossaryStore(state); store.load()
            ...计算...
            store.save()        # 一次性原子写回两个文件

    任一步抛异常都不会落盘，因为 `save()` 是最后一步且内部用
    `tmp + os.replace` 原子替换。
    """

    def __init__(self, state_dir: str):
        self.state_dir = state_dir
        self.policy = "C"
        self._terms: dict[str, GlossaryTerm] = {}
        self._conflicts: list[Conflict] = []
        self._next_id = 1
        self._loaded = False

    # ── 载入 / 落盘 ────────────────────────────────────────────────────
    def exists(self) -> bool:
        return os.path.isfile(glossary_path(self.state_dir))

    def load(self, required: bool = True) -> None:
        """全量读入内存。`required=True` 时缺文件以 `EXIT_STATE` 退出。"""
        gpath = glossary_path(self.state_dir)
        data = read_json(gpath)
        if data is None:
            if required:
                die(EXIT_STATE,
                    f"术语库未初始化：{gpath}\n  请先运行 glossary_tool.py init --state <dir> --policy <A|B|C|D>。")
            data = {}
        if not isinstance(data, dict):
            die(EXIT_STATE, f"术语库格式非法（顶层应为对象）：{gpath}")

        version = data.get("schema_version", SCHEMA_VERSION)
        if isinstance(version, int) and version > SCHEMA_VERSION:
            die(EXIT_STATE,
                f"术语库 schema_version={version} 高于本 skill 支持的 {SCHEMA_VERSION}：{gpath}\n"
                f"  请升级应用后再继续，不要用旧版本改写新格式数据。")

        policy = data.get("policy")
        self.policy = policy if policy in POLICIES else "C"
        self._terms = {}
        for raw in data.get("terms") or []:
            if not isinstance(raw, dict):
                continue
            term = GlossaryTerm.from_dict(raw)
            if term.source:
                self._terms[term.source] = term

        cdata = read_json(conflicts_path(self.state_dir), {}) or {}
        self._conflicts = [
            Conflict.from_dict(c) for c in (cdata.get("conflicts") or [])
            if isinstance(c, dict)
        ]
        raw_next = cdata.get("next_id")
        computed = max((c.id for c in self._conflicts), default=0) + 1
        self._next_id = raw_next if isinstance(raw_next, int) and raw_next >= computed else computed
        self._loaded = True

    def save(self) -> None:
        """一次性原子写回 glossary + conflicts（L2：同一把锁的同一次持有内）。"""
        stamp = now()
        payload = {
            "schema_version": SCHEMA_VERSION,
            "updated_at": round(stamp, 3),
            "policy": self.policy,
            "terms": [t.to_dict() for t in self.sorted_terms()],
        }
        write_json_atomic(glossary_path(self.state_dir), payload)
        write_json_atomic(conflicts_path(self.state_dir), {
            "schema_version": SCHEMA_VERSION,
            "next_id": self._next_id,
            "conflicts": [c.to_dict() for c in self._conflicts],
        })

    def sorted_terms(self) -> list[GlossaryTerm]:
        """稳定排序 `(type, source)`（§3.6），保证 JSON 可 diff。"""
        return sorted(self._terms.values(), key=lambda t: (t.type, t.source))

    # ── 查询 ──────────────────────────────────────────────────────────
    def get(self, source: str) -> GlossaryTerm | None:
        return self._terms.get(source)

    def all_terms(self) -> list[GlossaryTerm]:
        return self.sorted_terms()

    def open_conflicts(self) -> list[Conflict]:
        return [c for c in self._conflicts if not c.resolved]

    def conflicts(self) -> list[Conflict]:
        return list(self._conflicts)

    # ── 写入（§4.2 判定表）──────────────────────────────────────────────
    def upsert(self, term: GlossaryTerm, chunk: int | None = None,
               phase: str = "manual") -> str:
        """按 §4.2 判定表写入一条候选，返回判定结果字符串。

        返回值 ∈ {invalid, rejected_by_policy, inserted, unchanged,
                  rejected_by_lock, conflict}

        判定顺序**严格照抄** DESIGN §4.2 的表格，逐行对应：

        | 条件                                   | 结果               |
        |----------------------------------------|--------------------|
        | source 或 target 为空                  | invalid            |
        | policy == D                            | rejected_by_policy |
        | policy == A 且 source 不在库中         | rejected_by_policy |
        | source 不在库中（policy B/C）          | inserted           |
        | 已存在 且 locked 且 target 相同        | unchanged          |
        | 已存在 且 locked 且 target 不同        | rejected_by_lock   |
        | 已存在 且 !locked 且 target 相同       | unchanged          |
        | 已存在 且 !locked 且 target 不同       | conflict           |
        """
        source = (term.source or "").strip()
        target = (term.target or "").strip()
        if not source or not target:
            return "invalid"

        existing = self._terms.get(source)

        # policy D 不维护术语表：全部丢弃（含已存在的 source）。
        if self.policy == "D":
            return "rejected_by_policy"
        # policy A 纯用户表：禁止新增，但允许对已有词条做别名/字段补全。
        if self.policy == "A" and existing is None:
            return "rejected_by_policy"

        stamp = now()
        if existing is None:
            term.source = source
            term.target = target
            term.type = normalize_term_type(term.type)
            term.aliases = self._clean_aliases(term.aliases, source)
            term.origin = term.origin if term.origin in ("user", "auto") else "auto"
            term.locked = True if term.origin == "user" else bool(term.locked)
            term.status = "ok"
            # first_chunk：首次出现即定格，此后永不更新。
            if term.first_chunk is None:
                term.first_chunk = chunk
            term.created_at = stamp
            term.updated_at = stamp
            self._terms[source] = term
            return "inserted"

        if existing.target == target:
            # target 相同 —— 合并 aliases 并补全空字段，不动 target。
            self._merge_into(existing, term, stamp)
            return "unchanged"

        # target 不同 —— 分锁定/未锁定两种处置。
        if existing.locked:
            # 丢弃候选，只留证据；**不改 status**（锁定词条不进裁决队列）。
            self._log_conflict(source, existing.target, target, chunk, phase,
                               resolved=True, resolution="rejected_by_lock",
                               resolved_by="system")
            return "rejected_by_lock"

        # 未锁定：保留现值 + 标记 conflict + 记一条待裁决冲突。
        self._log_conflict(source, existing.target, target, chunk, phase,
                           resolved=False, resolution="", resolved_by="")
        existing.status = "conflict"
        existing.updated_at = stamp
        return "conflict"

    @staticmethod
    def _clean_aliases(aliases: list[str], source: str) -> list[str]:
        """`sorted(set(...))` 并剔除等于 source 的项与空串（§4.2 注）。"""
        return sorted({a.strip() for a in aliases if a and a.strip() and a.strip() != source})

    def _merge_into(self, existing: GlossaryTerm, incoming: GlossaryTerm,
                    stamp: float) -> None:
        """target 相同的合并：aliases 取并集，空字段用候选值补齐。"""
        merged = set(existing.aliases) | set(incoming.aliases or [])
        existing.aliases = self._clean_aliases(sorted(merged), existing.source)
        if not existing.reading and incoming.reading:
            existing.reading = incoming.reading
        if not existing.gender and incoming.gender:
            existing.gender = incoming.gender
        if not existing.note and incoming.note:
            existing.note = incoming.note
        # 类型只在现值为默认值时才被更精确的候选类型覆盖。
        if existing.type == DEFAULT_TERM_TYPE and incoming.type != DEFAULT_TERM_TYPE:
            existing.type = normalize_term_type(incoming.type)
        existing.updated_at = stamp

    def _log_conflict(self, source: str, existing_target: str, proposed_target: str,
                      chunk: int | None, phase: str, *, resolved: bool,
                      resolution: str, resolved_by: str) -> int:
        """追加一条冲突记录，返回其 id。与 upsert 同属一个事务。"""
        stamp = now()
        record = Conflict(
            id=self._next_id,
            source=source,
            existing_target=existing_target,
            proposed_target=proposed_target,
            chunk=chunk,
            phase=phase,
            resolved=resolved,
            resolution=resolution,
            resolved_by=resolved_by,
            created_at=stamp,
            resolved_at=stamp if resolved else 0.0,
        )
        self._conflicts.append(record)
        self._next_id += 1
        return record.id

    # ── 命中裁剪（§4.3）───────────────────────────────────────────────
    def hits(self, text: str, scope: str = "chunk",
             max_n: int = 0) -> tuple[list[GlossaryTerm], bool]:
        """返回 `(命中词条, 是否被截断)`。

        `scope == "full"` 时忽略匹配直接返回全表（对应 `settings.glossaryScope=full`）。
        否则执行 §4.3 五步匹配：整段文本只归一化一次，再对每个候选键判定。
        """
        if scope == "full":
            matched = self.sorted_terms()
        else:
            normalized = norm_text(text)
            matched = [
                t for t in self.sorted_terms()
                if any(source_matches(key, normalized) for key in term_match_sources(t) if key)
            ]

        truncated = False
        if max_n and len(matched) > max_n:
            # 截断优先级：locked 优先 → hits 降序 → first_chunk 升序。
            matched = sorted(
                matched,
                key=lambda t: (0 if t.locked else 1, -t.hits,
                               t.first_chunk if t.first_chunk is not None else 1 << 30,
                               t.type, t.source),
            )[:max_n]
            matched = sorted(matched, key=lambda t: (t.type, t.source))
            truncated = True
        return matched, truncated

    # ── 渲染（§4.3 md 格式）────────────────────────────────────────────
    @staticmethod
    def render_md(terms: list[GlossaryTerm]) -> str:
        """渲染 `--format md` 的术语块。

        这是 WB 与 DS 两后端注入术语约束的**唯一**文本来源，
        因此格式必须与 §4.3 的样例逐字相同。
        """
        if not terms:
            return "【本块命中术语】（暂无）"
        locked = [t for t in terms if t.locked]
        auto = [t for t in terms if not t.locked]
        lines = ["【本块命中术语（必须遵守）】"]
        if locked:
            lines.append("■ 锁定词条（用户提供，逐字执行，不得改写）")
            lines.extend(GlossaryStore._term_line(t) for t in locked)
        if auto:
            lines.append("■ 自动词条（软件维护，如需修正请记冲突，勿直接改译）")
            lines.extend(GlossaryStore._term_line(t) for t in auto)
        return "\n".join(lines)

    @staticmethod
    def _term_line(t: GlossaryTerm) -> str:
        """单条术语行：`- 御堂 静 → 御堂静（人物，女，读音:みどう しずか） [别名: 静ちゃん] ※女主角`"""
        meta = [t.type]
        if t.gender:
            meta.append(t.gender)
        if t.reading:
            meta.append(f"读音:{t.reading}")
        line = f"- {t.source} → {t.target}（{'，'.join(meta)}）"
        if t.aliases:
            line += f" [别名: {', '.join(t.aliases)}]"
        if t.note:
            line += f" ※{t.note}"
        return line

    # ── 裁决（§4.6）───────────────────────────────────────────────────
    def resolve(self, source: str, target: str, lock: bool, by: str) -> dict[str, Any]:
        """把 source 的最终译名定为 target，并把它的全部未决冲突标记为已裁决。"""
        term = self._terms.get(source)
        if term is None:
            die(EXIT_STATE, f"术语不存在，无法裁决：{source}")
        stamp = now()
        term.target = target
        term.status = "ok"
        if lock:
            term.locked = True
        term.updated_at = stamp
        resolved_count = 0
        for c in self._conflicts:
            if c.source == source and not c.resolved:
                c.resolved = True
                c.resolution = f"resolved_by_{by}"
                c.resolved_by = by
                c.resolved_at = stamp
                resolved_count += 1
        return {
            "ok": True,
            "source": source,
            "target": target,
            "locked": term.locked,
            "resolved_conflicts": resolved_count,
            "open_conflicts": len(self.open_conflicts()),
        }

    # ── 统计（§4.9）───────────────────────────────────────────────────
    def stats(self) -> dict[str, Any]:
        terms = self.sorted_terms()
        by_type: dict[str, int] = {}
        by_status: dict[str, int] = {}
        for t in terms:
            by_type[t.type] = by_type.get(t.type, 0) + 1
            by_status[t.status] = by_status.get(t.status, 0) + 1
        return {
            "ok": True,
            "terms": len(terms),
            "locked": sum(1 for t in terms if t.locked),
            "auto": sum(1 for t in terms if t.origin == "auto"),
            "open_conflicts": len(self.open_conflicts()),
            "by_type": by_type,
            "by_status": by_status,
            "policy": self.policy,
            "updated_at": round(now(), 3),
        }

    # ── 导出 / 导入（§4.7 / §4.8）─────────────────────────────────────
    def export(self, path: str, fmt: str, origin: str, only_ok: bool) -> int:
        """导出术语表，返回写出的行数。"""
        terms = self.sorted_terms()
        if origin in ("user", "auto"):
            terms = [t for t in terms if t.origin == origin]
        if only_ok:
            terms = [t for t in terms if t.status == "ok"]

        if fmt == "json":
            write_json_atomic(path, {
                "schema_version": SCHEMA_VERSION,
                "updated_at": round(now(), 3),
                "policy": self.policy,
                "terms": [t.to_dict() for t in terms],
            })
            return len(terms)

        buf = io.StringIO()
        writer = csv.writer(buf, lineterminator="\n")
        if fmt == "csv2":
            writer.writerow(["日语", "中文"])
            for t in terms:
                writer.writerow([t.source, t.target])
        else:  # csv5
            writer.writerow(["日语", "中文", "类型", "来源", "备注"])
            for t in terms:
                writer.writerow([t.source, t.target, t.type,
                                 _ORIGIN_CN.get(t.origin, "自动"), t.note])
        write_text_atomic(path, buf.getvalue())
        return len(terms)

    def import_(self, path: str, origin: str, lock: bool,
                overwrite: bool) -> dict[str, int]:
        """导入外部 CSV/JSON。返回 `{added, updated, skipped}`。

        - 不给 `--overwrite`：严格遵循 §4.2 的 upsert 判定表；
        - 给了 `--overwrite`（仅 `--origin user` 允许）：强制覆盖 target，
          用于「把编辑器里的用户表推进正在跑的 state」这一显式用户操作。
        """
        rows = load_terms_file(path)
        added = updated = skipped = 0
        stamp = now()
        for raw in rows:
            source = (raw.get("source") or "").strip()
            target = (raw.get("target") or "").strip()
            if not source or not target:
                skipped += 1
                continue
            existing = self._terms.get(source)
            if overwrite and existing is not None:
                existing.target = target
                existing.origin = origin
                existing.locked = True if (lock or origin == "user") else existing.locked
                existing.status = "ok"
                merged = set(existing.aliases) | set(raw.get("aliases") or [])
                existing.aliases = self._clean_aliases(sorted(merged), source)
                if raw.get("note"):
                    existing.note = raw["note"]
                if raw.get("type"):
                    existing.type = normalize_term_type(raw["type"])
                existing.updated_at = stamp
                # 覆盖即视为定论：该 source 的未决冲突一并了结。
                for c in self._conflicts:
                    if c.source == source and not c.resolved:
                        c.resolved = True
                        c.resolution = "superseded"
                        c.resolved_by = "user"
                        c.resolved_at = stamp
                updated += 1
                continue

            candidate = GlossaryTerm(
                source=source,
                target=target,
                reading=raw.get("reading", ""),
                type=normalize_term_type(raw.get("type")),
                gender=raw.get("gender", ""),
                aliases=list(raw.get("aliases") or []),
                note=raw.get("note", ""),
                origin=origin,
                locked=lock or origin == "user",
            )
            result = self.upsert(candidate, chunk=None, phase="import")
            if result == "inserted":
                added += 1
            elif result == "unchanged":
                # 「推进」语义：target 未变时允许把 auto 词条提升为 user/locked。
                target_term = self._terms[source]
                if origin == "user" and not target_term.locked and lock:
                    target_term.origin = "user"
                    target_term.locked = True
                    target_term.updated_at = stamp
                updated += 1
            else:
                skipped += 1
        return {"added": added, "updated": updated, "skipped": skipped}


# ══════════════════════════════════════════════════════════════════════════
# 用户术语表解析（CSV 两栏/五栏自动识别 + JSON）
# ══════════════════════════════════════════════════════════════════════════

def parse_user_csv(path: str) -> list[dict[str, Any]]:
    """解析用户 CSV，**兼容两栏与五栏**，缺列用默认值填充（§4.1）。

    两栏：`日语,中文`（v3.2 格式）
    五栏：`日语,中文,类型,来源,备注`（v3.3 编辑器格式）

    表头行自动识别并跳过；空行、只有原文没有译名的行一律丢弃。
    """
    try:
        with open(path, "r", encoding="utf-8-sig", newline="") as fh:
            rows = list(csv.reader(fh))
    except OSError as exc:
        die(EXIT_INPUT, f"无法读取术语表 CSV（{exc}）：{path}")

    out: list[dict[str, Any]] = []
    for idx, row in enumerate(rows):
        cells = [(c or "").strip() for c in row]
        while cells and not cells[-1]:
            cells.pop()
        if not cells:
            continue
        if idx == 0 and _looks_like_header(cells):
            continue
        if len(cells) < 2 or not cells[0] or not cells[1]:
            continue
        item: dict[str, Any] = {"source": cells[0], "target": cells[1]}
        if len(cells) >= 3 and cells[2]:
            item["type"] = cells[2]
        if len(cells) >= 4 and cells[3]:
            item["origin_hint"] = _CN_ORIGIN.get(cells[3], cells[3]
                                                 if cells[3] in ("user", "auto") else "user")
        if len(cells) >= 5 and cells[4]:
            item["note"] = cells[4]
        out.append(item)
    return out


def _looks_like_header(cells: list[str]) -> bool:
    """首行是否为表头。用列名白名单判断，避免把真实术语当表头丢掉。"""
    first = cells[0].strip().lower()
    second = cells[1].strip().lower() if len(cells) > 1 else ""
    return first in _HEADER_FIRST or second in _HEADER_SECOND


def parse_user_json(path: str) -> list[dict[str, Any]]:
    """解析用户 JSON（`{"terms":[…]}`，字段同 §3.6）。"""
    data = read_json(path)
    if data is None:
        die(EXIT_INPUT, f"无法读取或解析术语表 JSON：{path}")
    return extract_terms_array(data, where=path)


def extract_terms_array(data: Any, where: str) -> list[dict[str, Any]]:
    """从 `{"terms":[…]}` 或裸数组中取出术语数组；非数组以 `EXIT_INPUT` 退出。"""
    if isinstance(data, dict):
        terms = data.get("terms")
    else:
        terms = data
    if terms is None:
        die(EXIT_INPUT, f"缺少 terms 字段：{where}")
    if not isinstance(terms, list):
        die(EXIT_INPUT, f"terms 必须是数组：{where}")
    out: list[dict[str, Any]] = []
    for item in terms:
        if isinstance(item, dict):
            out.append(item)
        else:
            die(EXIT_INPUT, f"terms 的元素必须是对象：{where}")
    return out


def load_terms_file(path: str) -> list[dict[str, Any]]:
    """按扩展名分派到 CSV / JSON 解析器。"""
    if path.lower().endswith(".json"):
        return parse_user_json(path)
    return parse_user_csv(path)


# ══════════════════════════════════════════════════════════════════════════
# 子命令实现
# ══════════════════════════════════════════════════════════════════════════

def cmd_init(args: argparse.Namespace) -> int:
    """§4.1 —— 初始化术语库。幂等：已存在且未给 --force 则不覆盖。"""
    state = ensure_state(args.state)
    if args.policy not in POLICIES:
        die(EXIT_USAGE, f"--policy 必须是 A/B/C/D 之一，收到：{args.policy}")

    seed: list[dict[str, Any]] = []
    if args.user_csv and args.user_json:
        die(EXIT_USAGE, "--user-csv 与 --user-json 互斥，只能给一个。")
    if args.user_csv:
        seed = parse_user_csv(args.user_csv)
    elif args.user_json:
        seed = parse_user_json(args.user_json)

    # A/B 必须有用户表且条目 ≥ 1（否则策略推导本身就是错的）。
    if args.policy in ("A", "B") and len(seed) < 1:
        die(EXIT_USAGE,
            f"情形 {args.policy} 要求提供用户术语表且解析后条目 ≥ 1，"
            f"实际解析到 {len(seed)} 条。\n  请检查 --user-csv / --user-json 是否给出且内容非空。")

    with file_lock(state, "glossary"):
        store = GlossaryStore(state)
        if store.exists() and not args.force:
            # 幂等路径：续跑时重复 init 不得清空已有术语库。
            store.load()
            stats = store.stats()
            emit_json({
                "ok": True, "created": False, "policy": store.policy,
                "terms": stats["terms"], "locked": stats["locked"],
                "auto": stats["auto"], "path": glossary_path(state),
            })
            return EXIT_OK

        store.policy = args.policy
        store._terms = {}
        store._conflicts = []
        store._next_id = 1
        store._loaded = True
        stamp = now()
        for raw in seed:
            source = (raw.get("source") or "").strip()
            target = (raw.get("target") or "").strip()
            if not source or not target:
                continue
            store._terms[source] = GlossaryTerm(
                source=source,
                target=target,
                reading=str(raw.get("reading") or ""),
                type=normalize_term_type(raw.get("type")),
                gender=str(raw.get("gender") or ""),
                aliases=GlossaryStore._clean_aliases(
                    [str(a) for a in (raw.get("aliases") or [])], source),
                note=str(raw.get("note") or ""),
                origin="user",      # init 的种子一律是用户词条
                locked=True,        # origin=user ⇒ locked=true
                status="ok",
                first_chunk=None,
                hits=0,
                created_at=stamp,
                updated_at=stamp,
            )
        store.save()
        stats = store.stats()

    append_event(state, "glossary_init", stage="S0", actor="script",
                 data={"policy": args.policy, "user_terms": len(store._terms)})
    emit_json({
        "ok": True, "created": True, "policy": args.policy,
        "terms": stats["terms"], "locked": stats["locked"],
        "auto": stats["auto"], "path": glossary_path(state),
    })
    return EXIT_OK


def cmd_upsert(args: argparse.Namespace) -> int:
    """§4.2 —— 写入术语（唯一写路径）。"""
    state = ensure_state(args.state)
    if args.phase and args.chunk is None:
        die(EXIT_USAGE, "--phase 存在时 --chunk 必填（事件需要块号才能做 F33-02 取证）。")
    if args.stdin and args.file:
        die(EXIT_USAGE, "--stdin 与 --file 互斥，只能给一个。")
    if not args.stdin and not args.file:
        die(EXIT_USAGE, "必须给出 --stdin 或 --file 之一作为术语数组来源。")

    if args.stdin:
        payload = read_stdin_json()
        source_label = "<stdin>"
    else:
        payload = read_json(args.file)
        if payload is None:
            die(EXIT_INPUT, f"无法读取或解析术语 JSON：{args.file}")
        source_label = args.file
    # {"terms": []} 空数组合法且必须支持 —— F33-02「即使无新词也要留证据」。
    incoming = extract_terms_array(payload, where=source_label)

    summary = {"inserted": 0, "unchanged": 0, "conflict": 0,
               "rejected_by_lock": 0, "rejected_by_policy": 0, "invalid": 0}
    inserted_list: list[dict[str, str]] = []
    conflict_list: list[dict[str, Any]] = []
    rejected_lock_list: list[dict[str, str]] = []

    with file_lock(state, "glossary"):
        store = GlossaryStore(state)
        store.load()
        before_ids = {c.id for c in store.conflicts()}
        for raw in incoming:
            candidate = GlossaryTerm(
                source=str(raw.get("source") or ""),
                target=str(raw.get("target") or ""),
                reading=str(raw.get("reading") or ""),
                type=normalize_term_type(raw.get("type") or args.default_type),
                gender=str(raw.get("gender") or ""),
                aliases=[str(a) for a in (raw.get("aliases") or []) if str(a).strip()],
                note=str(raw.get("note") or ""),
                origin="auto",
                locked=False,
            )
            result = store.upsert(candidate, chunk=args.chunk,
                                  phase=args.phase or "manual")
            summary[result] = summary.get(result, 0) + 1
            if result == "inserted":
                inserted_list.append({"source": candidate.source, "target": candidate.target})

        # 本次事务新产生的冲突记录，按锁定/未锁定分列到 stdout。
        for c in store.conflicts():
            if c.id in before_ids:
                continue
            if c.resolution == "rejected_by_lock":
                rejected_lock_list.append({
                    "source": c.source,
                    "locked_target": c.existing_target,
                    "proposed_target": c.proposed_target,
                })
            else:
                conflict_list.append({
                    "id": c.id, "source": c.source,
                    "existing_target": c.existing_target,
                    "proposed_target": c.proposed_target,
                })
        store.save()
        stats = store.stats()

    etype = {"pre": "glossary_pre_extract",
             "post": "glossary_post_extract"}.get(args.phase or "", "glossary_upsert")
    # 事件 data：统一用 `inserted`（与 §4.2 upsert 决策枚举一致；BUG-03 裁定删除 `added`）。
    event_data = dict(summary)
    append_event(state, etype, stage="S4", chunk=args.chunk,
                 actor="script", data=event_data)

    emit_json({
        "ok": True,
        "chunk": args.chunk,
        "phase": args.phase,
        "summary": summary,
        "inserted": inserted_list,
        "conflicts": conflict_list,
        "rejected_by_lock": rejected_lock_list,
        "totals": {"terms": stats["terms"], "locked": stats["locked"],
                   "open_conflicts": stats["open_conflicts"]},
    })
    return EXIT_OK


def _resolve_hits_text(args: argparse.Namespace, state: str) -> str:
    """取得用于匹配的文本（--chunk / --text-file / --stdin-text 三选一）。"""
    if args.chunk is not None:
        path = chunk_path(state, args.chunk)
        if not os.path.isfile(path):
            die(EXIT_STATE, f"块文件不存在：{path}\n  请先运行 split_text.py 切分。")
        return read_text(path)
    if args.text_file:
        if not os.path.isfile(args.text_file):
            die(EXIT_STATE, f"文本文件不存在：{args.text_file}")
        return read_text(args.text_file)
    if args.stdin_text:
        return sys.stdin.buffer.read().decode("utf-8-sig", errors="replace")
    if args.scope == "full":
        return ""       # scope=full 不做匹配，无需文本
    die(EXIT_USAGE, "需要 --chunk N / --text-file <path> / --stdin-text 之一作为匹配文本。")


def _hits_payload(store: GlossaryStore, args: argparse.Namespace,
                  text: str) -> tuple[list[GlossaryTerm], bool]:
    return store.hits(text, scope=args.scope, max_n=args.max)


def cmd_hits(args: argparse.Namespace) -> int:
    """§4.3 —— 命中裁剪。"""
    state = ensure_state(args.state)
    text = _resolve_hits_text(args, state)
    # 只读命令不加写锁；读到的是某一次原子替换后的完整快照。
    store = GlossaryStore(state)
    store.load()
    matched, truncated = _hits_payload(store, args, text)

    if not args.no_event:
        append_event(state, "glossary_hits", stage="S4", chunk=args.chunk,
                     actor="script", data={"count": len(matched), "scope": args.scope})

    if args.format == "md":
        sys.stdout.write(GlossaryStore.render_md(matched) + "\n")
        return EXIT_OK
    if args.format == "csv":
        buf = io.StringIO()
        writer = csv.writer(buf, lineterminator="\n")
        writer.writerow(["日语", "中文", "类型", "来源", "备注"])
        for t in matched:
            writer.writerow([t.source, t.target, t.type,
                             _ORIGIN_CN.get(t.origin, "自动"), t.note])
        sys.stdout.write(buf.getvalue())
        return EXIT_OK

    emit_json({
        "ok": True,
        "chunk": args.chunk,
        "scope": args.scope,
        "count": len(matched),
        "truncated": truncated,
        "terms": [
            {"source": t.source, "target": t.target, "type": t.type,
             "locked": t.locked, "aliases": list(t.aliases),
             "note": t.note, "status": t.status}
            for t in matched
        ],
    })
    return EXIT_OK


def cmd_render(args: argparse.Namespace) -> int:
    """§4.4 —— 渲染完整提示词块（纯文本输出）。

    `= hits --format md 的结果，前面拼上策略段`。这是 WB 与 DS 两后端注入
    术语约束的**唯一函数**，保证两后端提示词逐字相同。
    """
    state = ensure_state(args.state)
    store = GlossaryStore(state)
    store.load()

    if args.chunk is not None:
        path = chunk_path(state, args.chunk)
        if not os.path.isfile(path):
            die(EXIT_STATE, f"块文件不存在：{path}\n  请先运行 split_text.py 切分。")
        text = read_text(path)
    else:
        text = ""
        if args.scope != "full":
            # 无 --chunk 又非 full：退化为全表渲染，避免静默输出空块。
            args.scope = "full"

    matched, _ = store.hits(text, scope=args.scope, max_n=args.max)
    block = GlossaryStore.render_md(matched)

    if args.policy is not None and args.policy is not True and args.policy not in POLICIES:
        # BUG-01：显式给了非法策略值（如 Z / 小写 b）→ 立即报错，绝不静默回落库内策略。
        die(EXIT_USAGE, f"未知策略：{args.policy}（应为 A/B/C/D）")
    # 未提供 `--policy` 时只输出命中块；显式 `--policy` 才拼接策略段。
    if args.policy is None:
        sys.stdout.write(block + "\n")
        return EXIT_OK
    # `--policy` 不带值（const=True）→ 用库里存的策略；带合法值 → 用指定策略。
    policy = store.policy if args.policy is True else args.policy
    prompt = POLICY_PROMPTS.get(policy)
    if prompt is None:
        die(EXIT_USAGE, f"未知策略：{policy}（应为 A/B/C/D）")
    sys.stdout.write(prompt + "\n\n" + block + "\n")
    return EXIT_OK


def cmd_conflicts(args: argparse.Namespace) -> int:
    """§4.5 —— 冲突查询。`--fail-if-open` 且有未决冲突时退 5。"""
    state = ensure_state(args.state)
    store = GlossaryStore(state)
    store.load()

    all_conflicts = store.conflicts()
    open_list = [c for c in all_conflicts if not c.resolved]
    items = all_conflicts if args.all else open_list
    if args.source:
        items = [c for c in items if c.source == args.source]

    if args.format == "md":
        if not items:
            sys.stdout.write("【术语冲突】（无）\n")
        else:
            lines = ["【术语冲突】"]
            for c in items:
                mark = "已裁决" if c.resolved else "待裁决"
                extra = f"（{c.resolution}）" if c.resolution else ""
                chunk = f"第 {c.chunk} 块" if c.chunk is not None else "—"
                lines.append(
                    f"- #{c.id} {c.source}：现值「{c.existing_target}」 vs 候选「{c.proposed_target}」"
                    f" · {chunk} · {c.phase} · {mark}{extra}"
                )
            sys.stdout.write("\n".join(lines) + "\n")
    else:
        emit_json({
            "ok": True,
            "open": len(open_list),
            "total": len(all_conflicts),
            "items": [
                {"id": c.id, "source": c.source,
                 "existing_target": c.existing_target,
                 "proposed_target": c.proposed_target,
                 "chunk": c.chunk, "phase": c.phase,
                 "resolved": c.resolved, "resolution": c.resolution,
                 "created_at": round(c.created_at, 3)}
                for c in items
            ],
        })

    if args.fail_if_open and open_list:
        # 业务检查未通过 —— 这是 S7 自检的预期用法，退 5 而非 0。
        sys.stderr.write(f"存在 {len(open_list)} 条未决术语冲突，请先裁决。\n")
        return EXIT_CHECK
    return EXIT_OK


def cmd_resolve(args: argparse.Namespace) -> int:
    """§4.6 —— 冲突裁决（F33-16）。"""
    state = ensure_state(args.state)
    if not args.target and not args.take:
        die(EXIT_USAGE, "必须给出 --target <t> 或 --take {existing|proposed} 之一。")
    if args.target and args.take:
        die(EXIT_USAGE, "--target 与 --take 互斥，只能给一个。")

    with file_lock(state, "glossary"):
        store = GlossaryStore(state)
        store.load()
        term = store.get(args.source)
        if term is None:
            die(EXIT_STATE, f"术语不存在，无法裁决：{args.source}\n  请确认 source 与库中完全一致（区分空格与全半角）。")

        if args.target:
            final = args.target
        elif args.take == "existing":
            final = term.target
        else:   # proposed
            candidates = [c for c in store.conflicts()
                          if c.source == args.source and not c.resolved]
            if args.conflict_id is not None:
                picked = next((c for c in store.conflicts() if c.id == args.conflict_id), None)
                if picked is None:
                    die(EXIT_STATE, f"冲突记录不存在：id={args.conflict_id}")
                if picked.source != args.source:
                    die(EXIT_USAGE,
                        f"冲突 #{args.conflict_id} 属于 source「{picked.source}」，"
                        f"与 --source「{args.source}」不符。")
                final = picked.proposed_target
            else:
                if not candidates:
                    die(EXIT_STATE, f"该术语没有未决冲突，无法 --take proposed：{args.source}")
                # 缺省取该 source **最新**的未决冲突。
                final = max(candidates, key=lambda c: (c.created_at, c.id)).proposed_target

        result = store.resolve(args.source, final, lock=args.lock, by=args.by)
        store.save()

    append_event(state, "glossary_resolved", stage=None, actor="script",
                 data={"source": args.source, "target": final, "by": args.by})
    emit_json(result)
    return EXIT_OK


def cmd_export(args: argparse.Namespace) -> int:
    """§4.7 —— 导出。"""
    state = ensure_state(args.state)
    store = GlossaryStore(state)
    store.load()
    rows = store.export(args.out, args.format, args.origin, args.only_ok)
    emit_json({"ok": True, "out": os.path.abspath(args.out),
               "format": args.format, "rows": rows})
    return EXIT_OK


def cmd_import(args: argparse.Namespace) -> int:
    """§4.8 —— 导入外部术语。"""
    state = ensure_state(args.state)
    if not os.path.isfile(args.file):
        die(EXIT_STATE, f"待导入文件不存在：{args.file}")
    if args.overwrite and args.origin != "user":
        die(EXIT_USAGE, "--overwrite 仅在 --origin user 时允许（避免自动流程静默改写用户译名）。")

    with file_lock(state, "glossary"):
        store = GlossaryStore(state)
        store.load()
        result = store.import_(args.file, args.origin, args.lock, args.overwrite)
        store.save()

    append_event(state, "glossary_imported", stage=None, actor="script",
                 data={"added": result["added"], "updated": result["updated"],
                       "origin": args.origin})
    emit_json({"ok": True, **result, "origin": args.origin})
    return EXIT_OK


def cmd_stats(args: argparse.Namespace) -> int:
    """§4.9 —— 统计。"""
    state = ensure_state(args.state)
    store = GlossaryStore(state)
    store.load()
    stats = store.stats()
    if args.format == "md":
        lines = [
            "【术语库统计】",
            f"- 策略：{stats['policy']}",
            f"- 总条数：{stats['terms']}（锁定 {stats['locked']} · 自动 {stats['auto']}）",
            f"- 未决冲突：{stats['open_conflicts']}",
        ]
        if stats["by_type"]:
            detail = "、".join(f"{k} {v}" for k, v in sorted(stats["by_type"].items()))
            lines.append(f"- 分类型：{detail}")
        sys.stdout.write("\n".join(lines) + "\n")
    else:
        emit_json(stats)
    return EXIT_OK


# ══════════════════════════════════════════════════════════════════════════
# CLI
# ══════════════════════════════════════════════════════════════════════════

def build_parser() -> argparse.ArgumentParser:
    ap = make_parser(
        prog="glossary_tool.py",
        description="术语库唯一写入口（v3.3）。所有子命令都必须给 --state。",
    )
    sub = ap.add_subparsers(dest="cmd", required=True, parser_class=UsageErrorParser)

    def with_state(p: argparse.ArgumentParser) -> argparse.ArgumentParser:
        p.add_argument("--state", required=True, help="<outDir>/state 目录")
        return p

    p_init = with_state(sub.add_parser("init", help="初始化术语库（幂等）"))
    p_init.add_argument("--policy", required=True, choices=list(POLICIES))
    p_init.add_argument("--user-csv", default=None, help="用户术语表 CSV（两栏或五栏）")
    p_init.add_argument("--user-json", default=None, help="用户术语表 JSON")
    p_init.add_argument("--force", action="store_true", help="已存在时强制重建")
    p_init.set_defaults(func=cmd_init)

    p_up = with_state(sub.add_parser("upsert", help="写入术语（唯一写路径）"))
    p_up.add_argument("--chunk", type=int, default=None)
    p_up.add_argument("--phase", choices=["pre", "post"], default=None)
    p_up.add_argument("--stdin", action="store_true")
    p_up.add_argument("--file", default=None)
    p_up.add_argument("--default-type", default=DEFAULT_TERM_TYPE)
    p_up.set_defaults(func=cmd_upsert)

    p_hit = with_state(sub.add_parser("hits", help="命中裁剪"))
    p_hit.add_argument("--chunk", type=int, default=None)
    p_hit.add_argument("--text-file", default=None)
    p_hit.add_argument("--stdin-text", action="store_true")
    p_hit.add_argument("--scope", choices=["chunk", "full"], default="chunk")
    p_hit.add_argument("--format", choices=["json", "md", "csv"], default="json")
    p_hit.add_argument("--max", type=int, default=400)
    p_hit.add_argument("--no-event", action="store_true")
    p_hit.set_defaults(func=cmd_hits)

    p_ren = with_state(sub.add_parser("render", help="渲染完整提示词块（纯文本）"))
    p_ren.add_argument("--chunk", type=int, default=None)
    p_ren.add_argument("--scope", choices=["chunk", "full"], default="chunk")
    # nargs="?"：`--policy` 用库里的策略，`--policy B` 强制指定（跨端 diff 验收用）。
    p_ren.add_argument("--policy", nargs="?", const=True, default=None)
    p_ren.add_argument("--max", type=int, default=400)
    p_ren.set_defaults(func=cmd_render)

    p_cf = with_state(sub.add_parser("conflicts", help="冲突查询"))
    g_cf = p_cf.add_mutually_exclusive_group()
    g_cf.add_argument("--open", action="store_true", help="只看未决（默认）")
    g_cf.add_argument("--all", action="store_true", help="含已裁决")
    p_cf.add_argument("--source", default=None)
    p_cf.add_argument("--format", choices=["json", "md"], default="json")
    p_cf.add_argument("--fail-if-open", action="store_true", help="有未决冲突时退 5")
    p_cf.set_defaults(func=cmd_conflicts)

    p_rs = with_state(sub.add_parser("resolve", help="冲突裁决"))
    p_rs.add_argument("--source", required=True)
    p_rs.add_argument("--target", default=None)
    p_rs.add_argument("--take", choices=["existing", "proposed"], default=None)
    p_rs.add_argument("--conflict-id", type=int, default=None)
    p_rs.add_argument("--lock", action="store_true")
    p_rs.add_argument("--by", choices=["user", "agent"], default="user")
    p_rs.set_defaults(func=cmd_resolve)

    p_ex = with_state(sub.add_parser("export", help="导出术语表"))
    p_ex.add_argument("--out", required=True)
    p_ex.add_argument("--format", choices=["csv2", "csv5", "json"], default="csv5")
    p_ex.add_argument("--origin", choices=["all", "auto", "user"], default="all")
    p_ex.add_argument("--only-ok", action="store_true")
    p_ex.set_defaults(func=cmd_export)

    p_im = with_state(sub.add_parser("import", help="导入外部术语"))
    p_im.add_argument("--file", required=True)
    p_im.add_argument("--origin", choices=["user", "auto"], default="user")
    p_im.add_argument("--lock", action="store_true")
    p_im.add_argument("--overwrite", action="store_true")
    p_im.set_defaults(func=cmd_import)

    p_st = with_state(sub.add_parser("stats", help="统计"))
    p_st.add_argument("--format", choices=["json", "md"], default="json")
    p_st.set_defaults(func=cmd_stats)

    return ap


def main(argv: list[str] | None = None) -> int:
    install_excepthook("glossary_tool.py")
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
