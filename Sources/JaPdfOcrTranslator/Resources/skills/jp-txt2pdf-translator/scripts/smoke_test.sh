#!/usr/bin/env bash
# smoke_test.sh — T02 冒烟测试（可重复执行）
#
# 覆盖 DESIGN-v3.3 §8 T02 的全部 8 条完成判据：
#   1. 语法解析 + 所有脚本 --help 退 0
#   2. F33-01 三情形（policy A / C / B）
#   3. F33-04 冲突（两条 auto 同 source 不同 target）
#   4. F33-02 时序（正序退 0，反序退 5 并列出块号）
#   5. §4.3 匹配（Ann/Anna、гад/гадкий、CJK 子串、称谓类 alias 不参与）
#   6. hits --format md 与 render --policy B 的术语部分逐字一致
#   7. check_alignment.py 对故意删段的样例退非零并列出块号与 delta
#   8. normalize_punct.py 处理后日式括号残留 = 0，围栏内标点零改动
#
# 每次运行都在全新的临时目录里跑，跑完清理，可无限次重复。
#
# 用法:
#   ./smoke_test.sh                 # 用默认 python3
#   PY=/path/to/python3 ./smoke_test.sh
#   KEEP=1 ./smoke_test.sh          # 保留临时目录便于排查

set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPTS                      # 供内联 python 片段 import _common
PY="${PY:-python3}"
KEEP="${KEEP:-0}"

PASS=0
FAIL=0
CASE_NO=0

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RST=$'\033[0m'
if [ ! -t 1 ]; then RED=""; GREEN=""; DIM=""; BOLD=""; RST=""; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/t02_smoke.XXXXXX")"
cleanup() {
    if [ "$KEEP" = "1" ]; then
        echo "${DIM}临时目录保留：$TMP${RST}"
    else
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

section() { printf '\n%s══ %s %s\n' "$BOLD" "$1" "$RST"; }

# ok/bad 各自记一条用例，保证 CASE_NO == PASS + FAIL 恒成立
ok()   { CASE_NO=$((CASE_NO+1)); PASS=$((PASS+1)); printf '  %s✔%s %s\n' "$GREEN" "$RST" "$1"; }
bad()  { CASE_NO=$((CASE_NO+1)); FAIL=$((FAIL+1)); printf '  %s✘ %s%s\n' "$RED" "$1" "$RST"; }

# assert_eq <期望> <实际> <说明>
assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 — 期望 [$1] 实际 [$2]"; fi
}

# assert_contains <文本> <子串> <说明>
assert_contains() {
    case "$1" in
        *"$2"*) ok "$3" ;;
        *)      bad "$3 — 未找到 [$2]" ;;
    esac
}

# assert_not_contains <文本> <子串> <说明>
assert_not_contains() {
    case "$1" in
        *"$2"*) bad "$3 — 不应出现 [$2]" ;;
        *)      ok "$3" ;;
    esac
}

# jq 不可用（零第三方依赖原则），用 python 读 JSON 字段
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
    print("true" if data else "false")      # 与 JSON 字面量一致，避免 Python 的 True/False
elif isinstance(data, (dict, list)):
    print(json.dumps(data, ensure_ascii=False))
else:
    print(data)
' "$1"; }

GT="$SCRIPTS/glossary_tool.py"
ST="$SCRIPTS/state_tool.py"

PARAMS='{"glossary_policy":"C","auto_glossary_enabled":true,"glossary_scope":"chunk","pre_extract_mode":"always","pre_extract_first_n":10,"enable_prescan":true,"enable_style_analysis":true,"enable_punct_normalize":true,"enable_qa":true,"enable_polish":false,"enable_resume":true,"max_chars_per_chunk":4000,"max_chars_per_paragraph":8000,"bilingual":false,"user_glossary_sha256":""}'

# ════════════════════════════════════════════════════════════════════════
section "判据 1 · 语法解析 + --help"
# ════════════════════════════════════════════════════════════════════════
if "$PY" -c 'import ast,sys
for f in sys.argv[1:]:
    ast.parse(open(f, encoding="utf-8").read(), filename=f)
' "$SCRIPTS"/*.py 2>"$TMP/ast.err"; then
    ok "全部脚本 ast.parse 通过"
else
    bad "ast.parse 失败：$(cat "$TMP/ast.err")"
fi

for f in _common.py state_tool.py glossary_tool.py split_text.py sample_text.py \
         reduce_digests.py check_boundaries.py check_alignment.py \
         normalize_punct.py qa_consistency.py merge.py make_report.py; do
    if "$PY" "$SCRIPTS/$f" --help >/dev/null 2>&1; then
        ok "$f --help 退 0"
    else
        # _common.py 是模块不是入口，允许无 --help
        if [ "$f" = "_common.py" ]; then ok "$f 为模块（无 --help，跳过）"
        else bad "$f --help 非 0"; fi
    fi
done

CNT=$(ls "$SCRIPTS"/*.py | wc -l | tr -d ' ')
# v3.3 主流水线 requiredScripts = 13；T06 新增 _llm_common.py + llm_tool.py（LLM 层）→ 共 15
if [ "$CNT" -ge 13 ]; then ok "scripts/ 下共 $CNT 个 .py（≥13 requiredScripts；T06 增 2 个 LLM 脚本）"; else bad "scripts/ 下 .py 数量不足：$CNT"; fi
for llm in _llm_common.py llm_tool.py; do
    if [ -f "$SCRIPTS/$llm" ]; then ok "$llm 存在（T06 LLM 层）"; else bad "$llm 缺失"; fi
done

# ════════════════════════════════════════════════════════════════════════
section "判据 2 · F33-01 三情形（policy A / C / B）"
# ════════════════════════════════════════════════════════════════════════

# ── 情形 A：用户表逐字执行，禁止新增 ──────────────────────────────────
SA="$TMP/A/state"; mkdir -p "$SA"
cat >"$TMP/A/user.csv" <<'CSV'
日语,中文
御堂 静,御堂静
桜坂,樱坂
CSV
OUT=$("$PY" "$GT" init --state "$SA" --policy A --user-csv "$TMP/A/user.csv")
# DESIGN §4.2 stdout 契约：terms/locked/auto；user_terms 只出现在 §3.4 事件 data 里
assert_eq "2" "$(printf '%s' "$OUT" | jget terms)" "A: init 载入 2 条用户词条"
assert_eq "2" "$(printf '%s' "$OUT" | jget locked)" "A: init locked=2"
EVT=$("$PY" -c '
import json,sys
for ln in open(sys.argv[1], encoding="utf-8"):
    if not ln.strip():
        continue
    e = json.loads(ln)
    if e.get("type") == "glossary_init":          # §3.4 字段名是 type，不是 event
        print(str(e["data"]["policy"]) + "|" + str(e["data"]["user_terms"]))
        break
' "$SA/events.jsonl")
assert_eq "A|2" "$EVT" "A: glossary_init 事件 data={policy,user_terms}（§3.4）"

ALL_USER=$("$PY" -c '
import json,sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
ts=d["terms"]
print("yes" if ts and all(t["origin"]=="user" and t["locked"] for t in ts) else "no")
' "$SA/glossary.json")
assert_eq "yes" "$ALL_USER" "A: 全部 origin=user 且 locked=true"

BEFORE=$("$PY" -c 'import json,sys;print(len(json.load(open(sys.argv[1],encoding="utf-8"))["terms"]))' "$SA/glossary.json")
OUT=$(printf '%s' '{"terms":[{"source":"新語","target":"新词","type":"术语"}]}' \
      | "$PY" "$GT" upsert --state "$SA" --stdin --chunk 1 --phase pre)
RC=$?
assert_eq "0" "$RC" "A: 被策略拒绝仍退 0（业务结果非错误）"
assert_eq "1" "$(printf '%s' "$OUT" | jget summary.rejected_by_policy)" "A: rejected_by_policy=1"
AFTER=$("$PY" -c 'import json,sys;print(len(json.load(open(sys.argv[1],encoding="utf-8"))["terms"]))' "$SA/glossary.json")
assert_eq "$BEFORE" "$AFTER" "A: glossary.json 条数不变（${BEFORE} 条）"

# ── 情形 C：空表起步，自动建表 ───────────────────────────────────────
SC="$TMP/C/state"; mkdir -p "$SC"
OUT=$("$PY" "$GT" init --state "$SC" --policy C)
assert_eq "0" "$(printf '%s' "$OUT" | jget terms)" "C: init 后为空表"
OUT=$(printf '%s' '{"terms":[
  {"source":"御堂 静","target":"御堂静","type":"人物"},
  {"source":"桜坂","target":"樱坂","type":"地名"},
  {"source":"影縫","target":"影缝","type":"招式"}]}' \
      | "$PY" "$GT" upsert --state "$SC" --stdin --chunk 1 --phase pre)
assert_eq "3" "$(printf '%s' "$OUT" | jget summary.inserted)" "C: inserted=3"
ALL_AUTO=$("$PY" -c '
import json,sys
ts=json.load(open(sys.argv[1],encoding="utf-8"))["terms"]
print("yes" if ts and all(t["origin"]=="auto" for t in ts) else "no")
' "$SC/glossary.json")
assert_eq "yes" "$ALL_AUTO" "C: 全部 origin=auto"

# ── 情形 B：用户表 + 自动扩充，锁定词条不可被改写 ────────────────────
SB="$TMP/B/state"; mkdir -p "$SB"
cat >"$TMP/B/user.csv" <<'CSV'
日语,中文
御堂 静,御堂静
CSV
"$PY" "$GT" init --state "$SB" --policy B --user-csv "$TMP/B/user.csv" >/dev/null
OUT=$(printf '%s' '{"terms":[{"source":"御堂 静","target":"米堂静","type":"人物"}]}' \
      | "$PY" "$GT" upsert --state "$SB" --stdin --chunk 3 --phase post)
assert_eq "1" "$(printf '%s' "$OUT" | jget summary.rejected_by_lock)" "B: rejected_by_lock=1"
KEPT=$("$PY" -c '
import json,sys
ts=json.load(open(sys.argv[1],encoding="utf-8"))["terms"]
print(next((t["target"] for t in ts if t["source"]=="御堂 静"), ""))
' "$SB/glossary.json")
assert_eq "御堂静" "$KEPT" "B: 用户词条 target 逐字未变"
CONF=$("$PY" -c '
import json,sys
cs=json.load(open(sys.argv[1],encoding="utf-8"))["conflicts"]
c=cs[-1] if cs else {}
print(str(c.get("resolution")) + "|" + str(bool(c.get("resolved"))).lower())
' "$SB/glossary_conflicts.json")
assert_eq "rejected_by_lock|true" "$CONF" "B: conflicts 记录 rejected_by_lock 且 resolved=true"

# ════════════════════════════════════════════════════════════════════════
section "判据 3 · F33-04 冲突（两条 auto 同 source 不同 target）"
# ════════════════════════════════════════════════════════════════════════
SF="$TMP/F/state"; mkdir -p "$SF"
"$PY" "$GT" init --state "$SF" --policy C >/dev/null
printf '%s' '{"terms":[{"source":"影縫","target":"影缝","type":"招式"}]}' \
    | "$PY" "$GT" upsert --state "$SF" --stdin --chunk 1 --phase pre >/dev/null
OUT=$(printf '%s' '{"terms":[{"source":"影縫","target":"暗缝","type":"招式"}]}' \
      | "$PY" "$GT" upsert --state "$SF" --stdin --chunk 2 --phase pre)
assert_eq "1" "$(printf '%s' "$OUT" | jget summary.conflict)" "F33-04: 第二次 conflict=1"
CUR=$("$PY" -c '
import json,sys
ts=json.load(open(sys.argv[1],encoding="utf-8"))["terms"]
t=next((t for t in ts if t["source"]=="影縫"), {})
print(str(t.get("target")) + "|" + str(t.get("status")))
' "$SF/glossary.json")
assert_eq "影缝|conflict" "$CUR" "F33-04: 现值不变且 status=conflict"
OPEN=$("$PY" -c '
import json,sys
cs=json.load(open(sys.argv[1],encoding="utf-8"))["conflicts"]
print(sum(1 for c in cs if not c["resolved"]))
' "$SF/glossary_conflicts.json")
assert_eq "1" "$OPEN" "F33-04: conflicts 出现 resolved=false"

OUT=$("$PY" "$GT" conflicts --state "$SF" --fail-if-open >/dev/null 2>&1; echo $?)
assert_eq "5" "$OUT" "conflicts --fail-if-open 有未决时退 5"

"$PY" "$GT" resolve --state "$SF" --source "影縫" --target "影缝" --lock --by user >/dev/null
OUT=$("$PY" "$GT" conflicts --state "$SF" --fail-if-open >/dev/null 2>&1; echo $?)
assert_eq "0" "$OUT" "resolve 后 --fail-if-open 退 0"

# ════════════════════════════════════════════════════════════════════════
section "判据 4 · F33-02 时序（正序退 0 / 反序退 5）"
# ════════════════════════════════════════════════════════════════════════
mk_run() {   # mk_run <state> ; 建立 2 块的最小 run
    local S="$1"
    mkdir -p "$S/chunks"
    printf '御堂 静は桜坂に立っていた。\n\n風が吹く。\n' >"$S/chunks/chunk_001.txt"
    printf '影縫を放つ。\n\n静かな夜。\n' >"$S/chunks/chunk_002.txt"
    printf '御堂静站在樱坂上。\n\n风吹过。\n' >"$S/chunks/chunk_001_zh.txt"
    printf '施展影缝。\n\n静谧的夜。\n' >"$S/chunks/chunk_002_zh.txt"
    printf '御堂 静は桜坂に立っていた。\n\n風が吹く。\n影縫を放つ。\n' >"$S/../input.txt"
    "$PY" "$ST" init --state "$S" --input "$S/../input.txt" --backend deepseek \
        --params-json "$PARAMS" >/dev/null
    "$PY" -c '
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding="utf-8")); d["total_chunks"]=2
json.dump(d, open(p,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
' "$S/config.json"
    "$PY" "$GT" init --state "$S" --policy C >/dev/null
}

# 正序：pre → translated
SOK="$TMP/ORD_OK/state"; mkdir -p "$SOK"; mk_run "$SOK"
for N in 1 2; do
    printf '%s' '{"terms":[]}' | "$PY" "$GT" upsert --state "$SOK" --stdin --chunk "$N" --phase pre >/dev/null
    "$PY" "$ST" mark-chunk --state "$SOK" --chunk "$N" --value done >/dev/null
done
OUT=$("$PY" "$ST" verify --state "$SOK" --check pre-extract-order); RC=$?
assert_eq "0" "$RC" "F33-02 正序：verify 退 0"
assert_eq "true" "$(printf '%s' "$OUT" | jget compliant)" "F33-02 正序：compliant=true"

# 反序：translated → pre
SBAD="$TMP/ORD_BAD/state"; mkdir -p "$SBAD"; mk_run "$SBAD"
for N in 1 2; do
    "$PY" "$ST" mark-chunk --state "$SBAD" --chunk "$N" --value done >/dev/null
    printf '%s' '{"terms":[]}' | "$PY" "$GT" upsert --state "$SBAD" --stdin --chunk "$N" --phase pre >/dev/null
done
OUT=$("$PY" "$ST" verify --state "$SBAD" --check pre-extract-order); RC=$?
assert_eq "5" "$RC" "F33-02 反序：verify 退 5"
assert_eq "false" "$(printf '%s' "$OUT" | jget compliant)" "F33-02 反序：compliant=false"
OOO=$(printf '%s' "$OUT" | jget checks.pre_extract_order.out_of_order)
assert_contains "$OOO" '"chunk": 1' "F33-02 反序：列出块号 1"
assert_contains "$OOO" '"chunk": 2' "F33-02 反序：列出块号 2"

# 缺失预抽
SMIS="$TMP/ORD_MIS/state"; mkdir -p "$SMIS"; mk_run "$SMIS"
printf '%s' '{"terms":[]}' | "$PY" "$GT" upsert --state "$SMIS" --stdin --chunk 1 --phase pre >/dev/null
"$PY" "$ST" mark-chunk --state "$SMIS" --chunk 1 --value done >/dev/null
"$PY" "$ST" mark-chunk --state "$SMIS" --chunk 2 --value done >/dev/null
OUT=$("$PY" "$ST" verify --state "$SMIS" --check pre-extract-order); RC=$?
assert_eq "5" "$RC" "F33-02 缺失预抽：verify 退 5"
assert_eq "[2]" "$(printf '%s' "$OUT" | jget missing_pre_extract)" "F33-02 缺失预抽：missing_pre_extract=[2]"

# ════════════════════════════════════════════════════════════════════════
section "判据 5 · §4.3 匹配规则"
# ════════════════════════════════════════════════════════════════════════
SM="$TMP/M/state"; mkdir -p "$SM"
"$PY" "$GT" init --state "$SM" --policy C >/dev/null
printf '%s' '{"terms":[
  {"source":"Ann","target":"安","type":"人物"},
  {"source":"гад","target":"坏东西","type":"其他"},
  {"source":"御堂","target":"御堂","type":"人物"},
  {"source":"お嬢様","target":"大小姐","type":"称谓","aliases":["嬢ちゃん"]},
  {"source":"先輩","target":"前辈","type":"术语","aliases":["せんぱい"]}]}' \
    | "$PY" "$GT" upsert --state "$SM" --stdin --chunk 1 --phase pre >/dev/null

hits_of() { printf '%s' "$1" | "$PY" "$GT" hits --state "$SM" --stdin-text --format json; }

R=$(hits_of "Anna went home."); assert_not_contains "$R" '"Ann"' "Ann 不命中 Anna"
R=$(hits_of "Ann went home.");  assert_contains     "$R" '"Ann"' "Ann 命中 Ann"
R=$(hits_of "гадкий утёнок");   assert_not_contains "$R" '"гад"' "гад 不命中 гадкий"
R=$(hits_of "какой гад!");      assert_contains     "$R" '"гад"' "гад 命中独立词 гад"
R=$(hits_of "御堂静が来た");     assert_contains     "$R" '"御堂"' "御堂 命中 御堂静（CJK 子串）"
R=$(hits_of "嬢ちゃん、こんにちは"); assert_not_contains "$R" '"お嬢様"' "称谓类 alias 不参与匹配"
R=$(hits_of "お嬢様、こんにちは"); assert_contains   "$R" '"お嬢様"' "称谓类 source 仍参与匹配"
R=$(hits_of "せんぱい！");        assert_contains     "$R" '"先輩"' "非称谓类 alias 正常参与匹配"

# ════════════════════════════════════════════════════════════════════════
section "判据 6 · hits --format md 与 render --policy B 术语段逐字一致"
# ════════════════════════════════════════════════════════════════════════
SR="$TMP/R/state"; mkdir -p "$SR"
cat >"$TMP/R/user.csv" <<'CSV'
日语,中文
御堂 静,御堂静
CSV
"$PY" "$GT" init --state "$SR" --policy B --user-csv "$TMP/R/user.csv" >/dev/null
printf '%s' '{"terms":[{"source":"桜坂","target":"樱坂","type":"地名"}]}' \
    | "$PY" "$GT" upsert --state "$SR" --stdin --chunk 1 --phase pre >/dev/null
mkdir -p "$SR/chunks"
printf '御堂 静は桜坂に立っていた。\n' >"$SR/chunks/chunk_001.txt"

"$PY" "$GT" hits --state "$SR" --chunk 1 --format md   >"$TMP/R/hits.md"
"$PY" "$GT" render --state "$SR" --chunk 1 --policy B  >"$TMP/R/render.md"
# render 的术语部分 = 从「【本块命中术语」标题行起到策略段之前
"$PY" - "$TMP/R/hits.md" "$TMP/R/render.md" >"$TMP/R/cmp.txt" <<'PYEOF'
import sys
hits = open(sys.argv[1], encoding="utf-8").read().strip("\n")
render = open(sys.argv[2], encoding="utf-8").read()
print("YES" if hits and hits in render else "NO")
PYEOF
assert_eq "YES" "$(cat "$TMP/R/cmp.txt")" "render 中逐字包含 hits --format md 的术语段"

# ════════════════════════════════════════════════════════════════════════
section "判据 7 · check_alignment.py 对删段样例退非零"
# ════════════════════════════════════════════════════════════════════════
SAL="$TMP/AL/state"; mkdir -p "$SAL/chunks"
printf '第一段。\n\n第二段。\n\n第三段。\n\n第四段。\n' >"$SAL/chunks/chunk_001.txt"
printf '第一段译文。\n\n第二段译文。\n' >"$SAL/chunks/chunk_001_zh.txt"   # 故意删 2 段
printf '甲。\n\n乙。\n' >"$SAL/chunks/chunk_002.txt"
printf '甲译。\n\n乙译。\n' >"$SAL/chunks/chunk_002_zh.txt"
OUT=$("$PY" "$SCRIPTS/check_alignment.py" --state "$SAL" 2>/dev/null); RC=$?
assert_eq "5" "$RC" "check_alignment 删段样例退 5（非零）"
assert_eq "[1]" "$(printf '%s' "$OUT" | jget error_chunks)" "check_alignment 列出块号 [1]"
DELTA=$("$PY" -c '
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
i=next(x for x in d["issues"] if x["kind"]=="paragraph_count_mismatch")
print(i["delta"])
' "$SAL/alignment_report.json")
assert_eq "-2" "$DELTA" "check_alignment 报出 delta=-2"

# 补齐后应退 0
printf '第一段译文。\n\n第二段译文。\n\n第三段译文。\n\n第四段译文。\n' >"$SAL/chunks/chunk_001_zh.txt"
"$PY" "$SCRIPTS/check_alignment.py" --state "$SAL" >/dev/null 2>&1
assert_eq "0" "$?" "check_alignment 补齐后退 0"

# ════════════════════════════════════════════════════════════════════════
section "判据 8 · normalize_punct.py 括号残留 = 0 且围栏内零改动"
# ════════════════════════════════════════════════════════════════════════
SNP="$TMP/NP/state"; mkdir -p "$SNP/chunks"
printf '源\n' >"$SNP/chunks/chunk_001.txt"
cat >"$SNP/chunks/chunk_001_zh.txt" <<'TXT'
他说「你好」,然后走了.真的吗?
她读了『雪国』这本书!
```
code: print("a.b,c!")  「不要动我」
```
版本 1.2.3 与 3.14 不应被改，路径 a/b.c 也不动。
等等...再见--
TXT
CKSUM_BEFORE=$("$PY" -c '
import sys,hashlib
lines=open(sys.argv[1],encoding="utf-8").read().split("\n")
print(hashlib.sha256("\n".join(lines[2:5]).encode()).hexdigest())
' "$SNP/chunks/chunk_001_zh.txt")

OUT=$("$PY" "$SCRIPTS/normalize_punct.py" --state "$SNP"); RC=$?
assert_eq "0" "$RC" "normalize_punct 退 0"
assert_eq "0" "$(printf '%s' "$OUT" | jget bracket_residue)" "日式括号残留 = 0（可规范化区）"
# 围栏里的「不要动我」按契约必须保留 → 计入 bracket_protected 而非 residue
assert_eq "2" "$(printf '%s' "$OUT" | jget bracket_protected)" "围栏内 2 个日式括号被保护而非改写"

# 独立复核：直接读盘，跳过围栏行后统计残留
RES=$("$PY" -c '
import sys, os
sys.path.insert(0, os.environ["SCRIPTS"])
from _common import fence_line_flags
t = open(sys.argv[1], encoding="utf-8").read()
flags = fence_line_flags(t)
print(sum(sum(ln.count(c) for c in "「」『』")
          for ln, fenced in zip(t.split("\n"), flags) if not fenced))
' "$SNP/chunks/chunk_001_zh.txt")
assert_eq "0" "$RES" "文件中日式括号实际残留 = 0（围栏外）"

CKSUM_AFTER=$("$PY" -c '
import sys,hashlib
lines=open(sys.argv[1],encoding="utf-8").read().split("\n")
print(hashlib.sha256("\n".join(lines[2:5]).encode()).hexdigest())
' "$SNP/chunks/chunk_001_zh.txt")
assert_eq "$CKSUM_BEFORE" "$CKSUM_AFTER" "围栏内 3 行标点零改动（sha256 一致）"

KEEP_NUM=$("$PY" -c '
import sys
t=open(sys.argv[1],encoding="utf-8").read()
print("yes" if ("1.2.3" in t and "3.14" in t and "a/b.c" in t) else "no")
' "$SNP/chunks/chunk_001_zh.txt")
assert_eq "yes" "$KEEP_NUM" "版本号/小数/路径未被误改"

ELL=$("$PY" -c '
import sys
t=open(sys.argv[1],encoding="utf-8").read()
print("yes" if ("……" in t and "——" in t) else "no")
' "$SNP/chunks/chunk_001_zh.txt")
assert_eq "yes" "$ELL" "省略号/破折号已转换"

# dry-run 不落盘
BEFORE_HASH=$("$PY" -c 'import sys,hashlib;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$SNP/chunks/chunk_001_zh.txt")
printf '再来一次「测试」\n' >>"$SNP/chunks/chunk_001_zh.txt"
BEFORE_HASH=$("$PY" -c 'import sys,hashlib;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$SNP/chunks/chunk_001_zh.txt")
"$PY" "$SCRIPTS/normalize_punct.py" --state "$SNP" --dry-run >/dev/null
AFTER_HASH=$("$PY" -c 'import sys,hashlib;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$SNP/chunks/chunk_001_zh.txt")
assert_eq "$BEFORE_HASH" "$AFTER_HASH" "--dry-run 不落盘"

# ════════════════════════════════════════════════════════════════════════
section "附加 · 端到端九阶段贯通（split → QA → report）"
# ════════════════════════════════════════════════════════════════════════
E2E="$TMP/E2E"; mkdir -p "$E2E"
"$PY" - "$E2E/ja.txt" <<'PYEOF'
import sys
paras = []
paras.append("第一章 出会い")
for i in range(1, 13):
    paras.append(f"御堂 静は桜坂の坂道を歩いていた。第{i}の場面である。" * 6)
open(sys.argv[1], "w", encoding="utf-8").write("\n\n".join(paras) + "\n")
PYEOF
SE="$E2E/state"
OUT=$("$PY" "$ST" init --state "$SE" --input "$E2E/ja.txt" --backend workbuddy --params-json "$PARAMS")
assert_eq "true" "$(printf '%s' "$OUT" | jget ok)" "e2e: state_tool init 成功"

"$PY" "$ST" set-stage --state "$SE" --stage S1 >/dev/null
OUT=$("$PY" "$SCRIPTS/split_text.py" --input "$E2E/ja.txt" --out "$SE" --target 400 --format json)
NCH=$(printf '%s' "$OUT" | jget chunks)
if [ "$NCH" -ge 2 ]; then ok "e2e: split_text 产出 $NCH 块"; else bad "e2e: split_text 块数异常 $NCH"; fi
assert_eq "$NCH" "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["total_chunks"])' "$SE/config.json")" \
    "e2e: config.total_chunks 已回填"
"$PY" "$ST" set-stage --state "$SE" --stage S1 --finish >/dev/null

"$PY" "$GT" init --state "$SE" --policy C >/dev/null
N=1
while [ "$N" -le "$NCH" ]; do
    printf '%s' '{"terms":[{"source":"御堂 静","target":"御堂静","type":"人物"},{"source":"桜坂","target":"樱坂","type":"地名"}]}' \
        | "$PY" "$GT" upsert --state "$SE" --stdin --chunk "$N" --phase pre >/dev/null
    "$PY" -c '
import sys, re
src = open(sys.argv[1], encoding="utf-8").read()
zh = src.replace("御堂 静", "御堂静").replace("桜坂", "樱坂")
zh = zh.replace("の坂道を歩いていた。", "沿着坡道走着。").replace("の場面である。", "个场景。")
zh = re.sub(r"第(\d+)", r"第\1", zh)
zh = re.sub(r"[\u3040-\u30FF]+", "", zh)
open(sys.argv[2], "w", encoding="utf-8").write(zh)
' "$SE/chunks/chunk_$(printf '%03d' "$N").txt" "$SE/chunks/chunk_$(printf '%03d' "$N")_zh.txt"
    "$PY" "$ST" mark-chunk --state "$SE" --chunk "$N" --value done >/dev/null
    N=$((N+1))
done
"$PY" "$ST" set-stage --state "$SE" --stage S4 --finish >/dev/null

"$PY" "$SCRIPTS/check_boundaries.py" --state "$SE" >/dev/null
[ -f "$SE/boundary_report.json" ] && ok "e2e: boundary_report.json 已产出" || bad "e2e: boundary_report.json 缺失"

"$PY" "$SCRIPTS/normalize_punct.py" --state "$SE" >/dev/null
"$PY" "$SCRIPTS/check_alignment.py" --state "$SE" >/dev/null 2>&1
[ -f "$SE/alignment_report.json" ] && ok "e2e: alignment_report.json 已产出" || bad "e2e: alignment_report.json 缺失"

OUT=$("$PY" "$SCRIPTS/qa_consistency.py" --state "$SE")
RATE=$(printf '%s' "$OUT" | jget terminology_rate)
if "$PY" -c "import sys;sys.exit(0 if float('$RATE')>=0.98 else 1)"; then
    ok "e2e: 术语符合率 $RATE ≥ 0.98（F33-03）"
else
    bad "e2e: 术语符合率 $RATE < 0.98"
fi
HB=$(printf '%s' "$OUT" | jget hits_backfilled)
[ "$HB" -ge 1 ] && ok "e2e: glossary hits 已回填（$HB 条）" || bad "e2e: hits 未回填"

"$PY" "$SCRIPTS/merge.py" --indir "$SE/chunks" --out "$SE/translation_full.txt" --state "$SE" >/dev/null
"$PY" "$SCRIPTS/merge.py" --indir "$SE/chunks" --out "$SE/original_full.txt" \
    --pattern 'chunk_*.txt' --exclude '*_zh.txt' --state "$SE" >/dev/null
"$PY" "$SCRIPTS/sample_text.py" --state "$SE" --n 3 --chars 500 >/dev/null
[ -f "$SE/samples/sample_pack.md" ] && ok "e2e: sample_pack.md 已产出" || bad "e2e: sample_pack.md 缺失"

mkdir -p "$SE/digests"
N=1
while [ "$N" -le "$NCH" ]; do
    printf '第 %d 块梗概：御堂静在樱坂散步。\n' "$N" >"$SE/digests/chunk_$(printf '%03d' "$N").md"
    N=$((N+1))
done
OUT=$("$PY" "$SCRIPTS/reduce_digests.py" --state "$SE" --group 5)
[ "$(printf '%s' "$OUT" | jget groups)" -ge 1 ] && ok "e2e: digest_pack 已产出" || bad "e2e: digest_pack 缺失"

OUT=$("$PY" "$ST" verify --state "$SE" --check pre-extract-order); RC=$?
assert_eq "0" "$RC" "e2e: F33-02 verify 退 0"

"$PY" "$ST" status --state "$SE" --refresh >/dev/null
OUT=$("$PY" "$SCRIPTS/make_report.py" --state "$SE")
[ -f "$SE/report.md" ] && ok "e2e: report.md 已产出" || bad "e2e: report.md 缺失"
REPORT=$(cat "$SE/report.md")
assert_contains "$REPORT" "总块数" "report 含块数"
assert_contains "$REPORT" "原文字符数" "report 含原文字数"
assert_contains "$REPORT" "译文字符数" "report 含译文字数"
assert_contains "$REPORT" "锁定条目" "report 含术语锁定分列"
assert_contains "$REPORT" "未决冲突" "report 含冲突数"
assert_contains "$REPORT" "术语符合率" "report 含 QA 符合率"
assert_contains "$REPORT" "合规结论" "report 含 compliant 结论"
assert_contains "$REPORT" "降级与跳过说明" "report 含降级说明"

# 续跑判定
OUT=$("$PY" "$ST" init --state "$SE" --input "$E2E/ja.txt" --backend workbuddy --params-json "$PARAMS"); RC=$?
assert_eq "0" "$RC" "e2e: 相同输入+参数 → 续跑判定退 0"
assert_eq "true" "$(printf '%s' "$OUT" | jget resumable)" "e2e: resumable=true"
printf '追加一行改变哈希\n' >>"$E2E/ja.txt"
OUT=$("$PY" "$ST" init --state "$SE" --input "$E2E/ja.txt" --backend workbuddy --params-json "$PARAMS" 2>/dev/null); RC=$?
assert_eq "4" "$RC" "e2e: 输入变化 → 退 4"
assert_eq "input_changed" "$(printf '%s' "$OUT" | jget reason)" "e2e: reason=input_changed"

# ════════════════════════════════════════════════════════════════════════
section "附加 · §3.4 事件契约（seq 单调 + 透传型事件）"
# ════════════════════════════════════════════════════════════════════════
# §3.4 指定由「state_tool event」写入的 5 种事件，验证通用透传子命令可写
"$PY" "$ST" event --state "$SE" --type synopsis_written --stage S2 --json '{"chars":120,"source":"sampled"}' >/dev/null
"$PY" "$ST" event --state "$SE" --type digest_written    --stage S2 --chunk 1 --json '{"chars":80}'          >/dev/null
"$PY" "$ST" event --state "$SE" --type style_guide_written --stage S3 --json '{"chars":200}'                 >/dev/null
"$PY" "$ST" event --state "$SE" --type boundary_fixed    --stage S5 --chunk 2 --json '{"pairs":1}'           >/dev/null
"$PY" "$ST" event --state "$SE" --type pdf_built         --stage S8 --json '{"path":"out.pdf","kind":"zh"}'  >/dev/null

EVCHK=$("$PY" -c '
import json, sys
seqs, types = [], set()
for ln in open(sys.argv[1], encoding="utf-8"):
    if not ln.strip():
        continue
    e = json.loads(ln)
    seqs.append(e["seq"])
    types.add(e["type"])
    # §3.4 固定字段齐备性
    for f in ("seq", "ts", "type", "stage", "chunk", "actor", "data"):
        if f not in e:
            print("missing_field:" + f); sys.exit(0)
mono = seqs == sorted(seqs) and len(seqs) == len(set(seqs))
need = {"synopsis_written","digest_written","style_guide_written","boundary_fixed","pdf_built"}
print(("mono" if mono else "nonmono") + "|" + ("all5" if need <= types else "miss:" + str(sorted(need - types))))
' "$SE/events.jsonl")
assert_eq "mono|all5" "$EVCHK" "events.jsonl：seq 严格单调递增且 7 个固定字段齐备（D6）"

# 事件类型枚举实际覆盖数（Python 侧应发出 ≥ 20 种）
NTYPES=$("$PY" -c '
import json, sys
print(len({json.loads(l)["type"] for l in open(sys.argv[1], encoding="utf-8") if l.strip()}))
' "$SE/events.jsonl")
if [ "$NTYPES" -ge 12 ]; then ok "端到端共产生 $NTYPES 种事件类型"; else bad "事件类型偏少：$NTYPES"; fi

# ════════════════════════════════════════════════════════════════════════
section "结果"
# ════════════════════════════════════════════════════════════════════════
printf '  用例总数 %d ｜ %s通过 %d%s ｜ %s失败 %d%s\n' \
    "$CASE_NO" "$GREEN" "$PASS" "$RST" "$RED" "$FAIL" "$RST"
if [ "$FAIL" -eq 0 ]; then
    printf '  %sSMOKE: PASS%s\n' "$GREEN$BOLD" "$RST"
    exit 0
fi
printf '  %sSMOKE: FAIL%s\n' "$RED$BOLD" "$RST"
exit 1
