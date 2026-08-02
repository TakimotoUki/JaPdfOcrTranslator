#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_llm_common.py — LLM 底层公共库（DESIGN-v3.3-llm §4/§5.1，T06 新地基）

零第三方依赖：只用 stdlib（urllib / json / dataclasses / typing）。

移植对照（照搬 wenyi-0.4.0/trans_novel/llm/，逐字对齐处注释标注源文件）：
- `resolve_tier`               ← tiers.py（只降不升回退链）
- `UsageTracker` / `UsageSample`
  / `_usage_summary` / `merge_usage_summaries`  ← usage.py（按设计去掉 threading）
- `base_request_kwargs`        ← providers/_openai_compatible.py（JSON 模式双保险）
- `normalize_openai_usage`     ← providers/_openai_compatible.py
- `normalize_deepseek_usage`   ← providers/deepseek.py
- `build_request_kwargs`（deepseek 方言） ← providers/deepseek.py
- `FakeClient`（JSONL 脚本版） ← providers/fake.py 的语义 + DESIGN §4.7 的脚本格式
- `parse_json_result`          ← json_parser.py 的语义，但 repair_json 改为 §4.6 手写实现

本文件不 import 任何第三方包；`llm_tool.py` 负责 CLI、退出码、usage.lock 与事件。
"""

from __future__ import annotations

import json
import os
import random
import time
import urllib.error
import urllib.request
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, Callable

#: LLM 重试耗尽退出码（DESIGN-v3.3-llm §4.0，延续 v3.3 退出码语义的新增 6）。
EXIT_RETRY = 6

#: 已知 provider 集合（build_client 的合法值）。
KNOWN_PROVIDERS = (
    "deepseek", "openai", "openrouter", "openai-compatible",
    "ollama", "vllm", "gemini", "fake",
)

#: provider 默认连接信息（DESIGN-v3.3-llm §4.5，照搬 wenyi factory/providers）。
PROVIDER_DEFAULTS: dict[str, dict[str, Any]] = {
    "deepseek": {
        "base_url": "https://api.deepseek.com",
        "api_key_env": "DEEPSEEK_API_KEY",
        "requires_api_key": True,
    },
    "openai": {
        "base_url": "https://api.openai.com/v1",
        "api_key_env": "OPENAI_API_KEY",
        "requires_api_key": True,
    },
    "openrouter": {
        "base_url": "https://openrouter.ai/api/v1",
        "api_key_env": "OPENROUTER_API_KEY",
        "requires_api_key": True,
    },
    "openai-compatible": {
        "base_url": "",               # 必填
        "api_key_env": "",
        "requires_api_key": False,    # 可配（cfg.api_key / cfg.api_key_env）
    },
    "ollama": {
        "base_url": "http://localhost:11434/v1",
        "api_key_env": "",
        "requires_api_key": False,
    },
    "vllm": {
        "base_url": "http://localhost:8000/v1",
        "api_key_env": "",
        "requires_api_key": False,    # 可配
    },
    "gemini": {
        "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
        "api_key_env": "GEMINI_API_KEY",
        "requires_api_key": True,
    },
    "fake": {
        "base_url": "",
        "api_key_env": "",
        "requires_api_key": False,
    },
}

#: deepseek 三档默认（DESIGN §4.5 默认表，照搬 wenyi providers/deepseek.py `_default_tiers`）。
DEEPSEEK_DEFAULT_TIERS: dict[str, dict[str, Any]] = {
    "strong": {"model": "deepseek-v4-pro", "options": {"thinking": True, "reasoning_effort": "high"}},
    "cheap": {"model": "deepseek-v4-flash", "options": {"thinking": True, "reasoning_effort": "high"}},
    "fast": {"model": "deepseek-v4-flash", "options": {"thinking": False, "reasoning_effort": "none"}},
}

#: JSON 模式指令（照搬 wenyi `_JSON_MODE_INSTRUCTION`）。
_JSON_MODE_INSTRUCTION = "Output must be valid json."

#: 用量字段（照搬 wenyi usage.py `_USAGE_FIELDS`）。
_USAGE_FIELDS = (
    "calls", "prompt_tokens", "completion_tokens", "total_tokens",
    "cache_hit_tokens", "cache_miss_tokens",
)


# ════════════════════════════════════════════════════════════════════════
# 档位解析（照搬 wenyi tiers.py）
# ════════════════════════════════════════════════════════════════════════

#: 缺档回退链：向“更便宜优先”回退，绝不因缺档反而升到更贵的档。
_TIER_FALLBACK = {"fast": ("cheap", "strong"), "cheap": ("strong",), "strong": ()}


def resolve_tier(tiers: dict[str, Any], tier: str) -> dict[str, Any]:
    """按回退链解析 tier 配置（wenyi tiers.py，逐字语义）。

    只降不升：`fast` 缺失 → 回退 `cheap` → 再缺 → `strong`；
    `cheap` 缺失 → `strong`；`strong` 本身缺失 → 直接 `KeyError`（与旧行为一致）。
    """
    if tier in tiers:
        return tiers[tier]
    for fallback in _TIER_FALLBACK.get(tier, ("strong",)):
        if fallback in tiers:
            return tiers[fallback]
    return tiers["strong"]


def resolve_provider_tiers(overrides: dict[str, Any],
                           defaults: dict[str, Any]) -> dict[str, Any]:
    """合并 provider 默认档位与用户覆盖；strong 缺失报错（wenyi `resolve_provider_tiers`）。

    `overrides[tier] = {model?, options{...}}`；options 递归合并到默认 options。
    """
    tiers = {name: {"model": cfg.get("model"), "options": dict(cfg.get("options") or {})}
             for name, cfg in (defaults or {}).items()}
    for name, override in (overrides or {}).items():
        current = tiers.get(name) or {"model": None, "options": {}}
        model = override.get("model") or current.get("model")
        if not model:
            raise ValueError(f"llm.tiers.{name}.model 不能为空")
        options = dict(current.get("options") or {})
        options.update(override.get("options") or {})
        tiers[name] = {"model": model, "options": options}
    if "strong" not in tiers:
        raise ValueError("配置缺少 llm.tiers.strong.model")
    return tiers


# ════════════════════════════════════════════════════════════════════════
# 用量统计（照搬 wenyi usage.py，去掉 threading）
# ════════════════════════════════════════════════════════════════════════

@dataclass(frozen=True)
class UsageSample:
    """provider 原始 usage 标准化后的单次调用用量（wenyi usage.py）。"""

    prompt_tokens: int
    completion_tokens: int
    total_tokens: int
    cache_hit_tokens: int = 0
    cache_miss_tokens: int = 0


def read_usage_value(usage: Any, name: str) -> Any:
    """从字典读取字段，保留缺失与 0 的区别（wenyi `read_usage_value`）。"""
    if usage is None:
        return None
    return usage.get(name) if isinstance(usage, dict) else None


def read_usage_int(usage: Any, name: str) -> int:
    """读取整数字段，缺失或非数返回 0（wenyi `read_usage_int`）。"""
    value = read_usage_value(usage, name)
    try:
        return int(value) if value is not None else 0
    except (TypeError, ValueError):
        return 0


def make_usage_sample(usage: Any, *, cache_hit_tokens: int = 0,
                      cache_miss_tokens: int = 0) -> UsageSample | None:
    """读取各 API 共用的 token 字段，组装 provider 无关的用量记录（wenyi `make_usage_sample`）。"""
    if usage is None:
        return None
    prompt_tokens = read_usage_int(usage, "prompt_tokens")
    completion_tokens = read_usage_int(usage, "completion_tokens")
    total_tokens = read_usage_int(usage, "total_tokens") or (prompt_tokens + completion_tokens)
    return UsageSample(
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        total_tokens=total_tokens,
        cache_hit_tokens=max(0, cache_hit_tokens),
        cache_miss_tokens=max(0, cache_miss_tokens),
    )


def _hit_rate(hit: int, miss: int) -> float:
    """计算缓存 token 命中率，无可统计 token 时返回 0（wenyi `_hit_rate`）。"""
    total = hit + miss
    return round(hit / total, 4) if total else 0.0


def _normalize_usage_group(group: dict[str, dict[str, int]]) -> dict[str, dict[str, Any]]:
    """规范化一组用量槽位，并重新计算各槽位缓存命中率（wenyi `_normalize_usage_group`）。"""
    normalized: dict[str, dict[str, Any]] = {
        name: {field: read_usage_int(values, field) for field in _USAGE_FIELDS}
        for name, values in group.items()
    }
    for slot in normalized.values():
        slot["cache_hit_rate"] = _hit_rate(slot["cache_hit_tokens"], slot["cache_miss_tokens"])
    return normalized


def _usage_summary(by_tier: dict[str, dict[str, int]],
                   by_stage: dict[str, dict[str, int]]) -> dict[str, Any]:
    """生成规范汇总；总计仅由 tier 计算，stage 是同一用量的另一种归因维度（wenyi `_usage_summary`）。"""
    tiers = _normalize_usage_group(by_tier)
    stages = _normalize_usage_group(by_stage)
    totals: dict[str, Any] = dict.fromkeys(_USAGE_FIELDS, 0)
    for values in tiers.values():
        for field in _USAGE_FIELDS:
            totals[field] += values[field]
    totals["cache_hit_rate"] = _hit_rate(totals["cache_hit_tokens"], totals["cache_miss_tokens"])
    return {"totals": totals, "by_tier": tiers, "by_stage": stages}


def _merge_usage_groups(*groups: dict[str, dict[str, int]]) -> dict[str, dict[str, int]]:
    """按槽位逐字段累加多组 token 用量（wenyi `_merge_usage_groups`）。"""
    merged: dict[str, dict[str, int]] = {}
    for group in groups:
        for name, values in group.items():
            slot = merged.setdefault(name, dict.fromkeys(_USAGE_FIELDS, 0))
            for field in _USAGE_FIELDS:
                slot[field] += read_usage_int(values, field)
    return merged


def merge_usage_summaries(accumulated: dict[str, Any],
                          increment: dict[str, Any]) -> dict[str, Any]:
    """把一次运行增量合并进历史累计用量（wenyi `merge_usage_summaries`）。"""
    tiers = _merge_usage_groups(accumulated["by_tier"], increment["by_tier"])
    stages = _merge_usage_groups(accumulated["by_stage"], increment["by_stage"])
    return _usage_summary(tiers, stages)


def empty_usage() -> dict[str, Any]:
    """构造一个全零 usage 汇总（无任何槽位）。"""
    return _usage_summary({}, {})


class UsageTracker:
    """累加标准化用量，按 tier 和调用 stage 分别归因（wenyi usage.py，无 threading）。"""

    def __init__(self) -> None:
        """初始化 tier 与调用阶段两种归因视图；总计始终以 tier 为准。"""
        self._by_tier: dict[str, dict[str, int]] = {}
        self._by_stage: dict[str, dict[str, int]] = {}

    def record(self, tier: str, sample: UsageSample | None, stage: str | None = None) -> None:
        """累加 provider 标准化后的用量；缺失时静默跳过（wenyi `record`）。"""
        if sample is None:
            return
        slots = [self._by_tier.setdefault(tier, dict.fromkeys(_USAGE_FIELDS, 0))]
        if stage:
            slots.append(self._by_stage.setdefault(stage, dict.fromkeys(_USAGE_FIELDS, 0)))
        for slot in slots:
            slot["calls"] += 1
            slot["prompt_tokens"] += sample.prompt_tokens
            slot["completion_tokens"] += sample.completion_tokens
            slot["total_tokens"] += sample.total_tokens
            slot["cache_hit_tokens"] += sample.cache_hit_tokens
            slot["cache_miss_tokens"] += sample.cache_miss_tokens

    def summary(self) -> dict[str, Any]:
        """返回 totals、by_tier 和 by_stage，各槽位含 cache_hit_rate（wenyi `summary`）。"""
        by_tier = {tier: dict(values) for tier, values in self._by_tier.items()}
        by_stage = {stage: dict(values) for stage, values in self._by_stage.items()}
        return _usage_summary(by_tier, by_stage)

    def merge_from_file(self, path: str) -> None:
        """把磁盘上已累计的 usage.json 合并进当前 tracker（增量合并语义 wenyi `merge_usage_summaries`）。

        供 `llm_tool.py` 在 `usage.lock` 内「读历史 → 合并本次 → 原子写回」。
        """
        try:
            with open(path, "r", encoding="utf-8") as fh:
                disk = json.load(fh)
        except (OSError, json.JSONDecodeError, TypeError):
            return
        if not isinstance(disk, dict):
            return
        disk_tiers = disk.get("by_tier") or {}
        disk_stages = disk.get("by_stage") or {}
        self._by_tier = _merge_usage_groups(self._by_tier, disk_tiers)
        self._by_stage = _merge_usage_groups(self._by_stage, disk_stages)


# ════════════════════════════════════════════════════════════════════════
# JSON 宽松解析（§4.6 手写实现，替代 json-repair）
# ════════════════════════════════════════════════════════════════════════

@dataclass(frozen=True)
class JsonParseResult:
    """模型 JSON 的解析结果，以及是否经过语法修复（wenyi json_parser.py）。"""

    value: Any
    repaired: bool


def repair_json(text: str) -> str:
    r"""§4.6 手写确定性修复，返回修复后的 JSON 文本；全部失败抛 `ValueError`。

    依次尝试：
    a. 剥离 Markdown 代码围栏（```json … ``` / ~~~json … ~~~）；
    b. 提取首个 `{` 到末个 `}`（或 `[` 到 `]`）之间的子串；
    c. 删除行尾逗号（正则匹配 `逗号紧跟右括号` 的模式）；
    d. 单引号替换为双引号（保守：`'(?=[^']*':)` 键侧 + 值侧成对）；
    e. 未加引号键补引号（`^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:` 逐行）；
    f. 修复字符串内裸换行（把 `"…\n…"` 里的裸换行转义为 `\\n`）。
    """
    raw = (text or "").strip()
    if not raw:
        raise ValueError(f"无法解析为 JSON：{text[:200]!r}")

    # a. 剥离 Markdown 代码围栏
    candidate = raw
    for fence in ("```json", "```", "~~~json", "~~~"):
        if candidate.startswith(fence):
            candidate = candidate[len(fence):].strip()
            if candidate.endswith(fence):
                candidate = candidate[:-len(fence)].strip()
            break

    # b. 提取首个 { 到末个 }（或 [ 到 ]）
    first_open = candidate.find("{")
    first_bracket = candidate.find("[")
    if first_open != -1 and (first_bracket == -1 or first_open < first_bracket):
        start = first_open
        end = candidate.rfind("}")
        if end != -1 and end >= start:
            candidate = candidate[start:end + 1]
    elif first_bracket != -1:
        start = first_bracket
        end = candidate.rfind("]")
        if end != -1 and end >= start:
            candidate = candidate[start:end + 1]

    # 快速验证：已合法 → 直接返回
    try:
        json.loads(candidate)
        return candidate
    except (json.JSONDecodeError, TypeError):
        pass

    # c. 删除行尾逗号
    import re
    candidate = re.sub(r",\s*([}\]])", r"\1", candidate)

    # d. 单引号 → 双引号（键侧保守匹配）
    candidate = re.sub(r"'([^']*)'(?=\s*:)", r'"\1"', candidate)
    # 值侧：'x' 或 'x,y'（不成对引号时保守处理）
    candidate = re.sub(r":\s*'([^']*)'", r': "\1"', candidate)

    # e. 未加引号键补引号：`key:` 出现在行首，或跟在 `{` / `,` 之后（逐行处理）
    #    例：`{a:1}`、`{"b":2, c:3}` → `{"a":1}`、`{"b":2, "c":3}`
    candidate = re.sub(
        r'(^|[{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)',
        r'\1"\2"\3',
        candidate,
        flags=re.M,
    )

    # f. 修复字符串内裸换行：把引号内未转义的 \n 变成 \\n
    candidate = _escape_bare_newlines_in_strings(candidate)

    try:
        json.loads(candidate)
        return candidate
    except (json.JSONDecodeError, TypeError):
        raise ValueError(f"无法解析为 JSON：{text[:200]!r}")


def _escape_bare_newlines_in_strings(text: str) -> str:
    """把 JSON 字符串字面量内部的裸换行转义为 `\\n`（§4.6-f）。"""
    out: list[str] = []
    in_string = False
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and in_string and i + 1 < len(text):
            out.append(ch)
            out.append(text[i + 1])
            i += 2
            continue
        if ch == "\"" and (i == 0 or text[i - 1] != "\\"):
            in_string = not in_string
            out.append(ch)
            i += 1
            continue
        if ch == "\n" and in_string:
            out.append("\\n")
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def parse_json_result(text: str) -> JsonParseResult:
    """解析模型 JSON，并准确标记结果是否经过语法修复（wenyi `parse_json_result` 语义）。"""
    raw = (text or "").strip()
    try:
        return JsonParseResult(json.loads(raw), repaired=False)
    except (json.JSONDecodeError, TypeError):
        pass
    fixed = repair_json(raw)
    return JsonParseResult(json.loads(fixed), repaired=True)


def parse_json_loose(text: str) -> Any:
    """返回模型 JSON 的值；语法容错由 `repair_json` 统一实现（wenyi `parse_json_loose`）。"""
    return parse_json_result(text).value


# ════════════════════════════════════════════════════════════════════════
# 指数退避重试（§4.1，替代 tenacity）
# ════════════════════════════════════════════════════════════════════════

class RetryExhausted(Exception):
    """重试耗尽（对应退出码 6）。"""

    def __init__(self, attempts: int, last_error: BaseException) -> None:
        super().__init__(f"重试耗尽（{attempts} 次）：{last_error}")
        self.attempts = attempts
        self.last_error = last_error


def retry_with_backoff(
    fn: Callable[[], Any],
    attempts: int,
    *,
    base: float = 1.0,
    max_wait: float = 30.0,
    jitter: float = 0.2,
    retry_if: Callable[[BaseException], bool] | None = None,
) -> tuple[Any, int]:
    """带抖动指数退避的重试（§4.1 `retry_with_backoff(attempts=max_retries+1, base=1.0, max=30, jitter=0.2)`）。

    - `attempts` = 最大尝试次数（含首次）。
    - `retry_if` 返回 False 的异常**不重试**（如 HTTP 4xx 非 429），直接抛 `RetryExhausted`。
    - 耗尽时抛 `RetryExhausted(attempts=实际尝试次数)`。
    - 返回 `(结果, 实际尝试次数)`。
    """
    if attempts < 1:
        attempts = 1
    last_error: BaseException | None = None
    for attempt in range(1, attempts + 1):
        try:
            return fn(), attempt
        except BaseException as error:  # noqa: BLE001 —— 由 retry_if 决定是否吞掉
            last_error = error
            if retry_if is not None and not retry_if(error):
                raise RetryExhausted(attempt, error) from error
            if attempt >= attempts:
                break
            wait = min(max_wait, base * (2 ** (attempt - 1)))
            if jitter > 0:
                wait = wait * (1 + random.uniform(-jitter, jitter))
            time.sleep(max(0.0, wait))
    raise RetryExhausted(attempts, last_error or RuntimeError("unknown"))


# ════════════════════════════════════════════════════════════════════════
# 客户端抽象与 OpenAI 兼容传输（§4.5 / §5.1，照搬 wenyi base/_openai_compatible）
# ════════════════════════════════════════════════════════════════════════

Messages = list[dict[str, str]]


class LLMClient(ABC):
    """所有 provider 实现此接口（wenyi base.py）。"""

    def __init__(self) -> None:
        """为 provider 初始化独立的用量统计器。"""
        self.usage = UsageTracker()

    def usage_summary(self) -> dict[str, Any]:
        """返回累计 token 用量快照（totals + by_tier + by_stage）。"""
        return self.usage.summary()

    def validate_credentials(self) -> None:
        """校验 provider 调用所需凭据；本地或测试 provider 默认免检。"""

    @abstractmethod
    def complete(
        self,
        messages: Messages,
        *,
        tier: str = "strong",
        json_mode: bool = False,
        max_tokens: int | None = None,
        stage: str | None = None,
    ) -> str:
        """返回模型回复的纯文本；stage 仅用于用量归因。"""
        raise NotImplementedError

    def complete_json(
        self,
        messages: Messages,
        *,
        tier: str = "strong",
        max_tokens: int | None = None,
        stage: str | None = None,
    ) -> Any:
        """要求 JSON 输出并解析（wenyi base.py `complete_json`）。"""
        text = self.complete(messages, tier=tier, json_mode=True,
                             max_tokens=max_tokens, stage=stage)
        return parse_json_loose(text)


def base_request_kwargs(model: str, messages: Messages, *, json_mode: bool) -> dict[str, Any]:
    """构造 Chat Completions 基础参数，并为 JSON 模式补充明确指令（wenyi `base_request_kwargs`）。

    JSON 模式双保险：system 与最后一条 user 都注入 `Output must be valid json.`
    （有些中转/网关只校验 user 角色内容）。
    """
    request_messages = [dict(message) for message in messages]
    if json_mode:
        for message in request_messages:
            if message.get("role") == "system":
                message["content"] = f"{message.get('content', '')}\n\n{_JSON_MODE_INSTRUCTION}"
                break
        else:
            request_messages.insert(0, {"role": "system", "content": _JSON_MODE_INSTRUCTION})
        for message in reversed(request_messages):
            if message.get("role") == "user":
                content = str(message.get("content", ""))
                if "json" not in content.lower():
                    message["content"] = f"{content}\n\n{_JSON_MODE_INSTRUCTION}"
                break
    kwargs: dict[str, Any] = {
        "model": model,
        "messages": request_messages,
        "stream": False,
    }
    if json_mode:
        kwargs["response_format"] = {"type": "json_object"}
    return kwargs


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    """递归合并 provider 请求体；用户值优先（wenyi `deep_merge`）。"""
    merged = dict(base)
    for key, value in override.items():
        current = merged.get(key)
        if isinstance(current, dict) and isinstance(value, dict):
            merged[key] = deep_merge(current, value)
        else:
            merged[key] = value
    return merged


def normalize_openai_usage(usage: Any) -> UsageSample | None:
    """把 OpenAI 风格的嵌套缓存明细转换成统一用量（wenyi `normalize_openai_usage`）。"""
    if usage is None:
        return None
    details = read_usage_value(usage, "prompt_tokens_details")
    cached_value = read_usage_value(details, "cached_tokens") if isinstance(details, dict) else None
    if cached_value is None:
        cache_hit_tokens = 0
        cache_miss_tokens = 0
    else:
        cache_hit_tokens = read_usage_int(details, "cached_tokens")
        cache_miss_tokens = max(0, read_usage_int(usage, "prompt_tokens") - cache_hit_tokens)
    return make_usage_sample(usage, cache_hit_tokens=cache_hit_tokens,
                             cache_miss_tokens=cache_miss_tokens)


def normalize_deepseek_usage(usage: Any) -> UsageSample | None:
    """把 DeepSeek 顶层缓存字段转换成统一用量（wenyi `normalize_deepseek_usage`）。"""
    if usage is None:
        return None
    return make_usage_sample(
        usage,
        cache_hit_tokens=read_usage_int(usage, "prompt_cache_hit_tokens"),
        cache_miss_tokens=read_usage_int(usage, "prompt_cache_miss_tokens"),
    )


def _normalize_usage_for_provider(provider: str, usage: Any) -> UsageSample | None:
    """按 provider 选用量归一化方言。"""
    if provider == "deepseek":
        return normalize_deepseek_usage(usage)
    return normalize_openai_usage(usage)


class OpenAICompatibleClient(LLMClient):
    """所有 OpenAI Chat Completions 兼容 provider 的共用客户端（wenyi `OpenAICompatibleBaseClient` 语义）。

    传输用 `urllib`（零第三方依赖）；重试用 `retry_with_backoff`。
    """

    def __init__(
        self,
        cfg: dict[str, Any],
        *,
        provider_name: str,
        default_base_url: str | None,
        default_api_key_env: str | None,
        tiers: dict[str, dict[str, Any]],
        requires_api_key: bool,
    ) -> None:
        super().__init__()
        self.cfg = cfg
        self.provider_name = provider_name
        self.base_url = (cfg.get("base_url") or "").strip() or (default_base_url or "")
        self.api_key_env = cfg.get("api_key_env") or default_api_key_env or ""
        self.api_key = str(cfg.get("api_key") or "").strip()
        self.tiers = tiers
        self.requires_api_key = requires_api_key
        self.timeout = int(cfg.get("timeout") or 120)
        self.max_retries = int(cfg.get("max_retries") or 4)
        self.reasoning_style = str(cfg.get("reasoning_style") or "deepseek")
        if not self.base_url:
            raise ValueError(f"{provider_name} provider 需要配置 llm.base_url")

    # ── 凭据校验 ──

    def validate_credentials(self) -> None:
        """在发起任何模型流程前报告缺失的 API Key（wenyi `validate_credentials` 语义）。"""
        if not self.requires_api_key:
            return
        if self.api_key:
            return
        if self.api_key_env:
            env_key = os.environ.get(self.api_key_env, "").strip()
            if env_key:
                return
        raise ValueError(
            f"{self.provider_name} provider 需要配置 llm.api_key"
            + (f"（或环境变量 {self.api_key_env}）" if self.api_key_env else "")
        )

    # ── 请求方言（provider 子类覆写）──

    def _build_request_kwargs(self, tier_config: dict[str, Any], messages: Messages,
                              *, json_mode: bool, max_tokens: int | None) -> dict[str, Any]:
        """把通用调用转换成 provider 的请求方言。基类按 `reasoning_style` 分派。"""
        style = self.reasoning_style
        options = tier_config.get("options") or {}
        thinking = bool(options.get("thinking", True))
        effort = str(options.get("reasoning_effort") or "high")
        overrides = options.get("request_overrides") or {}

        kwargs = base_request_kwargs(tier_config.get("model", ""), messages, json_mode=json_mode)
        extra: dict[str, Any] = {}
        if style == "deepseek":
            extra["thinking"] = {"type": "enabled" if thinking else "disabled"}
            if thinking:
                kwargs["reasoning_effort"] = effort
            if max_tokens is not None:
                kwargs["max_tokens"] = max(max_tokens, 4096) if thinking else max_tokens
        elif style == "openai":
            kwargs["reasoning_effort"] = effort if thinking else "none"
            if max_tokens is not None:
                kwargs["max_completion_tokens"] = max_tokens
        elif style == "openrouter":
            extra["reasoning"] = {"effort": effort} if thinking else {"enabled": False}
            if max_tokens is not None:
                kwargs["max_tokens"] = max_tokens
        else:  # none / 兼容模式（ollama/vllm/gemini）
            if max_tokens is not None:
                kwargs["max_tokens"] = max_tokens
        if extra:
            kwargs["extra_body"] = extra
        if overrides:
            kwargs = deep_merge(kwargs, overrides)
        return kwargs

    def _normalize_usage(self, usage: Any) -> UsageSample | None:
        """标准 OpenAI 兼容响应默认使用嵌套缓存明细（wenyi `_normalize_usage`）。"""
        return normalize_openai_usage(usage)

    # ── 传输 ──

    def _post(self, kwargs: dict[str, Any]) -> dict[str, Any]:
        """向 `{base_url}/chat/completions` POST 一次，返回解析后的响应 JSON。

        异常语义：
        - 网络错误 / HTTP 429 / 5xx → 抛 `_RetryableError`（可重试）；
        - HTTP 4xx（除 429）→ 抛 `_FatalHTTPError`（不重试，直接退 6）。
        """
        base = self.base_url.rstrip("/")
        url = base if base.endswith("/chat/completions") else base + "/chat/completions"
        payload = json.dumps(kwargs, ensure_ascii=False).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        key = self.api_key or (os.environ.get(self.api_key_env, "") if self.api_key_env else "")
        if key:
            headers["Authorization"] = f"Bearer {key}"
        req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read().decode("utf-8")
                body = json.loads(raw) if raw.strip() else {}
                if not isinstance(body, dict):
                    raise _RetryableError(f"响应不是 JSON 对象：{raw[:200]!r}")
                return body
        except urllib.error.HTTPError as error:
            code = error.code
            detail = error.read().decode("utf-8", errors="replace")[:300]
            if code == 429 or code >= 500:
                raise _RetryableError(f"HTTP {code}: {detail}") from error
            raise _FatalHTTPError(f"HTTP {code}: {detail}") from error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise _RetryableError(f"网络错误: {error}") from error
        except json.JSONDecodeError as error:
            raise _RetryableError(f"响应 JSON 解析失败: {error}") from error

    def complete(self, messages: Messages, *, tier: str = "strong",
                 json_mode: bool = False, max_tokens: int | None = None,
                 stage: str | None = None) -> str:
        """按指定档位调用兼容接口，自动重试并记录标准化用量（wenyi `complete` 语义）。"""
        self.validate_credentials()
        tier_config = resolve_tier(self.tiers, tier)
        kwargs = self._build_request_kwargs(tier_config, messages,
                                            json_mode=json_mode, max_tokens=max_tokens)
        retry_if = lambda error: isinstance(error, _RetryableError)  # noqa: E731

        def _call() -> str:
            body = self._post(kwargs)
            usage = body.get("usage")
            sample = self._normalize_usage(usage)
            self.usage.record(tier, sample, stage)
            try:
                return body["choices"][0]["message"]["content"] or ""
            except (KeyError, IndexError, TypeError) as error:
                raise _RetryableError(f"响应缺少 choices[0].message.content: {str(body)[:200]}") from error

        result, attempts = retry_with_backoff(
            _call,
            attempts=self.max_retries + 1,
            retry_if=retry_if,
        )
        return result


class _RetryableError(Exception):
    """可重试的临时错误（网络 / 429 / 5xx / 响应解析失败）。"""


class _FatalHTTPError(Exception):
    """不可重试的 HTTP 4xx（除 429）。"""


# ════════════════════════════════════════════════════════════════════════
# 具体 provider（§4.5 方言，照搬 wenyi providers/*.py）
# ════════════════════════════════════════════════════════════════════════

class DeepSeekClient(OpenAICompatibleClient):
    """DeepSeek 原生 OpenAI 兼容接口（wenyi providers/deepseek.py）。

    方言：`extra_body.thinking={type:enabled/disabled}` + `reasoning_effort`（thinking 时）；
    `max_tokens = max(max_tokens, 4096)`（thinking 时）。
    """

    def __init__(self, cfg: dict[str, Any]) -> None:
        tiers = resolve_provider_tiers(cfg.get("tiers") or {},
                                       defaults=DEEPSEEK_DEFAULT_TIERS)
        super().__init__(
            cfg,
            provider_name="DeepSeek",
            default_base_url=PROVIDER_DEFAULTS["deepseek"]["base_url"],
            default_api_key_env=PROVIDER_DEFAULTS["deepseek"]["api_key_env"],
            tiers=tiers,
            requires_api_key=PROVIDER_DEFAULTS["deepseek"]["requires_api_key"],
        )
        self.reasoning_style = "deepseek"

    def _normalize_usage(self, usage: Any) -> UsageSample | None:
        """读取 DeepSeek 顶层缓存字段并转换为统一用量（wenyi deepseek.py）。"""
        return normalize_deepseek_usage(usage)


class OllamaClient(OpenAICompatibleClient):
    """Ollama 本地 OpenAI 兼容接口（wenyi providers/ollama.py，默认免密）。"""

    def __init__(self, cfg: dict[str, Any]) -> None:
        tiers = resolve_provider_tiers(cfg.get("tiers") or {}, defaults={})
        super().__init__(
            cfg,
            provider_name="Ollama",
            default_base_url=PROVIDER_DEFAULTS["ollama"]["base_url"],
            default_api_key_env=None,
            tiers=tiers,
            requires_api_key=False,
        )
        self.reasoning_style = "none"


class OpenAICompatibleGenericClient(OpenAICompatibleClient):
    """`openai-compatible` / `openai` / `openrouter` / `vllm` / `gemini` 的通用实现。

    `reasoning_style` 由配置决定（none/deepseek/openai/openrouter）；
    P0 点亮 `openai-compatible`，其余以本类骨架运行（validate 可过）。
    """

    def __init__(self, cfg: dict[str, Any], *, provider: str) -> None:
        defaults = PROVIDER_DEFAULTS.get(provider, {})
        tiers = resolve_provider_tiers(cfg.get("tiers") or {}, defaults={})
        requires = bool(defaults.get("requires_api_key"))
        if provider in ("openai-compatible", "vllm"):
            # 可配：显式给了 api_key/api_key_env 才算需要
            requires = bool((cfg.get("api_key") or "").strip() or (cfg.get("api_key_env") or "").strip())
        super().__init__(
            cfg,
            provider_name=provider,
            default_base_url=defaults.get("base_url") or None,
            default_api_key_env=defaults.get("api_key_env") or None,
            tiers=tiers,
            requires_api_key=requires,
        )
        # 推理方言由 cfg.reasoning_style 决定（默认 deepseek）
        self.reasoning_style = str(cfg.get("reasoning_style") or "deepseek")


class FakeClient(LLMClient):
    """可编程的离线 provider（DESIGN §4.7）。

    `llm.fake_script` 指向 JSONL 规则文件（每行一个响应规则）：
    ```jsonl
    {"when":{"stage":"S4_pre_extract"},"respond":{"terms":[...]}}
    {"when":{"stage":"S4_translate","chunk":1},"respond":{"text":"..."}}
    {"when":{"stage":"ping"},"respond":{"text":"pong"}}
    ```
    规则匹配：`stage` 精确 + `chunk` 可选 + `tier` 可选；未命中 → 默认 `[]`（json_mode）或 `""`。
    fake 无网络请求、不计费，但照常走完整调用管线（含 usage 归一化：返回固定 usage 样例）。
    """

    def __init__(self, cfg: dict[str, Any]) -> None:
        super().__init__()
        self.cfg = cfg
        self.script: list[dict[str, Any]] = []
        self.calls: list[dict[str, Any]] = []
        # 与其它 provider 一致：显式给出 tiers 时必须含 strong（T06 判据 4）。
        tiers = cfg.get("tiers")
        if isinstance(tiers, dict) and "strong" not in tiers:
            raise ValueError("配置缺少 llm.tiers.strong.model")
        script_path = str(cfg.get("fake_script") or "")
        if script_path:
            self.load_script(script_path)

    def load_script(self, path: str) -> None:
        """从 JSONL 文件加载规则；忽略畸形行（只追加日志容忍尾部半行）。"""
        rules: list[dict[str, Any]] = []
        try:
            with open(path, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rule = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(rule, dict):
                        rules.append(rule)
        except OSError:
            rules = []
        self.script = rules

    def _match(self, stage: str | None, chunk: int | None, tier: str | None) -> dict[str, Any] | None:
        """按 when 条件精确匹配第一条规则；无 when 的规则兜底命中。"""
        for rule in self.script:
            when = rule.get("when") or {}
            if when.get("stage") is not None and when.get("stage") != stage:
                continue
            if when.get("chunk") is not None and when.get("chunk") != chunk:
                continue
            if when.get("tier") is not None and when.get("tier") != tier:
                continue
            return rule
        return None

    def validate_credentials(self) -> None:
        """fake 免检。"""

    def complete(self, messages: Messages, *, tier: str = "strong",
                 json_mode: bool = False, max_tokens: int | None = None,
                 stage: str | None = None) -> str:
        """记录调用并返回脚本命中的响应；未命中返回 `[]`（json_mode）或 `""`。"""
        self.calls.append({
            "messages": [dict(message) for message in messages],
            "tier": tier,
            "json_mode": json_mode,
            "max_tokens": max_tokens,
            "stage": stage,
        })
        rule = self._match(stage, None, tier)
        respond = (rule or {}).get("respond") or {}
        # 固定 usage 样例：QA 全流程离线可跑（DESIGN §4.7「Fake 返回固定 usage 样例」）。
        self.usage.record(tier, UsageSample(prompt_tokens=10, completion_tokens=5,
                                            total_tokens=15), stage)
        if "text" in respond:
            return str(respond["text"])
        # json_mode：把 respond 本身当作 JSON 值返回；未命中 → []
        return json.dumps(respond, ensure_ascii=False) if respond else ("[]" if json_mode else "")


# ════════════════════════════════════════════════════════════════════════
# 工厂（照搬 wenyi factory.py）
# ════════════════════════════════════════════════════════════════════════

def build_client(cfg: dict[str, Any]) -> LLMClient:
    """根据 `llm.provider` 构造对应客户端（wenyi factory.py）。

    `cfg` 即 `config.json.llm` 块（含可选 `api_key`、`fake_script`）。
    """
    provider = str(cfg.get("provider") or "deepseek").strip().lower().replace("_", "-")
    if provider == "deepseek":
        return DeepSeekClient(cfg)
    if provider == "ollama":
        return OllamaClient(cfg)
    if provider == "fake":
        return FakeClient(cfg)
    if provider in ("openai", "openrouter", "openai-compatible", "vllm", "gemini"):
        return OpenAICompatibleGenericClient(cfg, provider=provider)
    raise ValueError(
        f"未知 provider：{provider}"
        "（支持 deepseek / openai / openrouter / openai-compatible / "
        "ollama / vllm / gemini / fake）"
    )
