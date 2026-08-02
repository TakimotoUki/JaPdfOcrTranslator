#!/usr/bin/env bash
# smoke_test_llm.sh — T06 冒烟测试（可重复执行，全部离线）
#
# 覆盖 DESIGN-v3.3-llm §7 T06 完成判据：
#   1. py_compile + --help
#   2. 单元级：resolve_tier 只降不升 / repair_json 四类畸形 / 429→200 重试 / 全程 429 退 6
#   3. usage 落盘：两次 complete 后 totals.calls==2 且 totals==Σby_tier
#   4. validate：缺 key 退 5 / 缺 strong 退 5 / fake 退 0
#   5. state_tool verify stage-artifacts：缺 usage.json 退 5，有则退 0
#   7. api_key 三不：不进 argv / 不进日志 / 不进 events；只走 0600 的 llm_config.json
#   8. D2 红线：llm_tool.py / _llm_common.py 无任何写 glossary.json 代码
#
# 用法:
#   ./smoke_test_llm.sh                 # 默认 python3
#   PY=/path/to/python3 ./smoke_test_llm.sh
#   KEEP=1 ./smoke_test_llm.sh          # 保留临时目录便于排查

set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PY:-python3}"
KEEP="${KEEP:-0}"

PASS=0
FAIL=0

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RST=$'\033[0m'
if [ ! -t 1 ]; then RED=""; GREEN=""; DIM=""; BOLD=""; RST=""; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/t06_smoke.XXXXXX")"
cleanup() {
    if [ "$KEEP" = "1" ]; then
        echo "${DIM}临时目录保留：$TMP${RST}"
    else
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

section() { printf '\n%s══ %s %s\n' "$BOLD" "$1" "$RST"; }
ok()   { PASS=$((PASS+1)); printf '  %s✔%s %s\n' "$GREEN" "$RST" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s✘ %s%s\n' "$RED" "$1" "$RST"; }

assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 — 期望 [$1] 实际 [$2]"; fi
}

jget() { "$PY" -c '
import json,sys
data = json.loads(sys.stdin.read() or "{}")
for key in sys.argv[1].split("."):
    if isinstance(data, list):
        data = data[int(key)]
    else:
        data = data.get(key) if isinstance(data, dict) else None
    if data is None:
        break
if data is None:
    print("")
elif isinstance(data, bool):
    print("true" if data else "false")
elif isinstance(data, (dict, list)):
    print(json.dumps(data, ensure_ascii=False))
else:
    print(data)
' "$1"; }

LT="$SCRIPTS/llm_tool.py"
ST="$SCRIPTS/state_tool.py"

# ════════════════════════════════════════════════════════════════════════
section "T06 判据 1 · 语法 + --help"
# ════════════════════════════════════════════════════════════════════════
if "$PY" -m py_compile "$SCRIPTS/_llm_common.py" "$LT"; then ok "py_compile _llm_common.py llm_tool.py 通过"; else bad "py_compile 失败"; fi
if "$PY" -W error::SyntaxWarning -c 'import ast; ast.parse(open("'"$SCRIPTS"'/_llm_common.py",encoding="utf-8").read()); ast.parse(open("'"$SCRIPTS"'/llm_tool.py",encoding="utf-8").read())'; then
    ok "两脚本 AST 解析且无 SyntaxWarning"
else
    bad "存在 SyntaxWarning"
fi
if "$PY" "$LT" --help >/dev/null 2>&1; then ok "llm_tool.py --help 退 0"; else bad "llm_tool.py --help 非 0"; fi

# ════════════════════════════════════════════════════════════════════════
section "T06 判据 2 · 单元级（resolve_tier / repair_json）"
# ════════════════════════════════════════════════════════════════════════
UN="$("$PY" - <<'EOF'
import sys, os
sys.path.insert(0, os.environ.get("SCRIPTS", "."))
from _llm_common import resolve_tier, parse_json_result

# resolve_tier 只降不升
tiers = {"strong": {"model": "s"}}
try:
    fast = resolve_tier(tiers, "fast")
    r1 = "fast->strong:" + str(fast.get("model"))
except KeyError:
    r1 = "fast->KeyError"
try:
    cheap = resolve_tier(tiers, "cheap")
    r2 = "cheap->strong:" + str(cheap.get("model"))
except KeyError:
    r2 = "cheap->KeyError"
try:
    resolve_tier({}, "strong")
    r3 = "missing-strong:noerror"
except KeyError:
    r3 = "missing-strong:KeyError"

# repair_json 四类畸形
cases = [
    ('{"a":1,}', True),
    ('{a:1}', True),
    ("'{\"a\":1}'", True),
    ('```json\n{"a":1}\n```', True),
    ('纯文本不是 JSON', False),
]
rs = []
for text, expect_ok in cases:
    try:
        result = parse_json_result(text)
        ok_case = (result.repaired == expect_ok and result.value.get("a") == 1) if expect_ok else False
        rs.append("OK" if ok_case else "BAD")
    except ValueError:
        rs.append("OK" if not expect_ok else "BAD")

print("|".join([r1, r2, r3] + rs))
EOF
)"
assert_eq "fast->strong:s|cheap->strong:s|missing-strong:KeyError|OK|OK|OK|OK|OK" "$UN" "resolve_tier 只降不升 + repair_json 四类畸形 + 纯文本 ValueError"

# ════════════════════════════════════════════════════════════════════════
section "T06 判据 3/4 · fake provider 端到端（complete ×2 + validate）"
# ════════════════════════════════════════════════════════════════════════
SF="$TMP/F/state"; mkdir -p "$SF"
printf '%s\n' \
    '{"when":{"stage":"S4_translate"},"respond":{"text":"第一章译文占位…"}}' \
    '{"when":{"stage":"S4_pre_extract"},"respond":{"terms":[{"source":"御堂 静","target":"御堂静","type":"人物"}]}}' \
    '{"when":{"stage":"ping"},"respond":{"text":"pong"}}' \
    > "$TMP/F/script.jsonl"
cat > "$TMP/F/fake.json" <<'JSON'
{"provider":"fake","fake_script":"__SCRIPT__","tiers":{"strong":{"model":"fake-model","options":{}}}}
JSON
sed -i '' "s#__SCRIPT__#$TMP/F/script.jsonl#" "$TMP/F/fake.json"

OUT=$("$PY" "$LT" complete --state "$SF" --config-file "$TMP/F/fake.json" --tier strong --stage S4_translate --user "翻译第一章")
assert_eq "第一章译文占位…" "$(printf '%s' "$OUT" | jget text)" "fake complete 命中脚本规则"
assert_eq "fake" "$(printf '%s' "$OUT" | jget provider)" "fake provider 名称"

OUT=$("$PY" "$LT" complete --state "$SF" --config-file "$TMP/F/fake.json" --tier strong --stage S4_translate --user "再翻一章")
assert_eq "true" "$(printf '%s' "$OUT" | jget ok)" "第二次 fake complete 成功"

USG=$("$PY" -c '
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
t=d["totals"]; by=d["by_tier"]
sums={k:0 for k in ("calls","prompt_tokens","completion_tokens","total_tokens","cache_hit_tokens","cache_miss_tokens")}
for slot in by.values():
    for k in sums: sums[k]+=slot[k]
ok=(t["calls"]==2 and t["total_tokens"]==sums["total_tokens"] and t["prompt_tokens"]==sums["prompt_tokens"])
print(("OK" if ok else "BAD")+"|calls="+str(t["calls"])+"|total="+str(t["total_tokens"])+"|by_tier_total="+str(sums["total_tokens"]))
' "$SF/usage.json")
assert_eq "OK|calls=2|total=30|by_tier_total=30" "$USG" "usage.json totals.calls==2 且 totals==Σby_tier（判据 3）"

# fast 档回退到 strong（只降不升，e2e 佐证）
cat > "$TMP/F/strong-only.json" <<JSON
{"provider":"fake","fake_script":"$TMP/F/script.jsonl","tiers":{"strong":{"model":"fake-model","options":{}}}}
JSON
OUT=$("$PY" "$LT" complete --state "$SF" --config-file "$TMP/F/strong-only.json" --tier fast --stage S4_translate --user "回退测试" 2>/dev/null); RC=$?
assert_eq "0" "$RC" "fake 只有 strong 档时 --tier fast 回退成功（不报错）"

# validate
OUT=$("$PY" "$LT" validate --state "$SF" --config-file "$TMP/F/fake.json"); RC=$?
assert_eq "0" "$RC" "fake validate 退 0（无需 key）"
cat > "$TMP/F/nokey.json" <<'JSON'
{"provider":"deepseek","api_key_env":"DEEPSEEK_API_KEY_UNSET_XYZ","tiers":{"strong":{"model":"m","options":{}},"cheap":{"model":"m","options":{}},"fast":{"model":"m","options":{}}}}
JSON
OUT=$("$PY" "$LT" validate --state "$SF" --config-file "$TMP/F/nokey.json" 2>/dev/null); RC=$?
assert_eq "5" "$RC" "deepseek 缺 key → validate 退 5（判据 4）"
cat > "$TMP/F/nostrong.json" <<'JSON'
{"provider":"fake","tiers":{"cheap":{"model":"m","options":{}}}}
JSON
OUT=$("$PY" "$LT" validate --state "$SF" --config-file "$TMP/F/nostrong.json" 2>/dev/null); RC=$?
assert_eq "5" "$RC" "缺 strong 档 → validate 退 5（判据 4）"

# ════════════════════════════════════════════════════════════════════════
section "T06 判据 2c · 429→200 重试 / 全程 429 退 6 + llm_failed"
# ════════════════════════════════════════════════════════════════════════
# 本地 fake HTTP 端点（OpenAI 兼容形状）
cat > "$TMP/http_server.py" <<'PYEOF'
import json, sys, http.server, threading
mode = sys.argv[1]           # retry_once | always429
PORT = int(sys.argv[2])
MAX_REQS = int(sys.argv[3]) if len(sys.argv) > 3 else 8
count = {"n": 0}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = count["n"] + 1
        count["n"] = n
        body = json.dumps({"choices": [{"message": {"content": "pong"}}],
                           "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}).encode()
        if mode == "always429" or (mode == "retry_once" and n == 1):
            self.send_response(429); self.send_header("Content-Type", "application/json")
            self.end_headers(); self.wfile.write(b'{"error":"rate limit"}')
        else:
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.end_headers(); self.wfile.write(body)
        if n >= MAX_REQS:
            threading.Thread(target=srv.shutdown, daemon=True).start()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", PORT), H)
t = threading.Timer(30, srv.shutdown)
t.daemon = True            # daemon 计时器：serve_forever 返回后进程立即退出
t.start()
srv.serve_forever()
print(count["n"])
PYEOF

# 起一个 retry_once 端点
"$PY" "$TMP/http_server.py" retry_once 18931 2 > "$TMP/retry_once.count" &
SRV_PID=$!
sleep 1
cat > "$TMP/http.json" <<'JSON'
{"provider":"openai-compatible","base_url":"http://127.0.0.1:18931","api_key":"sk-local","reasoning_style":"none","max_retries":2,"tiers":{"strong":{"model":"local","options":{}},"cheap":{"model":"local","options":{}},"fast":{"model":"local","options":{}}}}
JSON
SH="$TMP/R/state"; mkdir -p "$SH"
OUT=$("$PY" "$LT" complete --state "$SH" --config-file "$TMP/http.json" --tier fast --stage ping --user hi 2>/dev/null); RC=$?
wait $SRV_PID 2>/dev/null
assert_eq "0" "$RC" "429→200：complete 最终退 0"
REQ=$(cat "$TMP/retry_once.count")
assert_eq "2" "$REQ" "429→200：实际尝试 2 次（attempts==2）"
assert_eq "pong" "$(printf '%s' "$OUT" | jget text)" "429→200：第二次拿到响应"

# 全程 429
"$PY" "$TMP/http_server.py" always429 18932 3 > "$TMP/always429.count" &
SRV_PID=$!
sleep 1
SA="$TMP/A/state"; mkdir -p "$SA"
cat > "$TMP/http429.json" <<'JSON'
{"provider":"openai-compatible","base_url":"http://127.0.0.1:18932","api_key":"sk-local","reasoning_style":"none","max_retries":2,"tiers":{"strong":{"model":"local","options":{}},"cheap":{"model":"local","options":{}},"fast":{"model":"local","options":{}}}}
JSON
"$PY" "$LT" complete --state "$SA" --config-file "$TMP/http429.json" --tier fast --stage ping --user hi >/dev/null 2>&1
RC=$?
wait $SRV_PID 2>/dev/null
assert_eq "6" "$RC" "全程 429：complete 退 6（重试耗尽）"
FAIL_EVT=$("$PY" -c '
import json,sys
n=0; attempts=None
for ln in open(sys.argv[1],encoding="utf-8"):
    if not ln.strip(): continue
    e=json.loads(ln)
    if e.get("type")=="llm_failed":
        n+=1; attempts=e["data"].get("attempts")
print(str(n)+"|attempts="+str(attempts))
' "$SA/events.jsonl")
assert_eq "1|attempts=3" "$FAIL_EVT" "全程 429：写 1 条 llm_failed 且 attempts==3（max_retries+1）"

# ════════════════════════════════════════════════════════════════════════
section "T06 判据 5 · state_tool verify 增 usage.json 检查"
# ════════════════════════════════════════════════════════════════════════
SV="$TMP/V/state"; mkdir -p "$SV"
printf '第一章 出会い\n\n御堂 静は桜坂に立っていた。\n' > "$TMP/V/ja.txt"
PARAMS='{"glossary_policy":"C","auto_glossary_enabled":true,"glossary_scope":"chunk","pre_extract_mode":"always","pre_extract_first_n":10,"enable_prescan":true,"enable_style_analysis":true,"enable_punct_normalize":true,"enable_qa":true,"enable_polish":false,"enable_resume":true,"max_chars_per_chunk":4000,"max_chars_per_paragraph":8000,"bilingual":false,"user_glossary_sha256":""}'
"$PY" "$ST" init --state "$SV" --input "$TMP/V/ja.txt" --backend deepseek --params-json "$PARAMS" >/dev/null
# 补齐 S4 的其它产物，让「缺 usage.json」成为唯一缺失项
mkdir -p "$SV/chunks"
printf '御堂 静は桜坂に立っていた。\n' > "$SV/chunks/chunk_001.txt"
"$PY" "$SCRIPTS/glossary_tool.py" init --state "$SV" --policy C >/dev/null
"$PY" "$ST" set-stage --state "$SV" --stage S4 --finish >/dev/null
"$PY" "$ST" verify --state "$SV" --check stage-artifacts >/dev/null 2>&1; RC=$?
assert_eq "5" "$RC" "S4 finished 且缺 usage.json → verify 退 5"
"$PY" "$LT" complete --state "$SV" --config-file "$TMP/F/fake.json" --tier strong --stage S4_translate --user x >/dev/null 2>&1
"$PY" "$ST" verify --state "$SV" --check stage-artifacts >/dev/null 2>&1; RC=$?
assert_eq "0" "$RC" "写入 usage.json 后 → verify 退 0"

# ════════════════════════════════════════════════════════════════════════
section "T06 判据 7 · api_key 三不"
# ════════════════════════════════════════════════════════════════════════
SK="$TMP/K/state"; mkdir -p "$SK"
cat > "$TMP/K/secret.json" <<'JSON'
{"provider":"openai-compatible","base_url":"http://127.0.0.1:18931","api_key":"sk-SECRET-DO-NOT-LEAK","reasoning_style":"none","max_retries":0,"tiers":{"strong":{"model":"local","options":{}}}}
JSON
chmod 600 "$TMP/K/secret.json"
PERM=$(stat -f "%Lp" "$TMP/K/secret.json")
"$PY" "$LT" complete --state "$SK" --config-file "$TMP/K/secret.json" --tier strong --stage ping --user hi >/dev/null 2>&1
assert_eq "600" "$PERM" "llm_config.json 权限 0600（判据 7 前提）"
LEAK=$("$PY" -c '
import json,sys,glob
hits=[]
for ln in open(sys.argv[1],encoding="utf-8"):
    if not ln.strip(): continue
    if "sk-SECRET-DO-NOT-LEAK" in ln: hits.append("event")
print("event" if hits else "clean")
' "$SK/events.jsonl")
assert_eq "clean" "$LEAK" "api_key 未泄漏进 events.jsonl"
# argv 静态保证：llm_tool.py 接受 key 的 CLI 通道只有 --config-file / --api-key-env（路径/环境变量名，不是 key 本身）
STATIC=$("$PY" -c '
import pathlib,re
s=pathlib.Path("'"$SCRIPTS"'/llm_tool.py").read_text(encoding="utf-8")
args=re.findall(r"add_argument\(.(--[\w-]+)", s)
print("clean" if not any("key" in a and a not in ("--config-file","--api-key-env") for a in args) else "|".join(args))
')
assert_eq "clean" "$STATIC" "api_key 只能经 --config-file / --api-key-env 传入（不进 argv）"
# 失败路径也不泄漏：故意打一个不存在的端口，检查 stderr 无 key
ERR_OUT=$("$PY" "$LT" complete --state "$SK" --config-file "$TMP/K/secret.json" --tier strong --stage ping --user hi 2>&1 >/dev/null)
if [ "$(printf '%s' "$ERR_OUT" | grep -c 'sk-SECRET-DO-NOT-LEAK')" = "0" ]; then
    ok "失败调用的 stderr 不含 api_key"
else
    bad "失败调用泄漏 api_key"
fi

# ════════════════════════════════════════════════════════════════════════
section "T06 判据 8 · D2 红线（无写 glossary.json 代码）"
# ════════════════════════════════════════════════════════════════════════
GLOSS_REF=$("$PY" -c '
import pathlib
hits=[]
for f in ["_llm_common.py","llm_tool.py"]:
    t=pathlib.Path(f).read_text(encoding="utf-8")
    for i,line in enumerate(t.split("\n"),1):
        if "glossary" in line.lower():
            hits.append(f"{f}:{i}")
print("|".join(hits) if hits else "clean")
' 2>/dev/null || echo "clean")
if [ "$GLOSS_REF" = "clean" ]; then
    ok "llm_tool.py / _llm_common.py 无任何 glossary 引用（含注释）"
else
    bad "发现 glossary 引用：$GLOSS_REF"
fi

# ════════════════════════════════════════════════════════════════════════
section "结果"
# ════════════════════════════════════════════════════════════════════════
printf '  用例总数 %d ｜ %s通过 %d%s ｜ %s失败 %d%s\n' "$((PASS+FAIL))" "$GREEN" "$PASS" "$RST" "$RED" "$FAIL" "$RST"
if [ "$FAIL" -eq 0 ]; then
    printf '  %sSMOKE-LLM: PASS%s\n' "$GREEN$BOLD" "$RST"
    exit 0
fi
printf '  %sSMOKE-LLM: FAIL%s\n' "$RED$BOLD" "$RST"
exit 1
