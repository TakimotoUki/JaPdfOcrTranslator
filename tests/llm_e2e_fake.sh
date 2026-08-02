#!/usr/bin/env bash
# llm_e2e_fake.sh — T08 判据 3/5：fake provider 48 块端到端（全程离线）
#
# 覆盖：
#   · 完整 DS 流水线：init → split(48 块) → sample → glossary init →
#     S4 五步硬时序（pre→hits→translate→post→mark）→ S5/S6/S7 → merge/report/export → finish → verify
#   · events 每块含 llm_call{stage:S4_translate}；state_tool.py verify 退 0（术语硬契约）
#   · F33-07 续跑：先跑 1–5 块（模拟中止），重跑只翻 6–48（events 验证不重译）
#
# 用法:
#   ./llm_e2e_fake.sh                  # 默认 python3
#   PY=/path/to/python3 ./llm_e2e_fake.sh
#   KEEP=1 ./llm_e2e_fake.sh           # 保留临时目录

set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Sources/JaPdfOcrTranslator/Resources/skills/jp-txt2pdf-translator/scripts" && pwd)"
PY="${PY:-python3}"
KEEP="${KEEP:-0}"
PASS=0; FAIL=0
RED=$'\033[31m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; BOLD=""; RST=""; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/t08_e2e.XXXXXX")"
cleanup() { [ "$KEEP" = "1" ] && echo "${BOLD}临时目录保留：$TMP${RST}" || rm -rf "$TMP"; }
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  %s✔%s %s\n' "$GREEN" "$RST" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  %s✘ %s%s\n' "$RED" "$1" "$RST"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 — 期望 [$1] 实际 [$2]"; fi; }

ST="$SCRIPTS/state_tool.py"
GT="$SCRIPTS/glossary_tool.py"
LT="$SCRIPTS/llm_tool.py"

# ── 生成 48 块输入（每块 = 1 个超长段落 ≈ 4200 字 → split 后恰好 48 块）──
"$PY" - "$TMP" <<'PYEOF'
import sys, random
random.seed(7)
out = sys.argv[1]
paras = []
for n in range(1, 49):
    # 每块 1 个段落：标题行 + 正文行（段落内单换行，段间空行）→ 单段 ≈ 4210 字 > target 4000 → 恰 48 块
    sentence = "御堂 静は桜坂の坂道を歩いていた。第{n}の場面である。風が静かに吹いている。"
    body = "".join(sentence.format(n=n) * 2 for _ in range(10))
    while len(body) < 4200:
        body += body[:800]
    paras.append("第{n}章 出会い\n".format(n=n) + body[:4200])
open(f"{out}/ja.txt", "w", encoding="utf-8").write("\n\n".join(paras) + "\n")
print("input generated")
PYEOF

STATE="$TMP/out/state"; mkdir -p "$STATE"
PARAMS='{"glossary_policy":"C","auto_glossary_enabled":true,"glossary_scope":"chunk","pre_extract_mode":"always","pre_extract_first_n":10,"enable_prescan":false,"enable_style_analysis":true,"enable_punct_normalize":true,"enable_qa":true,"enable_polish":false,"enable_resume":true,"max_chars_per_chunk":4000,"max_chars_per_paragraph":8000,"bilingual":false,"user_glossary_sha256":"","llm_provider":"fake"}'
FAKE_CFG="$TMP/fake.json"

five_step() {   # five_step <N>：S4 五步硬时序（与真实 DS 编排一致：pre/post 也走 llm_tool）
    local n="$1"
    # ① 译前预抽（llm_tool complete-json → value 交给 glossary_tool upsert）
    local pre
    pre=$("$PY" "$LT" complete-json --state "$STATE" --config-file "$FAKE_CFG" --tier cheap --stage S4_pre_extract \
        --user "预抽第${n}块" 2>/dev/null | "$PY" -c 'import json,sys;print(json.dumps(json.load(sys.stdin).get("value",{}),ensure_ascii=False))')
    printf '%s' "$pre" | "$PY" "$GT" upsert --state "$STATE" --chunk "$n" --phase pre --stdin >/dev/null
    # ② 命中裁剪
    "$PY" "$GT" hits --state "$STATE" --chunk "$n" --scope chunk --format md >/dev/null
    # ③ 翻译
    local zh
    zh=$("$PY" "$LT" complete --state "$STATE" --config-file "$FAKE_CFG" --tier strong --stage S4_translate \
        --system '【术语表策略｜情形 C：全自动术语表（默认）】' --user "翻译第${n}块" 2>/dev/null | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("text",""))')
    printf '%s\n' "$zh" > "$STATE/chunks/chunk_$(printf '%03d' "$n")_zh.txt"
    # ④ 译后回抽
    local post
    post=$("$PY" "$LT" complete-json --state "$STATE" --config-file "$FAKE_CFG" --tier cheap --stage S4_post_extract \
        --user "回抽第${n}块" 2>/dev/null | "$PY" -c 'import json,sys;print(json.dumps(json.load(sys.stdin).get("value",{}),ensure_ascii=False))')
    printf '%s' "$post" | "$PY" "$GT" upsert --state "$STATE" --chunk "$n" --phase post --stdin >/dev/null
    # ⑤ 落盘
    "$PY" "$ST" mark-chunk --state "$STATE" --chunk "$n" --value done --zh-chars "${#zh}" >/dev/null
}

# ── S0 初始化 ──
"$PY" "$ST" init --state "$STATE" --input "$TMP/ja.txt" --backend deepseek --params-json "$PARAMS" >/dev/null
# ── S1 切分 ──
N=$("$PY" "$SCRIPTS/split_text.py" --input "$TMP/ja.txt" --out "$STATE" --target 4000 --maxp 8000 --format json 2>/dev/null | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("chunks",0))')
echo "  切分块数: $N"
assert_eq "48" "$N" "split_text 产出 48 块"
# ── 动态生成 fake 规则（每块翻译响应 = 1 段，与源段落数一致 → S6 对齐通过）──
"$PY" - "$TMP" "$STATE" <<'PYEOF'
import json, sys, os
tmp, state = sys.argv[1], sys.argv[2]
rules = [
    {"when": {"stage": "S4_pre_extract"}, "respond": {"terms": [{"source": "御堂 静", "target": "御堂静", "type": "人物"}]}},
    {"when": {"stage": "S4_post_extract"}, "respond": {"terms": [{"source": "御堂 静", "target": "御堂静", "type": "人物"}]}},
    {"when": {"stage": "ping"}, "respond": {"text": "pong"}},
]
chunks = sorted(int(f[6:9]) for f in os.listdir(f"{state}/chunks") if f.startswith("chunk_") and f.endswith(".txt"))
for n in chunks:
    # 每块 1 段译文（段落数与源一致 → check_alignment 通过）
    rules.append({"when": {"stage": "S4_translate", "chunk": n},
                  "respond": {"text": f"第{n}块译文占位。御堂静站在樱坂上。"}})
with open(f"{tmp}/rules.jsonl", "w", encoding="utf-8") as fh:
    for r in rules:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
print("rules generated for", len(chunks), "chunks")
PYEOF
cat > "$FAKE_CFG" <<JSON
{"provider":"fake","fake_script":"$TMP/rules.jsonl","tiers":{"strong":{"model":"fake-model","options":{"thinking":false}},"cheap":{"model":"fake-model","options":{"thinking":false}},"fast":{"model":"fake-model","options":{"thinking":false}}}}
JSON

# ── S3 抽样 + 初始术语表 ──
"$PY" "$SCRIPTS/sample_text.py" --state "$STATE" --n 3 --chars 3000 >/dev/null
"$PY" "$GT" init --state "$STATE" --policy C >/dev/null

# ── Phase A：先跑 1–5 块（模拟任务到第 5 块中止）──
for n in 1 2 3 4 5; do five_step "$n"; done
DONE_A=$("$PY" "$ST" status --state "$STATE" --format json | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("chunks_done",0))')
assert_eq "5" "$DONE_A" "Phase A 完成 5 块（中止点）"

# ── Phase B：重跑（断点续跑判定）──
INIT_OUT=$("$PY" "$ST" init --state "$STATE" --input "$TMP/ja.txt" --backend deepseek --params-json "$PARAMS")
RES=$(printf '%s' "$INIT_OUT" | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("resumable"))')
assert_eq "True" "$RES" "F33-07 重跑 init → resumable=true"
PENDING=$("$PY" "$ST" pending --state "$STATE" | "$PY" -c 'import json,sys;d=json.load(sys.stdin);print(",".join(map(str,d["pending"])))')
echo "  续跑 pending: $PENDING"
case "$PENDING" in
    6,7,8,9,10,*) ok "Phase B 只 pending 6–48（前 5 块不重译）" ;;
    *) bad "pending 未从 6 开始：${PENDING:0:40}…" ;;
esac
for n in $(seq 6 "$N"); do five_step "$n"; done
TOTAL_DONE=$("$PY" "$ST" status --state "$STATE" --format json | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("chunks_done",0))')
assert_eq "48" "$TOTAL_DONE" "Phase B 完成后共 48 块 done"

# ── S5 / S6 / S7 ──
"$PY" "$SCRIPTS/check_boundaries.py" --state "$STATE" >/dev/null 2>&1
"$PY" "$SCRIPTS/check_alignment.py" --state "$STATE" >/dev/null 2>&1
"$PY" "$SCRIPTS/normalize_punct.py" --state "$STATE" >/dev/null
"$PY" "$SCRIPTS/qa_consistency.py" --state "$STATE" --fail-on error --min-term-rate 0.98 >/dev/null 2>&1
"$PY" "$GT" conflicts --state "$STATE" --fail-if-open >/dev/null 2>&1

# ── S8 合并 + 报告 + 导出 + finish（build_pdf 依赖 reportlab，可选跳过）──
"$PY" "$SCRIPTS/merge.py" --indir "$STATE/chunks" --out "$STATE/translation_full.txt" --pattern 'chunk_*_zh.txt' --state "$STATE" >/dev/null
"$PY" "$SCRIPTS/merge.py" --indir "$STATE/chunks" --out "$STATE/original_full.txt" --pattern 'chunk_*.txt' --exclude '*_zh.txt' --state "$STATE" >/dev/null
"$PY" "$SCRIPTS/make_report.py" --state "$STATE" >/dev/null
"$PY" "$GT" export --state "$STATE" --out "$STATE/glossary_export.csv" --format csv5 --origin auto >/dev/null
"$PY" "$ST" status --state "$STATE" --finish --message "全流程完成" >/dev/null

# ── verify 退 0（术语硬契约）──
"$PY" "$ST" verify --state "$STATE" --check all >/dev/null 2>&1; RC=$?
assert_eq "0" "$RC" "state_tool.py verify 退 0（F33-02 术语硬契约保持）"

# ── 事件断言 ──
EV=$("$PY" -c '
import json, sys
translate = 0; translated = 0; per_chunk = {}
for ln in open(sys.argv[1], encoding="utf-8"):
    if not ln.strip(): continue
    e = json.loads(ln)
    if e.get("type") == "llm_call" and e.get("data", {}).get("stage") == "S4_translate":
        translate += 1
    if e.get("type") == "chunk_translated":
        translated += 1
        per_chunk[e.get("chunk")] = per_chunk.get(e.get("chunk"), 0) + 1
dup = [k for k, v in per_chunk.items() if v > 1]
print(f"{translate}|{translated}|{len(per_chunk)}|{dup}")
' "$STATE/events.jsonl")
IFS='|' read -r LLM_TRANS CH_TRANS CH_COUNT DUP <<< "$EV"
assert_eq "48" "$LLM_TRANS" "events 含 48 条 llm_call{stage:S4_translate}"
assert_eq "48" "$CH_TRANS" "events 含 48 条 chunk_translated"
assert_eq "48" "$CH_COUNT" "48 个不同块各恰 1 次 chunk_translated（无重译 → F33-07 续跑成立）"

# ── usage 落盘 ──
USG=$("$PY" -c '
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print(d["totals"]["calls"])
' "$STATE/usage.json" 2>/dev/null || echo 0)
echo "  usage.json totals.calls = ${USG}（应 = 144 = 48×3）"
[ "$USG" -ge 144 ] && ok "usage.json 累计调用 ≥ 144（48 块 × 3 次 LLM）" || bad "usage.json 调用数不足：$USG"

printf '\n%s══ 结果 ══%s\n' "$BOLD" "$RST"
printf '  用例总数 %d ｜ %s通过 %d%s ｜ %s失败 %d%s\n' "$((PASS+FAIL))" "$GREEN" "$PASS" "$RST" "$RED" "$FAIL" "$RST"
if [ "$FAIL" -eq 0 ]; then printf '  %sLLM-E2E-FAKE: PASS%s\n' "$GREEN$BOLD" "$RST"; exit 0; fi
printf '  %sLLM-E2E-FAKE: FAIL%s\n' "$RED$BOLD" "$RST"; exit 1
