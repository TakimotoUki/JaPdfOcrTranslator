#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""state_tool.py — `state/` 状态目录管理器

契约出处：DESIGN-v3.3 §3.2（config.json）、§3.3（status.json）、
§3.4（events.jsonl 与 F33-02 验收算法）、§4.10（CLI 表）。

本脚本是 `config.json` / `status.json` / `events.jsonl` 的**唯一写者**（与
`glossary_tool.py` 对 `glossary*.json` 的独占写权限对称，见决策 D2）。
Swift 侧只读 `status.json` 做 UI 轮询，只读 `config.json` 做续跑判定。

八个子命令（§4.10）：
    init        初始化 / 续跑判定（写 config.json + status.json 骨架）
    set-stage   阶段切换（stage_started / stage_finished / stage_skipped）
    mark-chunk  块状态标记（chunk_translated / chunk_skipped / chunk_failed）
    pending     待处理块号列表
    status      读取 / 刷新 / 收尾 status.json
    event       追加任意事件（Agent 手工补事件用）
    verify      合规校验（F33-02 的唯一验收实现），不通过退 5
    reset       归档并重建 state 目录

退出码（§4.0，全脚本统一）：0 成功 / 1 用法错 / 2 IO 或锁错 /
3 输入 JSON 畸形 / 4 未初始化或哈希不一致 / 5 检查未通过。
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import time
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    EXIT_CHECK, EXIT_IO, EXIT_OK, EXIT_STATE, EXIT_USAGE, SCHEMA_VERSION,
    SKILL_VERSION, append_event, chunk_path, config_path, die, emit_json,
    ensure_state, ensure_state_writable, file_lock, install_excepthook,
    load_json_arg, now, parse_kv_pairs, read_events, read_json, read_text,
    sha256_file, sha256_obj, status_path, write_json_atomic,
    make_parser,
    UsageErrorParser,)

APP_VERSION = "3.3.1"

#: 九阶段中文名。**必须与 Swift `PipelineStage.displayName` 逐字一致**
#: （§3.3 `stage_name` 是同一份文案的两处实现，T04 会做交叉核对）。
STAGE_NAMES: dict[str, str] = {
    "S0": "初始化",
    "S1": "切分与结构分析",
    "S2": "全书预扫",
    "S3": "样本分析与风格定调",
    "S4": "逐块翻译",
    "S5": "跨块边界修复",
    "S6": "确定性质检",
    "S7": "一致性 QA",
    "S8": "合并与交付",
}

STAGE_IDS: tuple[str, ...] = tuple(STAGE_NAMES.keys())
STAGE_TOTAL = len(STAGE_IDS)          # 恒为 9

#: 每阶段完成后必须存在的产物，路径相对 `<state>/`。
#: **必须与 Swift `PipelineStage.requiredArtifacts` 逐项一致**。
#: 以 `/` 结尾表示「目录必须存在且非空」。
STAGE_ARTIFACTS: dict[str, tuple[str, ...]] = {
    "S0": ("config.json", "status.json"),
    "S1": ("structure.json", "manifest.json", "chunks/"),
    "S2": ("book_synopsis.md",),
    "S3": ("samples/sample_pack.md", "style_guide.md"),
    "S4": ("chunks/", "glossary.json"),
    "S5": ("boundary_report.json",),
    "S6": ("alignment_report.json",),
    "S7": ("qa_issues.json",),
    "S8": ("translation_full.txt", "original_full.txt", "report.md"),
}

CHUNK_VALUES = ("pending", "running", "done", "failed", "skipped")

#: 触发 `prescan_mode="sampled"` 的块数阈值（§3.2）。
PRESCAN_SAMPLED_THRESHOLD = 60
#: `sampled` 模式下均匀抽取的块数（§3.2）。
PRESCAN_SAMPLE_COUNT = 30
#: 触发 `path_mode="simple"` 的块数上限（§3.2）。
SIMPLE_PATH_MAX_CHUNKS = 2

#: `params` 各字段默认值（§3.2 子表）。
#: **仅用于派生逻辑**（path_mode / stages 等），
#: 绝不回填进 `params` 本体 —— `params_sha256` 必须对 Swift 传入的原始对象
#: 计算，任何补默认值的行为都会让两侧哈希永久不等、续跑永远失败。
PARAM_DEFAULTS: dict[str, Any] = {
    "glossary_policy": "C",
    "auto_glossary_enabled": True,
    "glossary_scope": "chunk",
    "pre_extract_mode": "always",
    "pre_extract_first_n": 10,
    "enable_prescan": True,
    "enable_style_analysis": True,
    "enable_punct_normalize": True,
    "enable_qa": True,
    "enable_polish": False,
    "enable_resume": True,
    "max_chars_per_chunk": 4000,
    "max_chars_per_paragraph": 8000,
    "bilingual": True,
    "user_glossary_sha256": "",
}


# ══════════════════════════════════════════════════════════════════════════
# 派生规则（§3.2）
# ══════════════════════════════════════════════════════════════════════════

def param(params: dict[str, Any], key: str) -> Any:
    """取 `params[key]`，缺失时回落到 §3.2 的默认值（不写回原对象）。"""
    value = params.get(key, PARAM_DEFAULTS.get(key))
    return PARAM_DEFAULTS.get(key) if value is None else value


def derive_path_mode(total_chunks: int) -> str:
    """≤2 块走 `simple`（跳 S2，S3 并入 S4）；块数未知（0）按 `full` 处理。"""
    if 0 < total_chunks <= SIMPLE_PATH_MAX_CHUNKS:
        return "simple"
    return "full"


def derive_prescan(params: dict[str, Any], total_chunks: int,
                   path_mode: str) -> tuple[str, list[int]]:
    """返回 `(prescan_mode, prescan_sample_indices)`。

    - `enable_prescan=false` 或 `path_mode=simple` → `off`；
    - 块数 >60 → `sampled`，均匀抽 30 块；
    - 其余 → `full`。
    """
    if not param(params, "enable_prescan") or path_mode == "simple":
        return "off", []
    if total_chunks > PRESCAN_SAMPLED_THRESHOLD:
        return "sampled", uniform_sample(total_chunks, PRESCAN_SAMPLE_COUNT)
    return "full", []


def uniform_sample(total: int, count: int) -> list[int]:
    """在 `1..total` 上均匀取 `count` 个块号（含首尾，升序去重）。

    用 `round(k*(total-1)/(count-1))` 而不是等距切片，保证首块与末块必被选中
    —— 预扫要能看到开头的人物登场与结尾的收束，两端最不能丢。
    """
    if total <= 0:
        return []
    if total <= count:
        return list(range(1, total + 1))
    step = (total - 1) / (count - 1)
    picked = {1 + int(round(k * step)) for k in range(count)}
    return sorted(n for n in picked if 1 <= n <= total)


def derive_stages(params: dict[str, Any], total_chunks: int, path_mode: str,
                  prescan_mode: str) -> list[str]:
    """推导本次实际要执行的阶段号数组（§3.2 `stages`）。

    S0/S1/S4/S8 是骨架阶段，任何配置下都不得跳过（与 Swift
    `PipelineStage.isSkippable` 的判断一致）。
    """
    stages = ["S0", "S1"]
    if prescan_mode != "off":
        stages.append("S2")
    if param(params, "enable_style_analysis") and path_mode != "simple":
        stages.append("S3")
    stages.append("S4")
    if total_chunks != 1:                     # 单块无跨块边界可修
        stages.append("S5")
    # S6 恒定执行：其中的 check_alignment 是 F33-12 的硬性验收项，
    # `enable_punct_normalize=false` 只关闭 S6 内部的 normalize_punct 子步。
    stages.append("S6")
    if param(params, "enable_qa"):
        stages.append("S7")
    stages.append("S8")
    return stages


def stage_index_of(stage: str) -> int:
    """`"S4"` → 4；未知阶段号以 `EXIT_USAGE` 退出。"""
    if stage not in STAGE_NAMES:
        die(EXIT_USAGE, f"未知阶段号：{stage}（合法值：{', '.join(STAGE_IDS)}）")
    return STAGE_IDS.index(stage)


# ══════════════════════════════════════════════════════════════════════════
# StateStore
# ══════════════════════════════════════════════════════════════════════════

class StateStore:
    """`state/` 目录的读写门面（DESIGN §5.2 类图）。

    所有对 `status.json` 的读-改-写都在 `.locks/state.lock` 内完成；
    `_common.file_lock` 是进程内可重入的，因此在同一临界区里调用
    `append_event()` 不会自我死锁。
    """

    def __init__(self, state_dir: str):
        self.state_dir: str = os.path.abspath(state_dir)

    # ── 基础读写 ──────────────────────────────────────────────────────
    def config(self, required: bool = True) -> dict[str, Any]:
        cfg = read_json(config_path(self.state_dir), None)
        if not isinstance(cfg, dict):
            if required:
                die(EXIT_STATE, f"config.json 缺失或畸形：{config_path(self.state_dir)}\n"
                                f"  请先运行 state_tool.py init。")
            return {}
        version = cfg.get("schema_version", 0)
        if isinstance(version, int) and version > SCHEMA_VERSION:
            die(EXIT_STATE, f"config.json 的 schema_version={version} 高于本 skill 支持的 "
                            f"{SCHEMA_VERSION}，请升级应用后重试。")
        return cfg

    def _read_status(self) -> dict[str, Any]:
        st = read_json(status_path(self.state_dir), None)
        if not isinstance(st, dict):
            return self._blank_status()
        return st

    def _write_status(self, d: dict[str, Any]) -> None:
        """重算派生计数后覆盖写 `status.json`（高频写，原子替换）。"""
        chunk_status: dict[str, str] = d.get("chunk_status") or {}
        done = sum(1 for v in chunk_status.values() if v in ("done", "skipped"))
        d["chunks_done"] = done
        d["chunks_failed"] = sum(1 for v in chunk_status.values() if v == "failed")
        d["chunks_skipped"] = sum(1 for v in chunk_status.values() if v == "skipped")
        d["schema_version"] = SCHEMA_VERSION
        d["stage_total"] = STAGE_TOTAL
        d["updated_at"] = round(now(), 3)
        write_json_atomic(status_path(self.state_dir), d)

    @staticmethod
    def _blank_status() -> dict[str, Any]:
        """§3.3 的完整骨架。所有字段都显式给出，UI 侧不必做 nil 兜底。"""
        return {
            "schema_version": SCHEMA_VERSION,
            "updated_at": round(now(), 3),
            "stage": "S0",
            "stage_index": 0,
            "stage_total": STAGE_TOTAL,
            "stage_name": STAGE_NAMES["S0"],
            "chunks_total": 0,
            "chunks_done": 0,
            "chunks_failed": 0,
            "chunks_skipped": 0,
            "current_chunk": None,
            "glossary_terms": 0,
            "glossary_locked": 0,
            "glossary_conflicts_open": 0,
            "qa_issues": 0,
            "alignment_issues": 0,
            "finished": False,
            "failed": False,
            "compliant": None,
            "message": "已初始化",
            "chunk_status": {},
            "artifacts": {"zh_pdf": "", "ja_pdf": "", "bi_pdf": "",
                          "report": "", "glossary_csv": ""},
        }

    # ── init（§4.10）──────────────────────────────────────────────────
    def init_run(self, input_path: str, backend: str, params: dict[str, Any],
                 force: bool) -> tuple[dict[str, Any], int]:
        """初始化或做续跑判定，返回 `(stdout_payload, exit_code)`。"""
        if backend not in ("workbuddy", "deepseek"):
            die(EXIT_USAGE, f"--backend 只能是 workbuddy 或 deepseek，收到：{backend}")
        abs_input = os.path.abspath(input_path)
        if not os.path.isfile(abs_input):
            die(EXIT_STATE, f"输入文件不存在：{abs_input}")

        ensure_state_writable(self.state_dir)
        for sub in ("chunks", "digests", "samples", ".locks"):
            os.makedirs(os.path.join(self.state_dir, sub), exist_ok=True)

        input_sha = sha256_file(abs_input)
        params_sha = sha256_obj(params)

        existing = read_json(config_path(self.state_dir), None)
        if isinstance(existing, dict) and not force:
            return self._resume_or_reject(existing, input_sha, params_sha, params)

        total_chunks = 0
        if isinstance(existing, dict) and force:
            # 强制重建时保留已知块数，让 path_mode/stages 不至于退回未知态。
            raw_total = existing.get("total_chunks", 0)
            total_chunks = raw_total if isinstance(raw_total, int) and raw_total > 0 else 0

        path_mode = derive_path_mode(total_chunks)
        prescan_mode, sample_indices = derive_prescan(params, total_chunks, path_mode)
        stages = derive_stages(params, total_chunks, path_mode, prescan_mode)
        stamp = round(now(), 3)

        cfg = {
            "schema_version": SCHEMA_VERSION,
            "created_at": stamp,
            "updated_at": stamp,
            "app_version": APP_VERSION,
            "skill_version": SKILL_VERSION,          # B2 版本印记
            "backend": backend,
            "input_path": abs_input,
            "input_sha256": input_sha,
            "params_sha256": params_sha,
            "params": params,                         # 原样保存，勿补默认值
            "total_chunks": total_chunks,
            "path_mode": path_mode,
            "prescan_mode": prescan_mode,
            "prescan_sample_indices": sample_indices,
            "stages": stages,
        }

        with file_lock(self.state_dir, "state"):
            write_json_atomic(config_path(self.state_dir), cfg)
            status = self._read_status() if force else self._blank_status()
            status["chunks_total"] = total_chunks
            status["stage"] = "S0"
            status["stage_index"] = 0
            status["stage_name"] = STAGE_NAMES["S0"]
            status["finished"] = False
            status["failed"] = False
            status["message"] = "已初始化，等待切分"
            if not force:
                status["chunk_status"] = {}
            self._write_status(status)

        append_event(self.state_dir, "run_init", stage="S0", actor="script", data={
            "input_sha256": input_sha,
            "params_sha256": params_sha,
            "path_mode": path_mode,
            "prescan_mode": prescan_mode,
            "backend": backend,
        })

        pending = self.pending()
        return ({
            "ok": True,
            "created": True,
            "resumable": False,
            "reason": "initialized",
            "state": self.state_dir,
            "backend": backend,
            "skill_version": SKILL_VERSION,
            "input_sha256": input_sha,
            "params_sha256": params_sha,
            "total_chunks": total_chunks,
            "path_mode": path_mode,
            "prescan_mode": prescan_mode,
            "prescan_sample_indices": sample_indices,
            "stages": stages,
            "done": 0,
            "pending": len(pending),
        }, EXIT_OK)

    def _resume_or_reject(self, cfg: dict[str, Any], input_sha: str,
                          params_sha: str,
                          params: dict[str, Any]) -> tuple[dict[str, Any], int]:
        """§3.2 续跑判定五连乘。任一不满足 → 退 4 并给出机器可读 `reason`。"""
        status = self._read_status()
        reason = ""
        if not param(params, "enable_resume"):
            reason = "resume_disabled"
        elif cfg.get("schema_version") != SCHEMA_VERSION:
            reason = "schema_mismatch"
        elif cfg.get("input_sha256") != input_sha:
            reason = "input_changed"
        elif cfg.get("params_sha256") != params_sha:
            reason = "params_changed"
        elif bool(status.get("finished")):
            reason = "finished"

        if reason:
            return ({
                "ok": False,
                "created": False,
                "resumable": False,
                "reason": reason,
                "state": self.state_dir,
            }, EXIT_STATE)

        pending = self.pending()
        total = int(cfg.get("total_chunks") or status.get("chunks_total") or 0)
        done = max(total - len(pending), 0) if total else int(status.get("chunks_done") or 0)

        append_event(self.state_dir, "run_resume", stage="S0", actor="script",
                     data={"done": done, "pending": len(pending)})
        return ({
            "ok": True,
            "created": False,
            "resumable": True,
            "done": done,
            "pending": len(pending),
            "pending_chunks": pending,
            "state": self.state_dir,
            "total_chunks": total,
            "path_mode": cfg.get("path_mode", "full"),
            "prescan_mode": cfg.get("prescan_mode", "full"),
            "stages": cfg.get("stages", list(STAGE_IDS)),
        }, EXIT_OK)

    # ── S1 回填（§3.2「total_chunks：S1 后回填」）──────────────────────
    def backfill_split(self, total_chunks: int) -> dict[str, Any]:
        """S1 结束后用真实块数重算 `total_chunks` / `path_mode` / `stages`。

        `init` 时块数尚未可知（`total_chunks=0`），而 `path_mode` 与
        `prescan_mode` 都由块数决定，所以必须在切分完成后回填一次。
        `split_text.py` 与 `set-stage --stage S1 --finish` 都会调用本方法，
        重复调用是幂等的。
        """
        cfg = self.config(required=False)
        if not cfg:
            return {"updated": False, "reason": "no_config"}
        params = cfg.get("params") or {}
        path_mode = derive_path_mode(total_chunks)
        prescan_mode, sample_indices = derive_prescan(params, total_chunks, path_mode)
        stages = derive_stages(params, total_chunks, path_mode, prescan_mode)

        with file_lock(self.state_dir, "state"):
            cfg["total_chunks"] = total_chunks
            cfg["path_mode"] = path_mode
            cfg["prescan_mode"] = prescan_mode
            cfg["prescan_sample_indices"] = sample_indices
            cfg["stages"] = stages
            cfg["updated_at"] = round(now(), 3)
            write_json_atomic(config_path(self.state_dir), cfg)

            status = self._read_status()
            status["chunks_total"] = total_chunks
            self._write_status(status)

        return {
            "updated": True,
            "total_chunks": total_chunks,
            "path_mode": path_mode,
            "prescan_mode": prescan_mode,
            "prescan_sample_indices": sample_indices,
            "stages": stages,
        }

    # ── set-stage（§4.10）─────────────────────────────────────────────
    def set_stage(self, stage: str, name: str | None, finish: bool,
                  skip: bool, reason: str) -> dict[str, Any]:
        if finish and skip:
            die(EXIT_USAGE, "--finish 与 --skip 互斥，不能同时给出。")
        index = stage_index_of(stage)
        label = name or STAGE_NAMES[stage]

        if stage == "S1" and finish:
            structure = read_json(os.path.join(self.state_dir, "structure.json"), None)
            if isinstance(structure, dict):
                count = structure.get("chunk_count")
                if isinstance(count, int) and count > 0:
                    self.backfill_split(count)

        artifacts_present: list[str] = []
        if finish:
            artifacts_present = [rel for rel in STAGE_ARTIFACTS.get(stage, ())
                                 if self._artifact_exists(rel)]

        with file_lock(self.state_dir, "state"):
            status = self._read_status()
            status["stage"] = stage
            status["stage_index"] = index
            status["stage_name"] = label
            if skip:
                status["message"] = f"阶段 {index + 1}/{STAGE_TOTAL} · {label} 已跳过（{reason or '未说明'}）"
            elif finish:
                status["message"] = f"阶段 {index + 1}/{STAGE_TOTAL} · {label} 已完成"
            else:
                status["message"] = f"阶段 {index + 1}/{STAGE_TOTAL} · {label} 进行中"
                status["current_chunk"] = None
            self._write_status(status)

        if skip:
            append_event(self.state_dir, "stage_skipped", stage=stage, actor="script",
                         data={"stage": stage, "reason": reason or "unspecified"})
        elif finish:
            append_event(self.state_dir, "stage_finished", stage=stage, actor="script",
                         data={"stage": stage, "name": label, "artifacts": artifacts_present})
        else:
            append_event(self.state_dir, "stage_started", stage=stage, actor="script",
                         data={"stage": stage, "name": label})

        missing = [rel for rel in STAGE_ARTIFACTS.get(stage, ())
                   if finish and not self._artifact_exists(rel)]
        return {
            "ok": True,
            "stage": stage,
            "stage_index": index,
            "stage_name": label,
            "event": "stage_skipped" if skip else ("stage_finished" if finish else "stage_started"),
            "artifacts": artifacts_present,
            "missing_artifacts": missing,
        }

    def _artifact_exists(self, rel: str) -> bool:
        """`rel` 以 `/` 结尾表示目录必须存在且非空。"""
        path = os.path.join(self.state_dir, rel.rstrip("/"))
        if rel.endswith("/"):
            return os.path.isdir(path) and bool(os.listdir(path))
        return os.path.isfile(path)

    # ── mark-chunk（§4.10）────────────────────────────────────────────
    def mark_chunk(self, n: int, value: str, zh_chars: int | None,
                   error: str, reason: str) -> dict[str, Any]:
        if value not in CHUNK_VALUES:
            die(EXIT_USAGE, f"--value 只能是 {'|'.join(CHUNK_VALUES)}，收到：{value}")
        if n < 1:
            die(EXIT_USAGE, f"--chunk 必须 ≥1，收到：{n}")

        src_chars = self._chars_of(chunk_path(self.state_dir, n, zh=False))
        if zh_chars is None:
            zh_chars = self._chars_of(chunk_path(self.state_dir, n, zh=True))

        with file_lock(self.state_dir, "state"):
            status = self._read_status()
            chunk_status: dict[str, str] = status.get("chunk_status") or {}
            chunk_status[str(n)] = value
            status["chunk_status"] = chunk_status
            status["current_chunk"] = n if value == "running" else None
            total = int(status.get("chunks_total") or 0)
            done = sum(1 for v in chunk_status.values() if v in ("done", "skipped"))
            if value == "running":
                status["message"] = f"正在翻译第 {n}/{total or '?'} 块"
            elif value == "failed":
                status["message"] = f"第 {n} 块失败：{error or '未知错误'}"
            else:
                status["message"] = f"已完成 {done}/{total or '?'} 块"
            self._write_status(status)

        if value == "done":
            append_event(self.state_dir, "chunk_translated", stage="S4", chunk=n,
                         actor="script", data={"src_chars": src_chars, "zh_chars": zh_chars})
        elif value == "skipped":
            append_event(self.state_dir, "chunk_skipped", stage="S4", chunk=n,
                         actor="script", data={"reason": reason or "resume"})
        elif value == "failed":
            append_event(self.state_dir, "chunk_failed", stage="S4", chunk=n,
                         actor="script", data={"error": error or "unknown"})

        return {"ok": True, "chunk": n, "value": value,
                "src_chars": src_chars, "zh_chars": zh_chars}

    @staticmethod
    def _chars_of(path: str) -> int:
        if not os.path.isfile(path):
            return 0
        return len(read_text(path))

    # ── pending（§4.10）───────────────────────────────────────────────
    def pending(self) -> list[int]:
        """返回尚未 `done`/`skipped` 的块号升序列表。"""
        cfg = self.config(required=False)
        status = self._read_status()
        total = int(cfg.get("total_chunks") or status.get("chunks_total") or 0)
        if total <= 0:
            return []
        chunk_status: dict[str, str] = status.get("chunk_status") or {}
        return [n for n in range(1, total + 1)
                if chunk_status.get(str(n)) not in ("done", "skipped")]

    # ── status（§4.10）────────────────────────────────────────────────
    def refresh_status(self, message: str) -> dict[str, Any]:
        """回填术语 / QA / 对齐三组指标。

        术语数走 `GlossaryStore.stats()` 而不是自己解析 `glossary.json`，
        保证「唯一事实标准」不被复制一份（决策 D2）。
        """
        terms = locked = open_conflicts = 0
        try:
            from glossary_tool import GlossaryStore    # 同目录脚本，零第三方依赖
            store = GlossaryStore(self.state_dir)
            if store.exists():
                store.load(required=False)
                gstats = store.stats()
                terms = int(gstats.get("terms", 0))
                locked = int(gstats.get("locked", 0))
                open_conflicts = int(gstats.get("open_conflicts", 0))
        except ImportError:
            pass                                        # 术语库尚未建立，保持 0

        qa = read_json(os.path.join(self.state_dir, "qa_issues.json"), None)
        qa_issues = 0
        if isinstance(qa, dict):
            summary = qa.get("summary") or {}
            qa_issues = int(summary.get("total", 0) or 0)

        alignment = read_json(os.path.join(self.state_dir, "alignment_report.json"), None)
        alignment_issues = 0
        if isinstance(alignment, dict):
            summary = alignment.get("summary") or {}
            alignment_issues = int(summary.get("error", 0) or 0)

        with file_lock(self.state_dir, "state"):
            status = self._read_status()
            status["glossary_terms"] = terms
            status["glossary_locked"] = locked
            status["glossary_conflicts_open"] = open_conflicts
            status["qa_issues"] = qa_issues
            status["alignment_issues"] = alignment_issues
            status["artifacts"] = self._scan_artifacts(status.get("artifacts") or {})
            if message:
                status["message"] = message
            self._write_status(status)
            return status

    def _scan_artifacts(self, current: dict[str, Any]) -> dict[str, str]:
        """扫描 state 根与父目录，回填已产出的交付物绝对路径。"""
        out = {"zh_pdf": "", "ja_pdf": "", "bi_pdf": "", "report": "", "glossary_csv": ""}
        for key in out:
            value = current.get(key)
            if isinstance(value, str) and value and os.path.exists(value):
                out[key] = value
        report = os.path.join(self.state_dir, "report.md")
        if not out["report"] and os.path.isfile(report):
            out["report"] = report
        csv_path = os.path.join(self.state_dir, "glossary_export.csv")
        if not out["glossary_csv"] and os.path.isfile(csv_path):
            out["glossary_csv"] = csv_path
        out_dir = os.path.dirname(self.state_dir)
        if os.path.isdir(out_dir):
            for name in sorted(os.listdir(out_dir)):
                if not name.lower().endswith(".pdf"):
                    continue
                full = os.path.join(out_dir, name)
                stem = name[:-4]
                if stem.endswith("_zh") and not out["zh_pdf"]:
                    out["zh_pdf"] = full
                elif stem.endswith("_ja") and not out["ja_pdf"]:
                    out["ja_pdf"] = full
                elif stem.endswith("_bi") and not out["bi_pdf"]:
                    out["bi_pdf"] = full
        return out

    def finish_run(self, message: str) -> dict[str, Any]:
        status = self.refresh_status(message or "全部完成")
        with file_lock(self.state_dir, "state"):
            status = self._read_status()
            status["finished"] = True
            status["failed"] = False
            status["current_chunk"] = None
            if message:
                status["message"] = message
            self._write_status(status)
        append_event(self.state_dir, "run_finished", stage="S8", actor="script",
                     data={"ok": True, "compliant": status.get("compliant")})
        return status

    def fail_run(self, error: str) -> dict[str, Any]:
        with file_lock(self.state_dir, "state"):
            status = self._read_status()
            status["failed"] = True
            status["finished"] = False
            status["current_chunk"] = None
            status["message"] = f"失败：{error or '未知错误'}"
            self._write_status(status)
        append_event(self.state_dir, "run_failed", actor="script",
                     data={"error": error or "unknown"})
        return status

    # ── verify（§3.4 F33-02 验收算法）─────────────────────────────────
    def verify(self, check: str) -> dict[str, Any]:
        cfg = self.config(required=True)
        status = self._read_status()
        checks: dict[str, Any] = {}
        payload: dict[str, Any] = {}

        if check in ("all", "pre-extract-order"):
            result = self._check_pre_extract_order(cfg, status)
            checks["pre_extract_order"] = result
            payload["missing_pre_extract"] = result["missing_pre_extract"]
        if check in ("all", "stage-artifacts"):
            checks["stage_artifacts"] = self._check_stage_artifacts(cfg)
        if check in ("all", "chunk-complete"):
            checks["chunk_complete"] = self._check_chunk_complete(cfg, status)
        if not checks:
            die(EXIT_USAGE, f"未知 --check 值：{check}")

        compliant = all(bool(v.get("pass")) for v in checks.values())
        with file_lock(self.state_dir, "state"):
            latest = self._read_status()
            latest["compliant"] = compliant
            self._write_status(latest)

        payload.update({"ok": True, "compliant": compliant, "checks": checks})
        payload.setdefault("missing_pre_extract", [])
        return payload

    def _check_pre_extract_order(self, cfg: dict[str, Any],
                                 status: dict[str, Any]) -> dict[str, Any]:
        """F33-02 唯一验收实现，逐字照抄 §3.4 的伪码。"""
        params = cfg.get("params") or {}
        mode = str(param(params, "pre_extract_mode"))
        first_n = int(param(params, "pre_extract_first_n") or 0)
        total = int(cfg.get("total_chunks") or status.get("chunks_total") or 0)
        chunk_status: dict[str, str] = status.get("chunk_status") or {}

        if mode == "off":
            return {"pass": True, "mode": "off", "required": 0, "checked": 0,
                    "missing_pre_extract": [], "out_of_order": [],
                    "note": "术语预抽已降级为 off，本项默认合规"}

        required: list[int] = []
        for n in range(1, total + 1):
            state = chunk_status.get(str(n))
            if state != "done":
                continue
            if mode == "firstNChunks" and n > first_n:
                continue
            required.append(n)

        first_pre: dict[int, int] = {}
        first_tr: dict[int, int] = {}
        for ev in read_events(self.state_dir):
            chunk = ev.get("chunk")
            seq = ev.get("seq")
            if not isinstance(chunk, int) or not isinstance(seq, int):
                continue
            etype = ev.get("type")
            if etype == "glossary_pre_extract":
                if chunk not in first_pre or seq < first_pre[chunk]:
                    first_pre[chunk] = seq
            elif etype == "chunk_translated":
                if chunk not in first_tr or seq < first_tr[chunk]:
                    first_tr[chunk] = seq

        missing: list[int] = []
        out_of_order: list[dict[str, int]] = []
        for n in required:
            pre = first_pre.get(n)
            tr = first_tr.get(n)
            if pre is None or tr is None:
                missing.append(n)
            elif pre >= tr:
                out_of_order.append({"chunk": n, "pre_seq": pre, "translated_seq": tr})

        return {
            "pass": not missing and not out_of_order,
            "mode": mode,
            "required": len(required),
            "checked": len(required),
            "missing_pre_extract": missing,
            "out_of_order": out_of_order,
        }

    def _check_stage_artifacts(self, cfg: dict[str, Any]) -> dict[str, Any]:
        """只校验「计划执行 且 已宣告 finished」的阶段，避免误报未跑到的阶段。"""
        planned = [s for s in (cfg.get("stages") or list(STAGE_IDS)) if s in STAGE_NAMES]
        finished: set[str] = set()
        skipped: set[str] = set()
        for ev in read_events(self.state_dir):
            data = ev.get("data") or {}
            stage = data.get("stage") or ev.get("stage")
            if not isinstance(stage, str):
                continue
            if ev.get("type") == "stage_finished":
                finished.add(stage)
            elif ev.get("type") == "stage_skipped":
                skipped.add(stage)

        missing: list[dict[str, Any]] = []
        for stage in planned:
            if stage not in finished or stage in skipped:
                continue
            gaps = [rel for rel in STAGE_ARTIFACTS.get(stage, ())
                    if not self._artifact_exists(rel)]
            if gaps:
                missing.append({"stage": stage, "missing": gaps})
        # DESIGN-v3.3-llm §3.3/T06：S4 走 LLM 管线后必须落 usage.json（LLM 用量取证）。
        # 仅对「已宣告 finished 且未跳过」的 S4 检查；WB 后端无 usage.json 时，
        # 调用方按 T05-c 降级到 pre-extract-order 核验，不阻塞主流程。
        if "S4" in finished and "S4" not in skipped:
            if not self._artifact_exists("usage.json"):
                missing.append({"stage": "S4", "missing": ["usage.json"]})
        return {
            "pass": not missing,
            "planned": planned,
            "finished": sorted(finished),
            "skipped": sorted(skipped),
            "missing": missing,
        }

    def _check_chunk_complete(self, cfg: dict[str, Any],
                              status: dict[str, Any]) -> dict[str, Any]:
        total = int(cfg.get("total_chunks") or status.get("chunks_total") or 0)
        chunk_status: dict[str, str] = status.get("chunk_status") or {}
        incomplete = [n for n in range(1, total + 1)
                      if chunk_status.get(str(n)) not in ("done", "skipped")]
        missing_files = [n for n in range(1, total + 1)
                         if chunk_status.get(str(n)) == "done"
                         and not os.path.isfile(chunk_path(self.state_dir, n, zh=True))]
        return {
            "pass": total > 0 and not incomplete and not missing_files,
            "total": total,
            "incomplete": incomplete,
            "missing_zh_files": missing_files,
        }

    # ── reset（§4.10）─────────────────────────────────────────────────
    def reset(self, archive: bool, keep_glossary: bool) -> dict[str, Any]:
        if not os.path.isdir(self.state_dir):
            die(EXIT_STATE, f"state 目录不存在，无需重置：{self.state_dir}")
        saved: dict[str, bytes] = {}
        if keep_glossary:
            for name in ("glossary.json", "glossary_conflicts.json"):
                path = os.path.join(self.state_dir, name)
                if os.path.isfile(path):
                    with open(path, "rb") as fh:
                        saved[name] = fh.read()

        archived = ""
        if archive:
            stamp = time.strftime("%Y%m%d%H%M%S", time.localtime())
            parent = os.path.dirname(self.state_dir)
            base = os.path.basename(self.state_dir.rstrip(os.sep))
            target = os.path.join(parent, f"{base}_archive_{stamp}")
            suffix = 1
            while os.path.exists(target):
                target = os.path.join(parent, f"{base}_archive_{stamp}_{suffix}")
                suffix += 1
            try:
                os.rename(self.state_dir, target)
            except OSError as exc:
                die(EXIT_IO, f"归档失败（{exc}）：{self.state_dir} → {target}")
            archived = target
        else:
            try:
                shutil.rmtree(self.state_dir)
            except OSError as exc:
                die(EXIT_IO, f"删除 state 目录失败（{exc}）：{self.state_dir}")

        for sub in ("chunks", "digests", "samples", ".locks"):
            os.makedirs(os.path.join(self.state_dir, sub), exist_ok=True)
        for name, blob in saved.items():
            with open(os.path.join(self.state_dir, name), "wb") as fh:
                fh.write(blob)
        self._write_status(self._blank_status())

        return {"ok": True, "state": self.state_dir, "archived": archived,
                "kept_glossary": sorted(saved.keys())}


# ══════════════════════════════════════════════════════════════════════════
# 子命令
# ══════════════════════════════════════════════════════════════════════════

def cmd_init(args: argparse.Namespace) -> int:
    params = load_json_arg(args.params_json)
    if not isinstance(params, dict):
        die(3, "--params-json 必须是 JSON 对象（{…}）。")
    store = StateStore(args.state)
    payload, code = store.init_run(args.input, args.backend, params, args.force)
    emit_json(payload)
    return code


def cmd_set_stage(args: argparse.Namespace) -> int:
    store = StateStore(ensure_state(args.state))
    emit_json(store.set_stage(args.stage.strip().upper(), args.name,
                              args.finish, args.skip, args.reason))
    return EXIT_OK


def cmd_mark_chunk(args: argparse.Namespace) -> int:
    store = StateStore(ensure_state(args.state))
    emit_json(store.mark_chunk(args.chunk, args.value, args.zh_chars,
                               args.error, args.reason))
    return EXIT_OK


def cmd_pending(args: argparse.Namespace) -> int:
    store = StateStore(ensure_state(args.state))
    pending = store.pending()
    cfg = store.config(required=False)
    status = store._read_status()
    total = int(cfg.get("total_chunks") or status.get("chunks_total") or 0)
    if args.format == "lines":
        for n in pending:
            sys.stdout.write(f"{n}\n")
        return EXIT_OK
    emit_json({"pending": pending, "done": max(total - len(pending), 0), "total": total})
    return EXIT_OK


def cmd_status(args: argparse.Namespace) -> int:
    if args.finish and args.fail:
        die(EXIT_USAGE, "--finish 与 --fail 互斥，不能同时给出。")
    store = StateStore(ensure_state(args.state))
    if args.fail:
        status = store.fail_run(args.error)
    elif args.finish:
        status = store.finish_run(args.message)
    elif args.refresh:
        status = store.refresh_status(args.message)
    else:
        status = store._read_status()
        if args.message:
            with file_lock(store.state_dir, "state"):
                status = store._read_status()
                status["message"] = args.message
                store._write_status(status)
                status = store._read_status()

    if args.format == "md":
        sys.stdout.write(render_status_md(status))
        return EXIT_OK
    emit_json(status)
    return EXIT_OK


def render_status_md(status: dict[str, Any]) -> str:
    """人类可读的进度快照，供 `report.md` 与终端排障使用。"""
    index = int(status.get("stage_index") or 0)
    lines = [
        f"### 进度 · 阶段 {index + 1}/{status.get('stage_total', STAGE_TOTAL)}"
        f" · {status.get('stage_name', '')}",
        "",
        f"- 块进度：{status.get('chunks_done', 0)}/{status.get('chunks_total', 0)}"
        f"（失败 {status.get('chunks_failed', 0)} · 跳过 {status.get('chunks_skipped', 0)}）",
        f"- 术语：{status.get('glossary_terms', 0)} 条"
        f"（锁定 {status.get('glossary_locked', 0)}）"
        f" · 未决冲突 {status.get('glossary_conflicts_open', 0)}",
        f"- QA 问题：{status.get('qa_issues', 0)} · 对齐 error：{status.get('alignment_issues', 0)}",
        f"- 合规：{status.get('compliant')}",
        f"- 状态：{status.get('message', '')}",
        "",
    ]
    return "\n".join(lines)


def cmd_event(args: argparse.Namespace) -> int:
    state = ensure_state(args.state)
    data: dict[str, Any] = {}
    if args.json:
        parsed = load_json_arg(args.json)
        if not isinstance(parsed, dict):
            die(3, "--json 必须是 JSON 对象（{…}）。")
        data.update(parsed)
    data.update(parse_kv_pairs(args.kv))
    seq = append_event(state, args.type, stage=args.stage, chunk=args.chunk,
                       actor=args.actor, data=data)
    emit_json({"ok": True, "seq": seq, "type": args.type,
               "chunk": args.chunk, "stage": args.stage, "data": data})
    return EXIT_OK


def cmd_verify(args: argparse.Namespace) -> int:
    store = StateStore(ensure_state(args.state))
    payload = store.verify(args.check)
    emit_json(payload)
    return EXIT_OK if payload["compliant"] else EXIT_CHECK


def cmd_reset(args: argparse.Namespace) -> int:
    store = StateStore(os.path.abspath(args.state))
    emit_json(store.reset(args.archive, args.keep_glossary))
    return EXIT_OK


# ══════════════════════════════════════════════════════════════════════════
# CLI
# ══════════════════════════════════════════════════════════════════════════

def build_parser() -> argparse.ArgumentParser:
    ap = make_parser(
        prog="state_tool.py",
        description="state/ 状态目录管理器（DESIGN-v3.3 §3 / §4.10）")
    ap.add_argument("--version", action="version",
                    version=f"state_tool.py (skill {SKILL_VERSION}, schema {SCHEMA_VERSION})")
    sub = ap.add_subparsers(dest="command", required=True, parser_class=UsageErrorParser)

    def with_state(p: argparse.ArgumentParser) -> argparse.ArgumentParser:
        p.add_argument("--state", required=True, help="<outDir>/state 目录")
        return p

    p_init = with_state(sub.add_parser("init", help="初始化或续跑判定"))
    p_init.add_argument("--input", required=True, help="日文 txt 绝对路径")
    p_init.add_argument("--backend", required=True, choices=("workbuddy", "deepseek"))
    p_init.add_argument("--params-json", required=True, dest="params_json",
                        help="params 对象，内联 JSON 或 @file")
    p_init.add_argument("--force", action="store_true", help="忽略续跑判定，强制重写 config")
    p_init.set_defaults(func=cmd_init)

    p_stage = with_state(sub.add_parser("set-stage", help="阶段切换"))
    p_stage.add_argument("--stage", required=True, help="S0…S8")
    p_stage.add_argument("--name", default=None, help="阶段中文名，缺省用内置文案")
    p_stage.add_argument("--finish", action="store_true", help="写 stage_finished")
    p_stage.add_argument("--skip", action="store_true", help="写 stage_skipped")
    p_stage.add_argument("--reason", default="", help="--skip 的原因")
    p_stage.set_defaults(func=cmd_set_stage)

    p_mark = with_state(sub.add_parser("mark-chunk", help="标记块状态"))
    p_mark.add_argument("--chunk", type=int, required=True)
    p_mark.add_argument("--value", required=True, choices=CHUNK_VALUES)
    p_mark.add_argument("--zh-chars", dest="zh_chars", type=int, default=None)
    p_mark.add_argument("--error", default="")
    p_mark.add_argument("--reason", default="")
    p_mark.set_defaults(func=cmd_mark_chunk)

    p_pending = with_state(sub.add_parser("pending", help="待处理块号"))
    p_pending.add_argument("--format", choices=("json", "lines"), default="json")
    p_pending.set_defaults(func=cmd_pending)

    p_status = with_state(sub.add_parser("status", help="读取 / 刷新 / 收尾状态"))
    p_status.add_argument("--refresh", action="store_true", help="回填术语/QA/对齐指标")
    p_status.add_argument("--message", default="", help="覆盖 message 文案")
    p_status.add_argument("--finish", action="store_true", help="标记全流程完成")
    p_status.add_argument("--fail", action="store_true", help="标记致命失败")
    p_status.add_argument("--error", default="", help="--fail 的错误描述")
    p_status.add_argument("--format", choices=("json", "md"), default="json")
    p_status.set_defaults(func=cmd_status)

    p_event = with_state(sub.add_parser("event", help="追加一条事件"))
    p_event.add_argument("--type", required=True, help="事件类型（§3.4 枚举）")
    p_event.add_argument("--chunk", type=int, default=None)
    p_event.add_argument("--stage", default=None)
    p_event.add_argument("--actor", default="agent", choices=("script", "swift", "agent"))
    p_event.add_argument("--kv", action="append", default=[], help="k=v，可重复")
    p_event.add_argument("--json", default="", help="data 对象，内联 JSON 或 @file")
    p_event.set_defaults(func=cmd_event)

    p_verify = with_state(sub.add_parser("verify", help="合规校验，不通过退 5"))
    p_verify.add_argument("--check", default="all",
                          choices=("all", "pre-extract-order", "stage-artifacts",
                                   "chunk-complete"))
    p_verify.add_argument("--format", choices=("json",), default="json")
    p_verify.set_defaults(func=cmd_verify)

    p_reset = with_state(sub.add_parser("reset", help="归档并重建 state"))
    p_reset.add_argument("--archive", action="store_true", help="改名保留旧目录")
    p_reset.add_argument("--keep-glossary", dest="keep_glossary", action="store_true")
    p_reset.set_defaults(func=cmd_reset)

    return ap


def main(argv: list[str] | None = None) -> int:
    install_excepthook("state_tool.py")
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
