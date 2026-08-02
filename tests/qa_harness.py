#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""qa_harness.py — v3.3 skill 脚本层测试公共底座（QA 侧，只读被测源码）

设计原则
--------
1. **被测脚本一律以子进程方式调用**，与 Swift / Agent 的真实调用方式一致；
   这样测的是「CLI 契约」而不是「Python 内部函数」，退出码与 stdout 通道
   都能被真实覆盖。
2. 只用标准库 `unittest` / `subprocess` / `tempfile`，零第三方依赖。
3. 所有临时状态目录都建在 `tempfile.TemporaryDirectory()` 里，用例结束即销毁。
4. 本文件**绝不修改** `Sources/` 下的任何文件。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from typing import Any

# ── 路径常量 ────────────────────────────────────────────────────────────
TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(TESTS_DIR)
SCRIPTS_DIR = os.path.join(
    PROJECT_ROOT, "Sources", "JaPdfOcrTranslator", "Resources",
    "skills", "jp-txt2pdf-translator", "scripts",
)

#: 托管 Python（任务书指定）。缺失时回落到当前解释器。
MANAGED_PY = "/Users/takimotouki/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
PY = MANAGED_PY if os.path.isfile(MANAGED_PY) else sys.executable

GLOSSARY = os.path.join(SCRIPTS_DIR, "glossary_tool.py")
STATE = os.path.join(SCRIPTS_DIR, "state_tool.py")
SPLIT = os.path.join(SCRIPTS_DIR, "split_text.py")
BOUNDARIES = os.path.join(SCRIPTS_DIR, "check_boundaries.py")
ALIGNMENT = os.path.join(SCRIPTS_DIR, "check_alignment.py")
PUNCT = os.path.join(SCRIPTS_DIR, "normalize_punct.py")
QA = os.path.join(SCRIPTS_DIR, "qa_consistency.py")
REPORT = os.path.join(SCRIPTS_DIR, "make_report.py")
MERGE = os.path.join(SCRIPTS_DIR, "merge.py")
SAMPLE = os.path.join(SCRIPTS_DIR, "sample_text.py")
REDUCE = os.path.join(SCRIPTS_DIR, "reduce_digests.py")
BUILD_PDF = os.path.join(SCRIPTS_DIR, "build_pdf.py")

#: 契约退出码（DESIGN §4.0）
EXIT_OK, EXIT_USAGE, EXIT_IO, EXIT_INPUT, EXIT_STATE, EXIT_CHECK = 0, 1, 2, 3, 4, 5


class Result:
    """一次子进程调用的结果。`json` 属性做惰性解析，非 JSON 输出时为 None。"""

    def __init__(self, proc: subprocess.CompletedProcess[str], argv: list[str]):
        self.code: int = proc.returncode
        self.out: str = proc.stdout
        self.err: str = proc.stderr
        self.argv: list[str] = argv

    @property
    def json(self) -> Any:
        try:
            return json.loads(self.out)
        except ValueError:
            return None

    def get(self, dotted: str, default: Any = None) -> Any:
        """按 `a.b.c` 路径取 stdout JSON 里的值。"""
        node = self.json
        for part in dotted.split("."):
            if not isinstance(node, dict) or part not in node:
                return default
            node = node[part]
        return node

    def __repr__(self) -> str:                       # pragma: no cover - 仅调试用
        return (f"<Result code={self.code}\n  argv={' '.join(self.argv)}\n"
                f"  stdout={self.out[:600]}\n  stderr={self.err[:600]}>")


def run(script: str, *args: str, stdin: str | None = None,
        cwd: str | None = None, timeout: float = 120.0) -> Result:
    """以子进程运行一个被测脚本。"""
    argv = [PY, script, *[str(a) for a in args]]
    proc = subprocess.run(
        argv, input=stdin, capture_output=True, text=True,
        encoding="utf-8", cwd=cwd, timeout=timeout,
    )
    return Result(proc, argv)


# ── 被测脚本的便捷包装 ──────────────────────────────────────────────────

def g(*args: str, stdin: str | None = None) -> Result:
    """glossary_tool.py"""
    return run(GLOSSARY, *args, stdin=stdin)


def s(*args: str, stdin: str | None = None) -> Result:
    """state_tool.py"""
    return run(STATE, *args, stdin=stdin)


# ── 夹具 ────────────────────────────────────────────────────────────────

class ScriptTestCase(unittest.TestCase):
    """提供一个隔离的 `<tmp>/out/state` 目录与一组读写便捷方法。"""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="japdf-qa-")
        self.root = self._tmp.name
        self.out_dir = os.path.join(self.root, "out")
        self.state = os.path.join(self.out_dir, "state")
        os.makedirs(self.state, exist_ok=True)
        self.addCleanup(self._tmp.cleanup)

    # ── 文件工具 ────────────────────────────────────────────────────
    def write(self, rel: str, text: str) -> str:
        """在 state 目录下写一个文本文件，返回绝对路径。"""
        path = rel if os.path.isabs(rel) else os.path.join(self.state, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        return path

    def write_root(self, rel: str, text: str) -> str:
        """在临时根目录下写文件（用于放输入 txt / 用户 CSV）。"""
        return self.write(os.path.join(self.root, rel), text)

    def read(self, rel: str) -> str:
        path = rel if os.path.isabs(rel) else os.path.join(self.state, rel)
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()

    def read_json(self, rel: str) -> Any:
        return json.loads(self.read(rel))

    def chunk(self, n: int, text: str, zh: bool = False) -> str:
        name = f"chunk_{n:03d}{'_zh' if zh else ''}.txt"
        return self.write(os.path.join("chunks", name), text)

    # ── 术语库便捷断言 ──────────────────────────────────────────────
    def glossary(self) -> dict[str, Any]:
        return self.read_json("glossary.json")

    def terms_by_source(self) -> dict[str, dict[str, Any]]:
        return {t["source"]: t for t in self.glossary().get("terms", [])}

    def conflicts(self) -> list[dict[str, Any]]:
        return self.read_json("glossary_conflicts.json").get("conflicts", [])

    def events(self) -> list[dict[str, Any]]:
        path = os.path.join(self.state, "events.jsonl")
        if not os.path.isfile(path):
            return []
        out = []
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    out.append(json.loads(line))
        return out

    # ── 常用初始化 ──────────────────────────────────────────────────
    def init_policy_c(self) -> Result:
        return g("init", "--state", self.state, "--policy", "C")

    def init_policy_d(self) -> Result:
        return g("init", "--state", self.state, "--policy", "D")

    def user_csv(self, rows: str, name: str = "user_glossary.csv") -> str:
        return self.write_root(name, rows)

    def init_with_user(self, policy: str, rows: str | None = None) -> Result:
        rows = rows if rows is not None else "日语,中文\n御堂 静,御堂静\n氷室,冰室\n"
        path = self.user_csv(rows)
        return g("init", "--state", self.state, "--policy", policy,
                 "--user-csv", path)

    def upsert(self, terms: list[dict[str, Any]], *extra: str) -> Result:
        payload = json.dumps({"terms": terms}, ensure_ascii=False)
        return g("upsert", "--state", self.state, "--stdin", *extra, stdin=payload)

    # ── 断言助手 ────────────────────────────────────────────────────
    def assertCode(self, result: Result, expected: int, msg: str = "") -> None:
        self.assertEqual(
            result.code, expected,
            f"{msg}\n  期望退出码 {expected}，实际 {result.code}\n"
            f"  命令：{' '.join(result.argv)}\n"
            f"  stdout：{result.out[:500]}\n  stderr：{result.err[:500]}")

    def assertOk(self, result: Result, msg: str = "") -> None:
        self.assertCode(result, EXIT_OK, msg)


def load_module(name: str):
    """把被测脚本作为模块 import（用于纯函数级白盒测试）。"""
    if SCRIPTS_DIR not in sys.path:
        sys.path.insert(0, SCRIPTS_DIR)
    import importlib
    return importlib.import_module(name)
