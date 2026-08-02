#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""llm_unit_test.py — T09 单测（离线，覆盖 resolve_tier / repair_json / retry / usage / validate 五组）

- 纯 stdlib unittest，零第三方依赖。
- 白盒组（resolve_tier / repair_json / retry / usage）直接 import `_llm_common`；
- 黑盒组（validate）以子进程跑 `llm_tool.py`，测 CLI 契约与退出码。
- **双 Python 版本兼容**：托管 Python 3.13 与系统 /usr/bin/python3 (3.9.6) 都能跑
  （`from __future__ import annotations` + 不使用 3.10+ 运行时语法）。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from typing import Any, Optional

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(TESTS_DIR)
SCRIPTS_DIR = os.path.join(
    PROJECT_ROOT, "Sources", "JaPdfOcrTranslator", "Resources",
    "skills", "jp-txt2pdf-translator", "scripts",
)
sys.path.insert(0, SCRIPTS_DIR)

from _llm_common import (  # noqa: E402
    EXIT_RETRY, RetryExhausted, UsageTracker, UsageSample,
    _RetryableError, parse_json_result, repair_json,
    build_client, resolve_tier, retry_with_backoff,
)

PY = sys.executable
LLM_TOOL = os.path.join(SCRIPTS_DIR, "llm_tool.py")


def run_tool(*args: str, stdin: Optional[str] = None) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(
        [PY, LLM_TOOL, *args], input=stdin, capture_output=True, text=True,
        encoding="utf-8", timeout=120,
    )


# ════════════════════════════════════════════════════════════════════════
# 1. resolve_tier（只降不升）
# ════════════════════════════════════════════════════════════════════════

class TestResolveTier(unittest.TestCase):
    def test_fast_falls_to_cheap(self) -> None:
        tiers = {"strong": {"model": "s"}, "cheap": {"model": "c"}}
        self.assertEqual(resolve_tier(tiers, "fast")["model"], "c")

    def test_fast_falls_to_strong_when_no_cheap(self) -> None:
        tiers = {"strong": {"model": "s"}}
        self.assertEqual(resolve_tier(tiers, "fast")["model"], "s")

    def test_cheap_falls_to_strong(self) -> None:
        tiers = {"strong": {"model": "s"}}
        self.assertEqual(resolve_tier(tiers, "cheap")["model"], "s")

    def test_missing_strong_raises(self) -> None:
        with self.assertRaises(KeyError):
            resolve_tier({}, "strong")

    def test_exact_tier_wins(self) -> None:
        tiers = {"fast": {"model": "f"}, "cheap": {"model": "c"}, "strong": {"model": "s"}}
        self.assertEqual(resolve_tier(tiers, "fast")["model"], "f")


# ════════════════════════════════════════════════════════════════════════
# 2. repair_json / parse_json_result（四类高频畸形 + repaired 标记）
# ════════════════════════════════════════════════════════════════════════

class TestRepairJSON(unittest.TestCase):
    def test_trailing_comma(self) -> None:
        r = parse_json_result('{"a":1,}')
        self.assertTrue(r.repaired)
        self.assertEqual(r.value, {"a": 1})

    def test_unquoted_key(self) -> None:
        r = parse_json_result("{a:1}")
        self.assertTrue(r.repaired)
        self.assertEqual(r.value, {"a": 1})

    def test_single_quotes(self) -> None:
        r = parse_json_result("'{\"a\":1}'")
        self.assertTrue(r.repaired)
        self.assertEqual(r.value, {"a": 1})

    def test_markdown_fence(self) -> None:
        r = parse_json_result("```json\n{\"a\":1}\n```")
        self.assertTrue(r.repaired)
        self.assertEqual(r.value, {"a": 1})

    def test_plain_text_raises(self) -> None:
        with self.assertRaises(ValueError):
            parse_json_result("纯文本不是 JSON")

    def test_valid_json_no_repair(self) -> None:
        r = parse_json_result('{"a": 1}')
        self.assertFalse(r.repaired)
        self.assertEqual(r.value, {"a": 1})


# ════════════════════════════════════════════════════════════════════════
# 3. retry_with_backoff（429→200 attempts==2；全程 429 退 6 语义）
# ════════════════════════════════════════════════════════════════════════

class TestRetry(unittest.TestCase):
    def test_retry_once_succeeds(self) -> None:
        calls = {"n": 0}

        def fn() -> str:
            calls["n"] += 1
            if calls["n"] == 1:
                raise _RetryableError("429 rate limit")
            return "ok"

        value, attempts = retry_with_backoff(
            fn, attempts=3, base=0.01, max_wait=0.05, jitter=0.0,
            retry_if=lambda e: isinstance(e, _RetryableError),
        )
        self.assertEqual(value, "ok")
        self.assertEqual(attempts, 2)
        self.assertEqual(calls["n"], 2)

    def test_all_fail_raises_exhausted(self) -> None:
        calls = {"n": 0}

        def fn() -> str:
            calls["n"] += 1
            raise _RetryableError("always 429")

        with self.assertRaises(RetryExhausted) as ctx:
            retry_with_backoff(
                fn, attempts=3, base=0.01, max_wait=0.05, jitter=0.0,
                retry_if=lambda e: isinstance(e, _RetryableError),
            )
        self.assertEqual(ctx.exception.attempts, 3)
        self.assertEqual(calls["n"], 3)   # = max_retries+1（全程 429 退 6 的底层语义）

    def test_non_retryable_error_not_retried(self) -> None:
        calls = {"n": 0}

        def fn() -> str:
            calls["n"] += 1
            raise ValueError("4xx 非 429 不重试")

        with self.assertRaises(RetryExhausted) as ctx:
            retry_with_backoff(
                fn, attempts=3, base=0.01, max_wait=0.05, jitter=0.0,
                retry_if=lambda e: isinstance(e, _RetryableError),
            )
        self.assertEqual(ctx.exception.attempts, 1)
        self.assertEqual(calls["n"], 1)


# ════════════════════════════════════════════════════════════════════════
# 4. UsageTracker（calls==Σby_tier）
# ════════════════════════════════════════════════════════════════════════

class TestUsage(unittest.TestCase):
    def test_totals_equal_sum_of_tiers(self) -> None:
        t = UsageTracker()
        t.record("strong", UsageSample(prompt_tokens=100, completion_tokens=50, total_tokens=150), "S4_translate")
        t.record("cheap", UsageSample(prompt_tokens=10, completion_tokens=5, total_tokens=15), "S4_pre_extract")
        t.record("strong", UsageSample(prompt_tokens=200, completion_tokens=100, total_tokens=300), "S4_translate")
        s = t.summary()
        self.assertEqual(s["totals"]["calls"], 3)
        tier_sum = sum(slot["calls"] for slot in s["by_tier"].values())
        self.assertEqual(s["totals"]["calls"], tier_sum)
        self.assertEqual(s["totals"]["total_tokens"], 150 + 15 + 300)
        stage_sum = sum(slot["total_tokens"] for slot in s["by_stage"].values())
        self.assertEqual(s["totals"]["total_tokens"], stage_sum)

    def test_none_sample_ignored(self) -> None:
        t = UsageTracker()
        t.record("strong", None, "S4_translate")
        self.assertEqual(t.summary()["totals"]["calls"], 0)


# ════════════════════════════════════════════════════════════════════════
# 5. validate（黑盒：缺 key 退 5 / 缺 strong 退 5 / fake 退 0）
# ════════════════════════════════════════════════════════════════════════

class TestValidate(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="t09-unit-")
        self.state = os.path.join(self._tmp.name, "state")
        os.makedirs(self.state, exist_ok=True)
        self.addCleanup(self._tmp.cleanup)

    def _config(self, path: str, obj: Any) -> str:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False)
        return path

    def test_fake_ok(self) -> None:
        cfg = self._config(os.path.join(self._tmp.name, "fake.json"), {
            "provider": "fake",
            "tiers": {"strong": {"model": "m", "options": {}}},
        })
        r = run_tool("validate", "--state", self.state, "--config-file", cfg)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(json.loads(r.stdout)["ok"])

    def test_deepseek_no_key_exit5(self) -> None:
        cfg = self._config(os.path.join(self._tmp.name, "nokey.json"), {
            "provider": "deepseek",
            "api_key_env": "DEEPSEEK_API_KEY_DOES_NOT_EXIST_XYZ",
            "tiers": {"strong": {"model": "m", "options": {}},
                      "cheap": {"model": "m", "options": {}},
                      "fast": {"model": "m", "options": {}}},
        })
        r = run_tool("validate", "--state", self.state, "--config-file", cfg)
        self.assertEqual(r.returncode, 5, r.stdout + r.stderr)

    def test_missing_strong_exit5(self) -> None:
        cfg = self._config(os.path.join(self._tmp.name, "nostrong.json"), {
            "provider": "fake",
            "tiers": {"cheap": {"model": "m", "options": {}}},
        })
        r = run_tool("validate", "--state", self.state, "--config-file", cfg)
        self.assertEqual(r.returncode, 5, r.stdout + r.stderr)

    def test_vllm_uses_wenyi_default_endpoint_without_key(self) -> None:
        client = build_client({
            "provider": "vllm",
            "tiers": {"strong": {"model": "local-model", "options": {}}},
        })
        self.assertEqual(client.base_url, "http://localhost:8000/v1")
        self.assertFalse(client.requires_api_key)


if __name__ == "__main__":
    unittest.main(verbosity=2)
