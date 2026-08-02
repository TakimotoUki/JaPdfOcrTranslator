#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""llm_tool.py — LLM 调用 CLI（DESIGN-v3.3-llm §4，T06 新地基）

五子命令：
- `complete`      纯文本补全（重试 + usage 落盘 + 事件）
- `complete-json` JSON 模式补全（宽松解析，`repaired` 标记）
- `validate`      凭据/配置校验（不发网络请求；不通过退 5）
- `ping`          最小连通性测试（设置页「测试连接」按钮）
- `usage`         只读 usage.json

零第三方依赖（urllib + 手写退避，见 `_llm_common`）。api_key 只从
`--config-file`（0600 文件）或环境变量读取，**绝不出现于 argv / 日志 / events**。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    EXIT_CHECK, EXIT_INPUT, EXIT_OK, EXIT_STATE, EXIT_USAGE,
    append_event, die, emit_json, ensure_state, file_lock, install_excepthook,
    now, read_json, write_json_atomic,
    make_parser,
    UsageErrorParser,)
from _llm_common import (  # noqa: E402
    EXIT_RETRY, KNOWN_PROVIDERS, RetryExhausted, build_client,
    parse_json_result, resolve_tier,
)

#: usage.json 的 schema 版本。
USAGE_SCHEMA_VERSION = 1


# ════════════════════════════════════════════════════════════════════════
# 配置加载
# ════════════════════════════════════════════════════════════════════════

def load_llm_config(args: argparse.Namespace) -> dict[str, Any]:
    """加载 `llm` 配置块（§3.2）。`--config-file` 与 `--config-json` 二选一。"""
    if bool(args.config_file) == bool(args.config_json):
        die(EXIT_USAGE, "--config-file 与 --config-json 必须二选一。")
    cfg: Any = None
    if args.config_file:
        cfg = read_json(args.config_file)
        if cfg is None:
            die(EXIT_INPUT, f"无法读取或解析 LLM 配置文件：{args.config_file}")
    else:
        try:
            cfg = json.loads(args.config_json)
        except json.JSONDecodeError as error:
            die(EXIT_INPUT, f"--config-json 不是合法 JSON：{error}")
    if not isinstance(cfg, dict):
        die(EXIT_INPUT, "LLM 配置必须是 JSON 对象。")
    # --api-key-env 覆盖配置里的 api_key_env（不出现于 argv 的 key 本身）
    if getattr(args, "api_key_env", None):
        cfg = dict(cfg)
        cfg["api_key_env"] = args.api_key_env
    provider = str(cfg.get("provider") or "deepseek").strip().lower().replace("_", "-")
    if provider not in KNOWN_PROVIDERS:
        die(EXIT_CHECK, f"未知 provider：{provider}（支持 {'/'.join(KNOWN_PROVIDERS)}）")
    return cfg


def _build(args: argparse.Namespace) -> Any:
    """加载配置并构造客户端；配置错误按 §4.0 退 5。"""
    cfg = load_llm_config(args)
    try:
        client = build_client(cfg)
    except ValueError as error:
        die(EXIT_CHECK, f"LLM 配置校验失败：{error}")
    return client


def _provider_name(client: Any) -> str:
    """取 provider 名（事件/输出用）；fake 无 provider_name 属性 → "fake"。"""
    name = getattr(client, "provider_name", "")
    if name:
        return str(name)
    return "fake" if client.__class__.__name__ == "FakeClient" else ""


def _resolved_model(client: Any, tier: str) -> str:
    """取档位回退解析后的 model（事件里用；fake 无 tiers → 空串）。"""
    tiers = getattr(client, "tiers", None)
    if not isinstance(tiers, dict) or not tiers:
        return ""
    try:
        return str(resolve_tier(tiers, tier).get("model") or "")
    except KeyError:
        return ""


# ════════════════════════════════════════════════════════════════════════
# usage.json 落盘（usage.lock 内 读-合并-原子写回，§3.3 / wenyi merge）
# ════════════════════════════════════════════════════════════════════════

def persist_usage(state: str, tracker: Any) -> dict[str, Any]:
    """在 `usage.lock` 内把 tracker 增量合并进 usage.json 并原子写回，返回写后的汇总。"""
    usage_path = os.path.join(state, "usage.json")
    with file_lock(state, "usage"):
        tracker.merge_from_file(usage_path)
        summary = tracker.summary()
        disk = {
            "schema_version": USAGE_SCHEMA_VERSION,
            "updated_at": round(now(), 3),
            "totals": summary["totals"],
            "by_tier": summary["by_tier"],
            "by_stage": summary["by_stage"],
        }
        write_json_atomic(usage_path, disk)
    return summary


def read_usage(state: str) -> dict[str, Any]:
    """只读 usage.json；缺失退 4（§4.4 `usage` 子命令）。"""
    usage_path = os.path.join(state, "usage.json")
    data = read_json(usage_path)
    if not isinstance(data, dict):
        die(EXIT_STATE, f"usage.json 不存在或损坏：{usage_path}\n  请先运行一次 llm_tool.py complete。")
    return data


# ════════════════════════════════════════════════════════════════════════
# 事件（§3.4：llm_call / llm_failed；api_key 绝不入事件）
# ════════════════════════════════════════════════════════════════════════

def emit_llm_call(state: str, *, provider: str, model: str, tier: str, stage: str | None,
                  json_mode: bool, sample: Any, repaired: bool) -> None:
    append_event(state, "llm_call", stage=stage, actor="script", data={
        "provider": provider,
        "model": model,
        "tier": tier,
        "stage": stage,
        "json_mode": json_mode,
        "prompt_tokens": int(getattr(sample, "prompt_tokens", 0) or 0),
        "completion_tokens": int(getattr(sample, "completion_tokens", 0) or 0),
        "total_tokens": int(getattr(sample, "total_tokens", 0) or 0),
        "cache_hit_tokens": int(getattr(sample, "cache_hit_tokens", 0) or 0),
        "cache_miss_tokens": int(getattr(sample, "cache_miss_tokens", 0) or 0),
        "repaired": repaired,
    })


def emit_llm_failed(state: str, *, provider: str, tier: str, stage: str | None,
                    attempts: int, error_type: str, error: str) -> None:
    append_event(state, "llm_failed", stage=stage, actor="script", data={
        "provider": provider,
        "tier": tier,
        "stage": stage,
        "attempts": attempts,
        "error_type": error_type,
        "error": error[:500],
    })


# ════════════════════════════════════════════════════════════════════════
# 消息构造
# ════════════════════════════════════════════════════════════════════════

def build_messages(args: argparse.Namespace) -> list[dict[str, str]]:
    """`--system/--user` 或 `--messages-json` 构造消息数组。"""
    if args.messages_json is not None:
        try:
            messages = json.loads(args.messages_json)
        except json.JSONDecodeError as error:
            die(EXIT_INPUT, f"--messages-json 不是合法 JSON：{error}")
        if not isinstance(messages, list) or not all(isinstance(m, dict) for m in messages):
            die(EXIT_INPUT, "--messages-json 必须是消息对象数组。")
        return messages
    user = (args.user or "").strip()
    if not user:
        die(EXIT_USAGE, "必须给出 --user <text> 或 --messages-json '<[...]>'。")
    messages: list[dict[str, str]] = []
    if args.system:
        messages.append({"role": "system", "content": args.system})
    messages.append({"role": "user", "content": user})
    return messages


# ════════════════════════════════════════════════════════════════════════
# 子命令
# ════════════════════════════════════════════════════════════════════════

def cmd_complete(args: argparse.Namespace) -> int:
    """§4.1 —— 纯文本补全。"""
    state = ensure_state(args.state)
    client = _build(args)
    messages = build_messages(args)
    provider = _provider_name(client)
    model = _resolved_model(client, args.tier)
    stage = args.stage

    try:
        text = client.complete(
            messages,
            tier=args.tier,
            json_mode=args.json_mode,
            max_tokens=args.max_tokens,
            stage=stage,
        )
    except RetryExhausted as error:
        emit_llm_failed(state, provider=provider,
                        tier=args.tier, stage=stage,
                        attempts=error.attempts,
                        error_type=type(error.last_error).__name__,
                        error=str(error.last_error))
        die(EXIT_RETRY, f"LLM 调用重试耗尽（{error.attempts} 次）：{error.last_error}")

    summary = persist_usage(state, client.usage)
    if not args.no_event:
        emit_llm_call(state, provider=provider,
                      model=model, tier=args.tier, stage=stage,
                      json_mode=args.json_mode,
                      sample=summary["totals"], repaired=False)

    emit_json({
        "ok": True,
        "provider": provider,
        "model": model,
        "tier": args.tier,
        "stage": stage,
        "text": text,
        "usage": summary["totals"],
        "totals": summary["totals"],
    })
    return EXIT_OK


def cmd_complete_json(args: argparse.Namespace) -> int:
    """§4.2 —— JSON 模式补全 + 宽松解析。"""
    state = ensure_state(args.state)
    client = _build(args)
    messages = build_messages(args)
    stage = args.stage
    model = _resolved_model(client, args.tier)

    from _llm_common import _RetryableError, retry_with_backoff

    def _call() -> tuple[str, Any, bool]:
        text = client.complete(
            messages,
            tier=args.tier,
            json_mode=True,
            max_tokens=args.max_tokens,
            stage=stage,
        )
        try:
            result = parse_json_result(text)
        except ValueError as error:
            raise _RetryableError(str(error)) from error
        return text, result.value, result.repaired

    try:
        (text, value, repaired), _attempts = retry_with_backoff(
            _call,
            attempts=int(getattr(client, "max_retries", 4)) + 1,
            retry_if=lambda error: isinstance(error, _RetryableError),
        )
    except RetryExhausted as error:
        emit_llm_failed(state, provider=str(getattr(client, "provider_name", "")),
                        tier=args.tier, stage=stage,
                        attempts=error.attempts,
                        error_type=type(error.last_error).__name__,
                        error=str(error.last_error))
        die(EXIT_RETRY, f"JSON 解析重试耗尽（{error.attempts} 次）：{error.last_error}")

    summary = persist_usage(state, client.usage)
    emit_llm_call(state, provider=str(getattr(client, "provider_name", "")),
                  model=model, tier=args.tier, stage=stage,
                  json_mode=True, sample=summary["totals"], repaired=repaired)

    emit_json({
        "ok": True,
        "repaired": repaired,
        "value": value,
        "text": text,
        "provider": str(getattr(client, "provider_name", "")),
        "model": model,
        "tier": args.tier,
        "stage": stage,
        "usage": summary["totals"],
        "totals": summary["totals"],
    })
    return EXIT_OK




def cmd_validate(args: argparse.Namespace) -> int:
    """§4.3 —— 凭据/配置校验（不发网络请求；不通过退 5）。"""
    state = ensure_state(args.state)
    cfg = load_llm_config(args)
    provider = str(cfg.get("provider") or "deepseek").strip().lower().replace("_", "-")
    try:
        client = build_client(cfg)
        client.validate_credentials()
    except ValueError as error:
        die(EXIT_CHECK, f"凭据/配置校验未通过：{error}")
    tiers = sorted((cfg.get("tiers") or {}).keys()) or ["strong"]
    has_key = bool((cfg.get("api_key") or "").strip()
                   or (cfg.get("api_key_env") and os.environ.get(cfg["api_key_env"], "").strip()))
    emit_json({
        "ok": True,
        "provider": provider,
        "requires_api_key": bool(getattr(client, "requires_api_key", False)),
        "has_api_key": has_key,
        "tiers": tiers,
    })
    return EXIT_OK


def cmd_ping(args: argparse.Namespace) -> int:
    """§4.4 —— 最小连通性测试（`max_tokens=8`，stage="ping"）。"""
    state = ensure_state(args.state)
    client = _build(args)
    try:
        text = client.complete(
            [{"role": "user", "content": "ping"}],
            tier="cheap",
            json_mode=False,
            max_tokens=8,
            stage="ping",
        )
    except RetryExhausted as error:
        emit_llm_failed(state, provider=str(getattr(client, "provider_name", "")),
                        tier="cheap", stage="ping",
                        attempts=error.attempts,
                        error_type=type(error.last_error).__name__,
                        error=str(error.last_error))
        die(EXIT_RETRY, f"ping 失败（{error.attempts} 次）：{error.last_error}")
    summary = persist_usage(state, client.usage)
    emit_llm_call(state, provider=str(getattr(client, "provider_name", "")),
                  model=_resolved_model(client, "cheap"), tier="cheap", stage="ping",
                  json_mode=False, sample=summary["totals"], repaired=False)
    if args.format == "text":
        sys.stdout.write(text.rstrip("\n") + "\n")
        return EXIT_OK
    emit_json({
        "ok": True,
        "provider": str(getattr(client, "provider_name", "")),
        "text": text,
        "usage": summary["totals"],
        "totals": summary["totals"],
    })
    return EXIT_OK


def cmd_usage(args: argparse.Namespace) -> int:
    """§4.4 —— 只读 usage.json（缺文件退 4）。"""
    state = ensure_state(args.state)
    data = read_usage(state)
    if args.format == "md":
        totals = data.get("totals") or {}
        lines = [
            "【LLM 用量】",
            f"- 调用次数：{totals.get('calls', 0)}",
            f"- tokens：{totals.get('total_tokens', 0)}"
            f"（prompt {totals.get('prompt_tokens', 0)} · completion {totals.get('completion_tokens', 0)}）",
            f"- 缓存命中：{totals.get('cache_hit_tokens', 0)}"
            f"（{totals.get('cache_hit_rate', 0.0)}）",
            "",
        ]
        sys.stdout.write("\n".join(lines))
        return EXIT_OK
    emit_json(data)
    return EXIT_OK


# ════════════════════════════════════════════════════════════════════════
# 入口
# ════════════════════════════════════════════════════════════════════════

def build_parser() -> argparse.ArgumentParser:
    ap = make_parser(
        prog="llm_tool.py",
        description="LLM 调用 CLI（DESIGN-v3.3-llm §4；零第三方依赖）")
    sub = ap.add_subparsers(dest="cmd", required=True, parser_class=UsageErrorParser)

    def add_common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--state", required=True, help="<outDir>/state 目录")
        cfg_group = p.add_mutually_exclusive_group(required=True)
        cfg_group.add_argument("--config-file", default=None,
                               help="LLM 配置 JSON 文件路径（api_key 走此 0600 文件，不出现于 argv）")
        cfg_group.add_argument("--config-json", default=None,
                               help="LLM 配置 JSON 文本（勿含 api_key）")
        p.add_argument("--api-key-env", default=None,
                       help="API key 环境变量名（覆盖配置里的 api_key_env）")

    p = sub.add_parser("complete", help="纯文本补全（§4.1）")
    add_common(p)
    p.add_argument("--tier", choices=("strong", "cheap", "fast"), default="strong")
    p.add_argument("--stage", default=None)
    p.add_argument("--max-tokens", dest="max_tokens", type=int, default=None)
    p.add_argument("--json-mode", dest="json_mode", action="store_true")
    p.add_argument("--no-event", dest="no_event", action="store_true")
    p.add_argument("--system", default=None)
    p.add_argument("--user", default=None)
    p.add_argument("--messages-json", dest="messages_json", default=None)
    p.set_defaults(func=cmd_complete)

    p = sub.add_parser("complete-json", help="JSON 模式补全 + 宽松解析（§4.2）")
    add_common(p)
    p.add_argument("--tier", choices=("strong", "cheap", "fast"), default="strong")
    p.add_argument("--stage", default=None)
    p.add_argument("--max-tokens", dest="max_tokens", type=int, default=None)
    p.add_argument("--system", default=None)
    p.add_argument("--user", default=None)
    p.add_argument("--messages-json", dest="messages_json", default=None)
    p.set_defaults(func=cmd_complete_json)

    p = sub.add_parser("validate", help="凭据/配置校验（§4.3，不发网络请求）")
    add_common(p)
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("ping", help="最小连通性测试（§4.4）")
    add_common(p)
    p.add_argument("--format", choices=("json", "text"), default="json")
    p.set_defaults(func=cmd_ping)

    p = sub.add_parser("usage", help="只读 usage.json（§4.4）")
    p.add_argument("--state", required=True)
    p.add_argument("--format", choices=("json", "md"), default="json")
    p.set_defaults(func=cmd_usage)

    return ap


def main(argv: list[str] | None = None) -> int:
    install_excepthook("llm_tool.py")
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
