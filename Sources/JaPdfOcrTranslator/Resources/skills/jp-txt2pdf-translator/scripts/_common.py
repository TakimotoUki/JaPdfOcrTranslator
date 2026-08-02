#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""_common.py — v3.3 skill 脚本共用底座（零第三方依赖）

本模块是 `state/` 契约层的 Python 侧地基，被全部 12 个入口脚本 import。
契约出处：DESIGN-v3.3 §3.4（事件）/ §4.0（退出码与原子性）/ §4.3（匹配算法）
/ §10.4（事件写入）/ §10.5（锁与原子写）/ §10.6（编码与文本）。

设计要点
--------
1. **只用标准库**：argparse/json/os/sys/re/time/hashlib/unicodedata/fcntl/
   glob/shutil/csv/dataclasses/typing/contextlib。任何 `pip install` 都可能
   在翻译进行到一半时才暴露失败，代价极高（DESIGN §9.1）。
2. **退出码语义全体脚本统一**：业务性拒绝（policy/lock 拒绝）退 0 并在 JSON
   里报数；只有真正的错误才非零退出（DESIGN §4.0 / §10.2）。
3. **绝不把 traceback 打到 stdout**：stdout 是机器可读的 JSON 通道，污染它会
   让 Swift/Agent 的 JSON 解析直接失败。人类可读信息一律走 stderr。
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import sys
import time
import unicodedata
from typing import Any, Iterable, Iterator, NoReturn

# ── 版本印记（DESIGN §1.5 B2：三重版本印记之二）────────────────────────────
SKILL_VERSION = "3.3.0"
SCHEMA_VERSION = 1

# ── 退出码（DESIGN §4.0，全体脚本统一）──────────────────────────────────────
EXIT_OK = 0       # 成功（含「部分条目被拒绝」这类业务结果）
EXIT_USAGE = 1    # 用法 / 参数错误
EXIT_IO = 2       # IO / 锁错误（锁超时 30s）
EXIT_INPUT = 3    # 输入 JSON 畸形
EXIT_STATE = 4    # 状态未初始化 / 目标不存在
EXIT_CHECK = 5    # 检查未通过


class UsageErrorParser(argparse.ArgumentParser):
    """argparse 用法错误统一退 `EXIT_USAGE`（1），而非 argparse 默认的 2。

    DESIGN §4.0：`1` = 用法错误、`2` = IO/锁错误。argparse 默认对 usage error
    走 `exit(2)`，会与 IO 错误混淆；Swift 侧 `GlossaryToolClient` / `StateToolClient`
    会把退出码 2 映射为 `.state`（IO/锁失败），从而误报。T10 修复：所有脚本的
    argparse 一律用本类（或 `make_parser`），子命令 parser 传 `parser_class=UsageErrorParser`。
    """

    def error(self, message: str) -> NoReturn:
        self.print_usage(sys.stderr)
        sys.stderr.write(f"{self.prog}: error: {message}\n")
        sys.exit(EXIT_USAGE)


def make_parser(*args: Any, **kwargs: Any) -> argparse.ArgumentParser:
    """构造一个用法错误统一退 1 的 argparse parser（BUG-02 修复的统一入口）。"""
    return UsageErrorParser(*args, **kwargs)

LOCK_TIMEOUT = 30.0

# ── 术语类型（DESIGN §3.6）──────────────────────────────────────────────────
TERM_TYPES = (
    "人物", "地名", "组织", "术语", "招式", "物品",
    "称谓", "敬称", "口癖", "固定表达", "其他",
)
DEFAULT_TERM_TYPE = "术语"
FALLBACK_TERM_TYPE = "其他"

#: 这四类**只按 `source` 匹配，忽略 `aliases`**（照搬 wenyi `store.py`）。
#: 理由：称谓/敬称/口癖/固定表达是带语气或场景的派生写法，若让其裸名 alias
#: 参与匹配，会把派生译法错误地注入到普通称呼处。
SOURCE_ONLY_TYPES = frozenset({"称谓", "敬称", "口癖", "固定表达"})

#: 需要词边界保护的书写系统（空格分词文字）。
_WORD_BOUNDARY_SCRIPTS = ("LATIN", "GREEK", "CYRILLIC")

#: 句末 / 收束符号，`split_text.py` 与 `check_boundaries.py` 共用。
TERMINAL_CHARS = set("。．.！？!?…）)」』】")


# ══════════════════════════════════════════════════════════════════════════
# 进程出口
# ══════════════════════════════════════════════════════════════════════════

def die(code: int, msg: str) -> NoReturn:
    """把人类可读的诊断写到 stderr 并以指定退出码结束进程。

    绝不写 stdout：stdout 被约定为单个 JSON 对象的通道（DESIGN §4.0）。
    """
    sys.stderr.write(msg.rstrip("\n") + "\n")
    sys.stderr.flush()
    raise SystemExit(code)


def emit_json(obj: Any) -> None:
    """把结果对象作为**单个 JSON 对象**打印到 stdout（无多余输出）。"""
    sys.stdout.write(json.dumps(obj, ensure_ascii=False))
    sys.stdout.write("\n")
    sys.stdout.flush()


def now() -> float:
    """当前 epoch 秒。集中一处便于测试替换。"""
    return time.time()


# ══════════════════════════════════════════════════════════════════════════
# 文件锁与原子写（DESIGN §10.5）
# ══════════════════════════════════════════════════════════════════════════

#: 本进程已持有的锁名。`flock` 的锁属于「打开文件描述」，同一进程用两个 fd
#: 抢同一把锁会自我死锁，因此这里做可重入保护：已持有则直接放行。
_HELD_LOCKS: set[str] = set()


def locks_dir(state_dir: str) -> str:
    """返回 `<state>/.locks/` 并确保其存在。锁文件永不删除（§10.5 L1）。"""
    d = os.path.join(state_dir, ".locks")
    os.makedirs(d, exist_ok=True)
    return d


@contextlib.contextmanager
def file_lock(state_dir: str, name: str = "glossary",
              timeout: float = LOCK_TIMEOUT) -> Iterator[None]:
    """在 `<state>/.locks/<name>.lock` 上持有 `LOCK_EX`。

    用 `LOCK_EX | LOCK_NB` 轮询而非阻塞式 `LOCK_EX`，以便实现真正的超时语义。
    Swift 侧 `FileLock.withExclusiveLock` 用同一路径同一系统调用，跨进程互斥
    有效（§10.5 L4）。

    Args:
        state_dir: state 目录绝对路径。
        name: 锁名，取值 `glossary` 或 `state`。
        timeout: 最长等待秒数，超时以 `EXIT_IO` 退出。
    """
    key = os.path.abspath(os.path.join(state_dir, ".locks", f"{name}.lock"))
    if key in _HELD_LOCKS:          # 可重入：本进程已持有，直接放行
        yield
        return

    try:
        path = os.path.join(locks_dir(state_dir), f"{name}.lock")
        handle = open(path, "a+b")
    except OSError as exc:
        die(EXIT_IO, f"无法创建锁文件（{exc}）：{state_dir}/.locks/{name}.lock\n  请检查该目录是否可写。")

    deadline = time.time() + timeout
    try:
        while True:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.time() > deadline:
                    die(EXIT_IO, f"获取锁超时（{timeout:g}s）：{name}\n  疑似有另一个任务正在写术语库，请稍后重试。")
                time.sleep(0.05)
        _HELD_LOCKS.add(key)
        yield
    finally:
        _HELD_LOCKS.discard(key)
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        finally:
            handle.close()


def write_json_atomic(path: str, data: Any) -> None:
    """同目录 `*.tmp` + `fsync` + `os.replace` 原子落盘，断电不产生半截文件。"""
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def write_text_atomic(path: str, text: str) -> None:
    """文本版原子写。换行一律 `\\n`，UTF-8 无 BOM（§10.6）。"""
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def read_json(path: str, default: Any = None) -> Any:
    """读 JSON；文件缺失或内容畸形时返回 `default`（容忍 BOM）。"""
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def read_text(path: str) -> str:
    """按 §10.6 的编码回退链读入文本：utf-8 → BOM → shift_jis → euc_jp → cp932。"""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        die(EXIT_IO, f"无法读取文件（{exc}）：{path}")
    return decode_bytes(raw)


def decode_bytes(raw: bytes) -> str:
    """解码日文文本，末位用 `errors='replace'` 兜底以免整本书失败。"""
    for enc in ("utf-8", "utf-8-sig", "shift_jis", "euc_jp", "cp932"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


# ══════════════════════════════════════════════════════════════════════════
# 事件（DESIGN §3.4 / §10.4）
# ══════════════════════════════════════════════════════════════════════════

def next_seq(state_dir: str) -> int:
    """读取并自增 `<state>/.locks/seq`，返回**新值**（1-based）。

    用单调整数计数器而不是浮点时间戳做事件排序主键（DESIGN 决策 D6）：
    同秒内多次调用时 `ts` 可能相等，时钟回拨时甚至倒挂，而 F33-02 需要
    判定「① 早于 ③」，必须绝对可靠。

    自愈（§10.4 R3）：`seq` 文件丢失或损坏时，用 `events.jsonl` 的非空行数重建。

    Note:
        调用方必须**已持有** `state` 锁；本函数不自行加锁，以便与事件追加
        构成同一个临界区。
    """
    seq_path = os.path.join(locks_dir(state_dir), "seq")
    current = 0
    try:
        with open(seq_path, "r", encoding="utf-8") as fh:
            current = int(fh.read().strip() or "0")
    except (OSError, ValueError):
        events = os.path.join(state_dir, "events.jsonl")
        try:
            with open(events, "r", encoding="utf-8") as fh:
                current = sum(1 for line in fh if line.strip())
        except OSError:
            current = 0
    nxt = current + 1
    tmp = seq_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(str(nxt))
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, seq_path)
    return nxt


def append_event(state_dir: str, etype: str, *, stage: str | None = None,
                 chunk: int | None = None, actor: str = "script",
                 data: dict[str, Any] | None = None) -> int:
    """在 `state` 锁内自增 seq 并向 `events.jsonl` **追加一行**，返回 seq。

    §10.4 的硬约束：
    - R1 只追加，任何情况下不得重写/删除已有行；
    - R2 seq 自增与追加在同一把 `state.lock` 内完成，**一次 write 写完整一行**；
    - R4 `data` 里不放大文本（梗概/译文正文），只放计数与短标识。

    # T06 扩展点（DESIGN-v3.3-llm U-LLM 事件）：后续 DeepSeek 底层 wenyi 化会新增
    # `llm_call` / `llm_failed` 两种事件（记录每轮 LLM 请求与失败，供 T10 用量展示）。
    # 本函数是通用追加器，事件类型不白名单化 —— 届时只需在调用侧传入新类型，
    # 无需改动本文件；此处仅留注释作为占位，不预先实现、不杜撰字段。
    """
    os.makedirs(state_dir, exist_ok=True)
    with file_lock(state_dir, "state"):
        seq = next_seq(state_dir)
        record = {
            "seq": seq,
            "ts": round(now(), 3),
            "type": etype,
            "stage": stage,
            "chunk": chunk,
            "actor": actor,
            "data": data or {},
        }
        line = json.dumps(record, ensure_ascii=False) + "\n"
        with open(os.path.join(state_dir, "events.jsonl"), "a", encoding="utf-8", newline="\n") as fh:
            fh.write(line)          # 单次 write，保证行不被交错撕裂
            fh.flush()
    return seq


def read_events(state_dir: str) -> list[dict[str, Any]]:
    """读全部事件；跳过畸形行（只追加日志容忍尾部半行）。"""
    path = os.path.join(state_dir, "events.jsonl")
    out: list[dict[str, Any]] = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if isinstance(obj, dict):
                    out.append(obj)
    except OSError:
        return []
    return out


# ══════════════════════════════════════════════════════════════════════════
# 术语匹配算法（DESIGN §4.3，照搬 wenyi `store.py`）
# ══════════════════════════════════════════════════════════════════════════

def norm_text(s: str) -> str:
    """匹配用归一化：NFKC + casefold。

    **只在匹配时归一化，存储时保留原样**（§10.6）——否则用户填的「御堂 静」
    会被改写成归一化形态回写进术语表，破坏「逐字执行」的承诺。
    """
    return unicodedata.normalize("NFKC", s).casefold()


def source_pattern(key: str) -> "re.Pattern[str] | None":
    """为空格分词文字构造词边界正则；连续书写文字（CJK）返回 None 走子串匹配。

    三档规则（§4.3 步骤 3/4/5）：
    1. 纯 ASCII → `(?<![a-z0-9_])<esc>(?![a-z0-9_])`；
    2. 全部字母属于拉丁/希腊/西里尔 → 首尾按 `isalnum()` 决定加 `(?<!\\w)` / `(?!\\w)`；
    3. 其它 → None（调用方改用归一化子串匹配）。

    这两档边界规则正是「`Ann` 不命中 `Anna`、`гад` 不命中 `гадкий`」的实现。
    """
    if key.isascii():
        return re.compile(rf"(?<![a-z0-9_]){re.escape(key)}(?![a-z0-9_])")

    letters = [ch for ch in key if ch.isalpha()]
    if not letters or not all(
        any(script in unicodedata.name(ch, "") for script in _WORD_BOUNDARY_SCRIPTS)
        for ch in letters
    ):
        return None

    left = r"(?<!\w)" if key[0].isalnum() else ""
    right = r"(?!\w)" if key[-1].isalnum() else ""
    return re.compile(f"{left}{re.escape(key)}{right}")


def source_matches(source: str, normalized_text: str) -> bool:
    """判断术语原文是否出现在**已归一化**的文本中。

    Args:
        source: 术语原文（未归一化，函数内部会归一化）。
        normalized_text: 调用方预先用 `norm_text()` 处理过的整段文本。
            预归一化是为了在「一段文本 × N 个术语」的循环里只做一次昂贵的 NFKC。
    """
    key = norm_text(source).strip()
    if not key:
        return False
    pattern = source_pattern(key)
    if pattern is not None:
        return pattern.search(normalized_text) is not None
    return key in normalized_text


def source_spans(source: str, normalized_text: str) -> list[tuple[int, int]]:
    """返回术语在已归一化文本中的**非重叠**命中区间，供计数使用。"""
    key = norm_text(source).strip()
    if not key:
        return []
    pattern = source_pattern(key)
    if pattern is not None:
        return [m.span() for m in pattern.finditer(normalized_text)]
    spans: list[tuple[int, int]] = []
    start = 0
    while (idx := normalized_text.find(key, start)) != -1:
        end = idx + len(key)
        spans.append((idx, end))
        start = end
    return spans


def merged_occurrence_count(spans: Iterable[tuple[int, int]]) -> int:
    """把 source 与 alias 在同一处产生的重叠命中合并为一次正文提及。"""
    count = 0
    active_end = -1
    for start, end in sorted(spans):
        if start >= active_end:
            count += 1
            active_end = end
        else:
            active_end = max(active_end, end)
    return count


def term_match_sources(term: Any) -> list[str]:
    """返回该词条允许参与匹配的写法列表（§4.3 步骤 2）。

    `SOURCE_ONLY_TYPES`（称谓/敬称/口癖/固定表达）只用 `source`，其它类型
    用 `[source, *aliases]`。`term` 可以是 dict 也可以是带同名属性的对象。
    """
    if isinstance(term, dict):
        ttype = term.get("type") or DEFAULT_TERM_TYPE
        source = term.get("source") or ""
        aliases = term.get("aliases") or []
    else:
        ttype = getattr(term, "type", DEFAULT_TERM_TYPE)
        source = getattr(term, "source", "")
        aliases = getattr(term, "aliases", []) or []
    if ttype in SOURCE_ONLY_TYPES:
        return [source]
    return [source, *aliases]


def normalize_term_type(raw: str | None) -> str:
    """未知类型一律归 `其他`（§3.6）。空值取默认类型。"""
    value = (raw or "").strip()
    if not value:
        return DEFAULT_TERM_TYPE
    return value if value in TERM_TYPES else FALLBACK_TERM_TYPE


# ══════════════════════════════════════════════════════════════════════════
# 路径与哈希
# ══════════════════════════════════════════════════════════════════════════

def chunk_path(state_dir: str, n: int, zh: bool = False) -> str:
    """`<state>/chunks/chunk_NNN.txt`（1-based，三位补零，§10.1）。"""
    name = f"chunk_{n:03d}{'_zh' if zh else ''}.txt"
    return os.path.join(state_dir, "chunks", name)


def digest_path(state_dir: str, n: int) -> str:
    """`<state>/digests/chunk_NNN.md`。"""
    return os.path.join(state_dir, "digests", f"chunk_{n:03d}.md")


def glossary_path(state_dir: str) -> str:
    return os.path.join(state_dir, "glossary.json")


def conflicts_path(state_dir: str) -> str:
    return os.path.join(state_dir, "glossary_conflicts.json")


def config_path(state_dir: str) -> str:
    return os.path.join(state_dir, "config.json")


def status_path(state_dir: str) -> str:
    return os.path.join(state_dir, "status.json")


def sha256_file(path: str) -> str:
    """文件内容 SHA-256（十六进制小写）。"""
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for block in iter(lambda: fh.read(1 << 20), b""):
                h.update(block)
    except OSError as exc:
        die(EXIT_IO, f"无法读取文件用于哈希（{exc}）：{path}")
    return h.hexdigest()


def sha256_obj(obj: Any) -> str:
    """对象规范化 JSON 的 SHA-256。

    规范化口径必须与 Swift 侧 `RunParams.sha256()` **逐字一致**，否则续跑判定
    会永远失败：`sort_keys=True`、`separators=(",", ":")`、`ensure_ascii=False`、UTF-8。
    """
    payload = json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def ensure_state(state_dir: str) -> str:
    """校验 state 目录存在，返回其绝对路径；不存在则以 `EXIT_STATE` 退出。"""
    path = os.path.abspath(state_dir)
    if not os.path.isdir(path):
        die(EXIT_STATE, f"state 目录不存在：{path}\n  请先运行 state_tool.py init。")
    return path


def ensure_state_writable(state_dir: str) -> str:
    """确保 state 目录存在（不存在则创建），返回绝对路径。用于 init 类命令。"""
    path = os.path.abspath(state_dir)
    try:
        os.makedirs(path, exist_ok=True)
    except OSError as exc:
        die(EXIT_IO, f"无法创建 state 目录（{exc}）：{path}")
    return path


# ══════════════════════════════════════════════════════════════════════════
# 文本结构（§10.6）
# ══════════════════════════════════════════════════════════════════════════

def split_paragraphs(text: str) -> list[str]:
    """按**连续一个及以上空行**分段。

    `split_text.py` 与 `check_alignment.py` 必须调用**同一个函数**，否则段落数
    永远对不上（§10.6）。这是本函数存在于 `_common` 的唯一理由。
    """
    blocks = re.split(r"\n\s*\n", text)
    return [b.strip() for b in blocks if b.strip()]


_FENCE_RE = re.compile(r"^\s*(```|~~~)")


def fence_line_flags(text: str) -> list[bool]:
    """逐行标记是否处于代码围栏内（含围栏标记行本身）。

    ` ``` ` 与 `~~~` 成对切换。`normalize_punct.py` / `qa_consistency.py`
    必须跳过被标记为 True 的行（§10.6）——围栏内是代码或占位符，改标点会破坏语义。
    """
    flags: list[bool] = []
    inside = False
    fence_token = ""
    for line in text.split("\n"):
        m = _FENCE_RE.match(line)
        if m:
            token = m.group(1)
            if not inside:
                inside = True
                fence_token = token
            elif token == fence_token:
                inside = False
                fence_token = ""
            flags.append(True)      # 围栏标记行本身也不改
            continue
        flags.append(inside)
    return flags


def strip_fenced(text: str) -> str:
    """把围栏内的行替换为空行后返回，用于「只扫描正文」的检查。

    保留行数不变，这样报告里的 `line` 行号仍与原文件对得上。
    """
    lines = text.split("\n")
    flags = fence_line_flags(text)
    return "\n".join("" if flag else line for line, flag in zip(lines, flags))


def parse_kv_pairs(items: list[str] | None) -> dict[str, Any]:
    """把 `--kv k=v` 列表解析为 dict，数值型自动转 int/float。"""
    out: dict[str, Any] = {}
    for item in items or []:
        if "=" not in item:
            die(EXIT_USAGE, f"--kv 需要 key=value 形式，收到：{item}")
        key, _, value = item.partition("=")
        key = key.strip()
        value = value.strip()
        if not key:
            die(EXIT_USAGE, f"--kv 的 key 不能为空：{item}")
        try:
            out[key] = int(value)
            continue
        except ValueError:
            pass
        try:
            out[key] = float(value)
            continue
        except ValueError:
            pass
        if value.lower() in ("true", "false"):
            out[key] = value.lower() == "true"
        else:
            out[key] = value
    return out


def load_json_arg(raw: str) -> Any:
    """解析 `--params-json` / `--json` 参数：支持内联 JSON 与 `@file` 两种写法。"""
    text = raw
    if raw.startswith("@"):
        path = raw[1:]
        try:
            with open(path, "r", encoding="utf-8-sig") as fh:
                text = fh.read()
        except OSError as exc:
            die(EXIT_IO, f"无法读取 JSON 文件（{exc}）：{path}")
    try:
        return json.loads(text)
    except ValueError as exc:
        die(EXIT_INPUT, f"JSON 解析失败：{exc}")


def read_stdin_json() -> Any:
    """从 stdin 读一个 JSON 对象（允许 BOM）。畸形则以 `EXIT_INPUT` 退出。"""
    raw = sys.stdin.buffer.read()
    if not raw.strip():
        die(EXIT_INPUT, "stdin 为空，需要 JSON 对象，例如 {\"terms\":[]}")
    try:
        return json.loads(raw.decode("utf-8-sig"))
    except (ValueError, UnicodeDecodeError) as exc:
        die(EXIT_INPUT, f"stdin JSON 解析失败：{exc}")


def install_excepthook(script_name: str) -> None:
    """顶层异常兜底：转成 stderr 上的一行诊断 + `EXIT_IO`，绝不打印 traceback。

    §10.2 的硬要求 —— traceback 会污染 stdout 的 JSON 通道，让上层解析失败，
    使真正的错误信息反而丢失。
    """
    def _hook(exc_type, exc, _tb):  # noqa: ANN001
        if issubclass(exc_type, SystemExit):
            raise exc
        sys.stderr.write(f"{script_name}: 未预期错误：{exc_type.__name__}: {exc}\n")
        sys.stderr.flush()
        os._exit(EXIT_IO)

    sys.excepthook = _hook
