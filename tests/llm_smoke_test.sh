#!/usr/bin/env bash
# llm_smoke_test.sh — T09 离线 QA 全流程验收主入口（一键复现，全程离线）
#
# 组成：
#   A. 单测（托管 Python 3.13）      —— resolve_tier / repair_json / retry / usage / validate
#   B. 单测（系统 /usr/bin/python3） —— 双 Python 版本兼容（3.9.6 也必须过）
#   C. 复用 tests/llm_e2e_fake.sh    —— fake 48 块端到端 + F33-07 续跑（增量价值：一体化）
#   D. 静态 fake 脚本快速 e2e        —— 验证 tests/llm_fake_script.jsonl 规则文件可用 + verify + usage
#   E. 总耗时断言 < 60s
#
# 判据：bash tests/llm_smoke_test.sh 全程离线退 0（无网络依赖）。
# 用法：
#   ./llm_smoke_test.sh                     # 默认托管 PY
#   PY=/path/to/python3 ./llm_smoke_test.sh # 指定解释器
#   KEEP=1 ./llm_smoke_test.sh              # 保留临时目录

set -uo pipefail

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$TESTS")"
SCRIPTS="$ROOT/Sources/JaPdfOcrTranslator/Resources/skills/jp-txt2pdf-translator/scripts"
PY="${PY:-/Users/takimotouki/.workbuddy/binaries/python/versions/3.13.12/bin/python3}"
SYS_PY="${SYS_PY:-/usr/bin/python3}"
KEEP="${KEEP:-0}"
START=$(date +%s)

PASS=0; FAIL=0
RED=$'\033[31m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; BOLD=""; RST=""; }
section() { printf '\n%s══ %s ══%s\n' "$BOLD" "$1" "$RST"; }
ok()  { PASS=$((PASS+1)); printf '  %s✔%s %s\n' "$GREEN" "$RST" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  %s✘ %s%s\n' "$RED" "$1" "$RST"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 — 期望 [$1] 实际 [$2]"; fi; }
check_rc() { if [ "$1" -eq "$2" ]; then ok "$3"; else bad "$3 — 退出码 $1"; fi; }

# ════════════════════════════════════════════════════════════════════════
section "A · 单测（托管 Python 3.13）"
# ════════════════════════════════════════════════════════════════════════
cd "$TESTS"
A_OUT=$("$PY" -m unittest llm_unit_test 2>&1); A_RC=$?
A_N=$(printf '%s' "$A_OUT" | grep -E "^Ran [0-9]+ tests" | grep -oE "[0-9]+" | head -1)
if [ "$A_RC" -eq 0 ]; then ok "单测全部通过（托管 PY 3.13，Ran $A_N tests）"; else bad "单测失败（3.13）：$A_OUT"; fi

# ════════════════════════════════════════════════════════════════════════
section "B · 单测（系统 Python 3.9.6 双版本兼容）"
# ════════════════════════════════════════════════════════════════════════
if [ -x "$SYS_PY" ]; then
    B_OUT=$("$SYS_PY" -m unittest llm_unit_test 2>&1); B_RC=$?
    B_N=$(printf '%s' "$B_OUT" | grep -E "^Ran [0-9]+ tests" | grep -oE "[0-9]+" | head -1)
    if [ "$B_RC" -eq 0 ]; then ok "单测通过（系统 PY $("$SYS_PY" --version 2>&1)，Ran $B_N tests）"; else bad "单测失败（3.9）：$B_OUT"; fi
else
    ok "系统 /usr/bin/python3 不存在，跳过双版本检查（非阻塞）"
fi

# ════════════════════════════════════════════════════════════════════════
section "C · 复用 llm_e2e_fake.sh（fake 48 块端到端 + 续跑）"
# ════════════════════════════════════════════════════════════════════════
PY="$PY" bash "$TESTS/llm_e2e_fake.sh" > "$TESTS/.e2e.log" 2>&1; C_RC=$?
C_N=$(grep -c "✔" "$TESTS/.e2e.log")   # e2e 全绿用例数
if [ "$C_RC" -eq 0 ]; then ok "llm_e2e_fake.sh 通过（${C_N}）"; else bad "llm_e2e_fake.sh 失败：$(tail -3 "$TESTS/.e2e.log")"; fi

# ════════════════════════════════════════════════════════════════════════
section "D · 静态 fake 脚本快速 e2e（验证 llm_fake_script.jsonl 规则文件）"
# ════════════════════════════════════════════════════════════════════════
TMP="$(mktemp -d "${TMPDIR:-/tmp}/t09_smoke.XXXXXX")"
trap 'rm -rf "$TMP"; rm -f "$TESTS/.e2e.log"' EXIT
ST="$SCRIPTS/state_tool.py"; GT="$SCRIPTS/glossary_tool.py"; LT="$SCRIPTS/llm_tool.py"
S="$TMP/out/state"; mkdir -p "$S"
# 3 块输入（每块 1 段，对齐天然通过）
"$PY" - "$TMP" <<'PYEOF'
import sys
out = sys.argv[1]
paras = []
for n in range(1, 4):
    body = ("御堂 静は桜坂の坂道を歩いていた。第{}の場面である。風が静かに吹いている。".format(n) * 120)[:4200]
    paras.append("第{}章 出会い\n".format(n) + body)
open(out + "/ja.txt", "w", encoding="utf-8").write("\n\n".join(paras) + "\n")
PYEOF
PARAMS='{"glossary_policy":"C","auto_glossary_enabled":true,"glossary_scope":"chunk","pre_extract_mode":"always","pre_extract_first_n":10,"enable_prescan":false,"enable_style_analysis":false,"enable_punct_normalize":true,"enable_qa":true,"enable_polish":false,"enable_resume":true,"max_chars_per_chunk":4000,"max_chars_per_paragraph":8000,"bilingual":false,"user_glossary_sha256":"","llm_provider":"fake"}'
cat > "$TMP/fake.json" <<JSON
{"provider":"fake","fake_script":"$TESTS/llm_fake_script.jsonl","tiers":{"strong":{"model":"fake-model","options":{"thinking":false}},"cheap":{"model":"fake-model","options":{"thinking":false}},"fast":{"model":"fake-model","options":{"thinking":false}}}}
JSON
"$PY" "$ST" init --state "$S" --input "$TMP/ja.txt" --backend deepseek --params-json "$PARAMS" >/dev/null
N=$("$PY" "$SCRIPTS/split_text.py" --input "$TMP/ja.txt" --out "$S" --target 4000 --maxp 8000 --format json 2>/dev/null | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("chunks",0))')
assert_eq "3" "$N" "D: split 产出 3 块"
"$PY" "$GT" init --state "$S" --policy C >/dev/null
for n in 1 2 3; do
    pre=$("$PY" "$LT" complete-json --state "$S" --config-file "$TMP/fake.json" --tier cheap --stage S4_pre_extract --user "预抽$n" 2>/dev/null | "$PY" -c 'import json,sys;print(json.dumps(json.load(sys.stdin).get("value",{}),ensure_ascii=False))')
    printf '%s' "$pre" | "$PY" "$GT" upsert --state "$S" --chunk "$n" --phase pre --stdin >/dev/null
    "$PY" "$GT" hits --state "$S" --chunk "$n" --scope chunk --format md >/dev/null
    zh=$("$PY" "$LT" complete --state "$S" --config-file "$TMP/fake.json" --tier strong --stage S4_translate --user "译$n" 2>/dev/null | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("text",""))')
    printf '%s\n' "$zh" > "$S/chunks/chunk_$(printf '%03d' "$n")_zh.txt"
    post=$("$PY" "$LT" complete-json --state "$S" --config-file "$TMP/fake.json" --tier cheap --stage S4_post_extract --user "回抽$n" 2>/dev/null | "$PY" -c 'import json,sys;print(json.dumps(json.load(sys.stdin).get("value",{}),ensure_ascii=False))')
    printf '%s' "$post" | "$PY" "$GT" upsert --state "$S" --chunk "$n" --phase post --stdin >/dev/null
    "$PY" "$ST" mark-chunk --state "$S" --chunk "$n" --value done --zh-chars "${#zh}" >/dev/null
done
"$PY" "$ST" verify --state "$S" --check all >/dev/null 2>&1; D_RC=$?
check_rc "$D_RC" 0 "D: 静态规则 e2e 后 verify 退 0（术语硬契约）"
D_USG=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["totals"]["calls"])' "$S/usage.json" 2>/dev/null || echo 0)
assert_eq "9" "$D_USG" "D: usage.json totals.calls = 9（3 块 × 3 次 LLM，静态规则命中）"
D_PONG=$("$PY" "$LT" ping --state "$S" --config-file "$TMP/fake.json" --format text 2>/dev/null)
assert_eq "pong" "$D_PONG" "D: ping 命中静态规则 → pong"

# ════════════════════════════════════════════════════════════════════════
section "E · 总耗时断言"
# ════════════════════════════════════════════════════════════════════════
END=$(date +%s); ELAPSED=$((END - START))
if [ "$ELAPSED" -lt 60 ]; then
    ok "全流程耗时 ${ELAPSED}s < 60s"
else
    bad "全流程耗时 ${ELAPSED}s ≥ 60s"
fi

printf '\n%s══ 结果 ══%s\n' "$BOLD" "$RST"
printf '  用例总数 %d ｜ %s通过 %d%s ｜ %s失败 %d%s ｜ 耗时 %ds\n' \
    "$((PASS+FAIL))" "$GREEN" "$PASS" "$RST" "$RED" "$FAIL" "$RST" "$ELAPSED"
if [ "$FAIL" -eq 0 ]; then printf '  %sLLM-SMOKE: PASS%s\n' "$GREEN$BOLD" "$RST"; exit 0; fi
printf '  %sLLM-SMOKE: FAIL%s\n' "$RED$BOLD" "$RST"; exit 1
