#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_glossary_tool.py — P0 术语库引擎验收（DESIGN-v3.3 §4.1–§4.9）

对应用户原话需求的四个要点：
  ① 用户编辑过术语表 → **必须使用用户的术语表**   → A/B 策略 + locked 优先级
  ② 否则 → **自动生成术语表**                     → C 策略
  ③ **每次分块翻译之前必须先更新这一块的术语表**   → upsert --phase pre + hits --chunk
  ④ 翻译时**严格遵循**术语表                       → render / hits 的可注入文本

本文件只做**只读**调用，绝不修改 Sources/ 下任何文件。
"""

from __future__ import annotations

import json
import os
import unittest

from qa_harness import (
    EXIT_CHECK, EXIT_INPUT, EXIT_OK, EXIT_STATE, EXIT_USAGE,
    ScriptTestCase, g,
)


# ══════════════════════════════════════════════════════════════════════════
# 1. init 与策略推导
# ══════════════════════════════════════════════════════════════════════════

class TestInit(ScriptTestCase):
    """§4.1 init：策略约束、幂等、用户词条属性。"""

    def test_init_c_creates_empty_store(self) -> None:
        r = self.init_policy_c()
        self.assertOk(r, "C 策略 init 应成功")
        self.assertTrue(r.get("created"))
        self.assertEqual(r.get("policy"), "C")
        self.assertEqual(r.get("terms"), 0)
        self.assertEqual(self.glossary()["policy"], "C")
        self.assertEqual(self.glossary()["terms"], [])

    def test_init_d_creates_empty_store(self) -> None:
        r = self.init_policy_d()
        self.assertOk(r, "D 策略 init 应成功（逃生口）")
        self.assertEqual(self.glossary()["policy"], "D")

    def test_init_a_user_terms_are_user_and_locked(self) -> None:
        """需求①：用户表词条必须 origin=user 且 locked=true。"""
        r = self.init_with_user("A")
        self.assertOk(r)
        self.assertEqual(r.get("terms"), 2)
        self.assertEqual(r.get("locked"), 2)
        self.assertEqual(r.get("auto"), 0)
        for term in self.glossary()["terms"]:
            self.assertEqual(term["origin"], "user", f"{term['source']} 应为 user")
            self.assertTrue(term["locked"], f"{term['source']} 应 locked")
            self.assertEqual(term["status"], "ok")
            self.assertIsNone(term["first_chunk"], "init 种子 first_chunk 应为 null")

    def test_init_b_user_terms_are_user_and_locked(self) -> None:
        r = self.init_with_user("B")
        self.assertOk(r)
        self.assertTrue(all(t["locked"] for t in self.glossary()["terms"]))

    def test_init_a_without_user_glossary_is_usage_error(self) -> None:
        """A/B 必须给用户表，否则策略推导本身就是错的 → 退 1。"""
        r = g("init", "--state", self.state, "--policy", "A")
        self.assertCode(r, EXIT_USAGE, "A 缺用户表应退 1")

    def test_init_b_with_empty_user_csv_is_usage_error(self) -> None:
        path = self.user_csv("日语,中文\n")           # 只有表头
        r = g("init", "--state", self.state, "--policy", "B", "--user-csv", path)
        self.assertCode(r, EXIT_USAGE, "B 的用户表解析后 0 条应退 1")

    def test_init_is_idempotent_without_force(self) -> None:
        """续跑的关键：重复 init 不得清空已有术语库。"""
        self.init_with_user("B")
        self.upsert([{"source": "氷刃", "target": "冰刃"}])
        before = self.terms_by_source()
        r = self.init_with_user("B")
        self.assertOk(r)
        self.assertFalse(r.get("created"), "第二次 init 应 created=false")
        self.assertEqual(set(self.terms_by_source()), set(before),
                         "幂等 init 不得改变词条集合")

    def test_init_force_rebuilds(self) -> None:
        self.init_with_user("B")
        self.upsert([{"source": "氷刃", "target": "冰刃"}])
        path = self.user_csv("日语,中文\n御堂 静,御堂静\n氷室,冰室\n")
        r = g("init", "--state", self.state, "--policy", "B",
              "--user-csv", path, "--force")
        self.assertOk(r)
        self.assertTrue(r.get("created"))
        self.assertNotIn("氷刃", self.terms_by_source(), "--force 应丢弃自动词条")

    def test_init_mutually_exclusive_csv_json(self) -> None:
        csv_path = self.user_csv("日语,中文\nA,甲\n")
        json_path = self.write_root("u.json", json.dumps({"terms": []}))
        r = g("init", "--state", self.state, "--policy", "B",
              "--user-csv", csv_path, "--user-json", json_path)
        self.assertCode(r, EXIT_USAGE, "--user-csv 与 --user-json 互斥应退 1")

    def test_init_writes_glossary_init_event(self) -> None:
        self.init_with_user("B")
        kinds = [e["type"] for e in self.events()]
        self.assertIn("glossary_init", kinds)
        ev = next(e for e in self.events() if e["type"] == "glossary_init")
        self.assertEqual(ev["data"]["policy"], "B")
        self.assertEqual(ev["data"]["user_terms"], 2)

    def test_init_five_column_csv(self) -> None:
        rows = ("日语,中文,类型,来源,备注\n"
                "御堂 静,御堂静,人物,用户,女主角\n"
                "氷室,冰室,地名,用户,\n")
        r = self.init_with_user("B", rows)
        self.assertOk(r)
        terms = self.terms_by_source()
        self.assertEqual(terms["御堂 静"]["type"], "人物")
        self.assertEqual(terms["御堂 静"]["note"], "女主角")
        self.assertEqual(terms["氷室"]["type"], "地名")

    def test_init_unknown_type_falls_back_to_other(self) -> None:
        """§3.6：未知 type 一律归「其他」。"""
        rows = "日语,中文,类型,来源,备注\n妖刀,妖刀,兵器,用户,\n"
        self.init_with_user("B", rows)
        self.assertEqual(self.terms_by_source()["妖刀"]["type"], "其他")

    def test_init_schema_version_guard(self) -> None:
        """读到高于本 skill 的 schema_version 必须拒绝，不得用旧代码改写新数据。"""
        self.init_policy_c()
        data = self.glossary()
        data["schema_version"] = 99
        self.write("glossary.json", json.dumps(data, ensure_ascii=False))
        r = g("stats", "--state", self.state)
        self.assertCode(r, EXIT_STATE, "schema_version 过高应拒绝")

    def test_init_on_missing_state_dir_exits_4(self) -> None:
        r = g("init", "--state", os.path.join(self.root, "nope"), "--policy", "C")
        self.assertCode(r, EXIT_STATE, "state 目录不存在应退 4")


# ══════════════════════════════════════════════════════════════════════════
# 2. upsert 判定表（§4.2）—— 用户需求①②③ 的核心
# ══════════════════════════════════════════════════════════════════════════

class TestUpsertDecisionTable(ScriptTestCase):

    # ── 策略 A：纯用户表，禁止任何自动新增 ─────────────────────────
    def test_policy_a_rejects_brand_new_auto_term(self) -> None:
        """需求①：A 下 auto 新词必须 rejected_by_policy（不是 inserted）。"""
        self.init_with_user("A")
        before = len(self.glossary()["terms"])
        r = self.upsert([{"source": "氷刃", "target": "冰刃"}])
        self.assertOk(r, "业务性拒绝仍必须退 0")
        self.assertEqual(r.get("summary.rejected_by_policy"), 1)
        self.assertEqual(r.get("summary.inserted"), 0)
        self.assertEqual(len(self.glossary()["terms"]), before,
                         "A 下不得新增任何词条")

    def test_policy_a_locked_term_target_is_immutable(self) -> None:
        """需求①：任何 auto 改写 locked 词条 → rejected_by_lock 且 target 不变。"""
        self.init_with_user("A")
        r = self.upsert([{"source": "御堂 静", "target": "米堂静"}])
        self.assertOk(r)
        self.assertEqual(r.get("summary.rejected_by_lock"), 1)
        self.assertEqual(self.terms_by_source()["御堂 静"]["target"], "御堂静",
                         "锁定词条 target 必须逐字不变")

    def test_policy_a_same_target_merges_aliases_only(self) -> None:
        """A 下允许对已有词条补别名（§4.2：locked + 同 target → unchanged + 合并）。"""
        self.init_with_user("A")
        r = self.upsert([{"source": "御堂 静", "target": "御堂静",
                          "aliases": ["静ちゃん", "御堂 静"], "note": "女主角"}])
        self.assertOk(r)
        self.assertEqual(r.get("summary.unchanged"), 1)
        term = self.terms_by_source()["御堂 静"]
        self.assertEqual(term["aliases"], ["静ちゃん"],
                         "别名应去重且剔除等于 source 的项")
        self.assertEqual(term["note"], "女主角", "空字段应被补齐")
        self.assertEqual(term["target"], "御堂静")

    # ── 策略 B：用户表打底 + 自动补充 ───────────────────────────────
    def test_policy_b_inserts_new_auto_term(self) -> None:
        self.init_with_user("B")
        r = self.upsert([{"source": "氷刃", "target": "冰刃", "type": "招式"}])
        self.assertOk(r)
        self.assertEqual(r.get("summary.inserted"), 1)
        term = self.terms_by_source()["氷刃"]
        self.assertEqual(term["origin"], "auto")
        self.assertFalse(term["locked"])
        self.assertEqual(term["status"], "ok")
        self.assertEqual(term["type"], "招式")

    def test_policy_b_rejects_rewrite_of_locked_and_logs_evidence(self) -> None:
        """需求①：B 下用户词条不可被自动改写，且必须留证据。"""
        self.init_with_user("B")
        r = self.upsert([{"source": "氷室", "target": "冰之室"}])
        self.assertOk(r)
        self.assertEqual(r.get("summary.rejected_by_lock"), 1)
        self.assertEqual(self.terms_by_source()["氷室"]["target"], "冰室")
        self.assertEqual(self.terms_by_source()["氷室"]["status"], "ok",
                         "§4.2：rejected_by_lock 不得改 status")
        conflicts = self.conflicts()
        self.assertEqual(len(conflicts), 1)
        self.assertEqual(conflicts[0]["resolution"], "rejected_by_lock")
        self.assertTrue(conflicts[0]["resolved"], "锁定冲突创建即已裁决")
        self.assertEqual(conflicts[0]["resolved_by"], "system")
        self.assertEqual(r.get("rejected_by_lock")[0]["locked_target"], "冰室")

    def test_policy_b_rejected_lock_does_not_enter_open_queue(self) -> None:
        self.init_with_user("B")
        self.upsert([{"source": "氷室", "target": "冰之室"}])
        r = g("conflicts", "--state", self.state)
        self.assertOk(r)
        self.assertEqual(r.get("open"), 0, "rejected_by_lock 不进待裁决队列")
        self.assertEqual(r.get("total"), 1)

    # ── 策略 C：纯自动 ──────────────────────────────────────────────
    def test_policy_c_auto_generates_terms(self) -> None:
        """需求②：无用户表时必须能自动建表。"""
        self.init_policy_c()
        r = self.upsert([{"source": "氷室", "target": "冰室", "type": "地名"},
                         {"source": "御堂 静", "target": "御堂静", "type": "人物"}],
                        "--chunk", "1", "--phase", "pre")
        self.assertOk(r)
        self.assertEqual(r.get("summary.inserted"), 2)
        self.assertEqual(len(self.glossary()["terms"]), 2)
        self.assertTrue(all(t["origin"] == "auto" for t in self.glossary()["terms"]))

    def test_policy_c_conflict_keeps_existing_value(self) -> None:
        """§4.2：未锁定 + 不同 target → conflict，保留现值，绝不静默覆盖。"""
        self.init_policy_c()
        self.upsert([{"source": "白鷺", "target": "白鹭"}])
        r = self.upsert([{"source": "白鷺", "target": "白鹭鸶"}], "--chunk", "3",
                        "--phase", "post")
        self.assertOk(r)
        self.assertEqual(r.get("summary.conflict"), 1)
        term = self.terms_by_source()["白鷺"]
        self.assertEqual(term["target"], "白鹭", "必须保留现值")
        self.assertEqual(term["status"], "conflict")
        conflicts = self.conflicts()
        self.assertEqual(len(conflicts), 1)
        self.assertFalse(conflicts[0]["resolved"])
        self.assertEqual(conflicts[0]["resolution"], "")
        self.assertEqual(conflicts[0]["chunk"], 3)
        self.assertEqual(conflicts[0]["phase"], "post")

    def test_policy_c_same_target_is_unchanged(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "白鷺", "target": "白鹭"}])
        r = self.upsert([{"source": "白鷺", "target": "白鹭"}])
        self.assertEqual(r.get("summary.unchanged"), 1)
        self.assertEqual(len(self.conflicts()), 0)

    def test_first_chunk_is_frozen_on_first_sight(self) -> None:
        """§4.2 注：first_chunk 一旦写入永不更新。"""
        self.init_policy_c()
        self.upsert([{"source": "氷室", "target": "冰室"}], "--chunk", "7",
                    "--phase", "pre")
        self.assertEqual(self.terms_by_source()["氷室"]["first_chunk"], 7)
        self.upsert([{"source": "氷室", "target": "冰室"}], "--chunk", "19",
                    "--phase", "pre")
        self.assertEqual(self.terms_by_source()["氷室"]["first_chunk"], 7,
                         "first_chunk 必须定格在首次出现的块号")

    # ── 策略 D：无术语约束 ──────────────────────────────────────────
    def test_policy_d_rejects_everything_by_policy(self) -> None:
        self.init_policy_d()
        r = self.upsert([{"source": "氷室", "target": "冰室"}])
        self.assertOk(r, "D 下拒绝也必须退 0")
        self.assertEqual(r.get("summary.rejected_by_policy"), 1)
        self.assertEqual(self.glossary()["terms"], [])

    def test_policy_d_hits_returns_empty_not_error(self) -> None:
        """需求④的边界：D 下 hits 必须返回空而不是报错。"""
        self.init_policy_d()
        self.chunk(1, "氷室の前で御堂 静が立っていた。\n")
        r = g("hits", "--state", self.state, "--chunk", "1")
        self.assertOk(r, "D 下 hits 不得报错")
        self.assertEqual(r.get("count"), 0)
        self.assertEqual(r.get("terms"), [])

    def test_policy_d_render_emits_policy_d_prompt(self) -> None:
        self.init_policy_d()
        self.chunk(1, "本文。\n")
        r = g("render", "--state", self.state, "--chunk", "1", "--policy")
        self.assertOk(r)
        self.assertIn("情形 D：不维护术语表", r.out)
        self.assertIn("【本块命中术语】（暂无）", r.out)

    # ── invalid ─────────────────────────────────────────────────────
    def test_empty_source_or_target_is_invalid(self) -> None:
        self.init_policy_c()
        r = self.upsert([{"source": "", "target": "甲"},
                         {"source": "乙", "target": ""},
                         {"source": "   ", "target": "  "}])
        self.assertOk(r)
        self.assertEqual(r.get("summary.invalid"), 3)
        self.assertEqual(self.glossary()["terms"], [])

    def test_summary_enum_uses_inserted_not_added(self) -> None:
        """主理人拍板：upsert 判定枚举统一为 inserted，stdout 不得出现 added。"""
        self.init_policy_c()
        r = self.upsert([{"source": "氷室", "target": "冰室"}])
        summary = r.get("summary")
        self.assertIn("inserted", summary)
        self.assertNotIn("added", summary,
                         "upsert 的 summary 不应残留 v3.2 的 added 字段")

    def test_pre_extract_event_data_uses_inserted_not_added(self) -> None:
        """事件 data 同样应统一为 inserted（§3.4 与 §4.2 的命名分歧点）。"""
        self.init_policy_c()
        self.upsert([{"source": "氷室", "target": "冰室"}], "--chunk", "1",
                    "--phase", "pre")
        ev = next(e for e in self.events() if e["type"] == "glossary_pre_extract")
        self.assertNotIn("added", ev["data"],
                         "glossary_pre_extract 事件 data 不应残留 added 字段")


# ══════════════════════════════════════════════════════════════════════════
# 3. upsert 的 CLI / 输入校验（§4.0 退出码）
# ══════════════════════════════════════════════════════════════════════════

class TestUpsertCli(ScriptTestCase):

    def test_empty_terms_array_is_legal(self) -> None:
        """F33-02：即使一条新词都没有也必须能调用一次，留下合规证据。"""
        self.init_policy_c()
        r = self.upsert([], "--chunk", "5", "--phase", "pre")
        self.assertOk(r, "{\"terms\":[]} 必须合法")
        self.assertEqual(r.get("summary.inserted"), 0)
        events = [e for e in self.events() if e["type"] == "glossary_pre_extract"]
        self.assertEqual(len(events), 1, "空数组也必须留下 pre_extract 事件")
        self.assertEqual(events[0]["chunk"], 5)
        self.assertEqual(events[0]["stage"], "S4")

    def test_phase_requires_chunk(self) -> None:
        self.init_policy_c()
        r = g("upsert", "--state", self.state, "--phase", "pre", "--stdin",
              stdin='{"terms":[]}')
        self.assertCode(r, EXIT_USAGE, "--phase 无 --chunk 应退 1")

    def test_stdin_and_file_are_mutually_exclusive(self) -> None:
        self.init_policy_c()
        path = self.write_root("t.json", '{"terms":[]}')
        r = g("upsert", "--state", self.state, "--stdin", "--file", path,
              stdin='{"terms":[]}')
        self.assertCode(r, EXIT_USAGE)

    def test_neither_stdin_nor_file(self) -> None:
        self.init_policy_c()
        r = g("upsert", "--state", self.state)
        self.assertCode(r, EXIT_USAGE)

    def test_malformed_stdin_json_exits_3(self) -> None:
        self.init_policy_c()
        r = g("upsert", "--state", self.state, "--stdin", stdin="{not json")
        self.assertCode(r, EXIT_INPUT, "stdin 非法 JSON 应退 3")

    def test_terms_not_array_exits_3(self) -> None:
        self.init_policy_c()
        r = g("upsert", "--state", self.state, "--stdin",
              stdin='{"terms":{"source":"a"}}')
        self.assertCode(r, EXIT_INPUT, "terms 非数组应退 3")

    def test_terms_element_not_object_exits_3(self) -> None:
        self.init_policy_c()
        r = g("upsert", "--state", self.state, "--stdin", stdin='{"terms":["x"]}')
        self.assertCode(r, EXIT_INPUT)

    def test_empty_stdin_exits_3(self) -> None:
        self.init_policy_c()
        r = g("upsert", "--state", self.state, "--stdin", stdin="")
        self.assertCode(r, EXIT_INPUT)

    def test_stdin_with_bom_is_accepted(self) -> None:
        self.init_policy_c()
        r = g("upsert", "--state", self.state, "--stdin",
              stdin='\ufeff{"terms":[{"source":"氷室","target":"冰室"}]}')
        self.assertOk(r, "§4.0：输入 JSON 允许 BOM")
        self.assertEqual(r.get("summary.inserted"), 1)

    def test_uninitialized_store_exits_4(self) -> None:
        r = g("upsert", "--state", self.state, "--stdin", stdin='{"terms":[]}')
        self.assertCode(r, EXIT_STATE, "术语库未初始化应退 4")

    def test_missing_required_arg_is_usage_error(self) -> None:
        """§4.0：缺参属于「用法/参数错误」，退出码必须是 1。"""
        r = g("stats")
        self.assertCode(r, EXIT_USAGE, "缺 --state 应退 1（契约 §4.0）")

    def test_invalid_policy_value_is_usage_error(self) -> None:
        r = g("init", "--state", self.state, "--policy", "Z")
        self.assertCode(r, EXIT_USAGE, "非法 --policy 应退 1（契约 §4.0）")

    def test_stdout_is_single_json_object(self) -> None:
        """§4.0：stdout 必须是单个 JSON 对象，不得有多余打印。"""
        self.init_policy_c()
        r = self.upsert([{"source": "氷室", "target": "冰室"}])
        self.assertEqual(len(r.out.strip().splitlines()), 1)
        self.assertIsInstance(r.json, dict)


# ══════════════════════════════════════════════════════════════════════════
# 4. hits —— 需求③「每块译前更新本块术语表」的落地点（§4.3）
# ══════════════════════════════════════════════════════════════════════════

class TestHits(ScriptTestCase):

    def seed(self) -> None:
        self.init_policy_c()
        self.upsert([
            {"source": "御堂 静", "target": "御堂静", "type": "人物",
             "aliases": ["静ちゃん"], "gender": "女", "reading": "みどう しずか",
             "note": "女主角"},
            {"source": "氷室", "target": "冰室", "type": "地名"},
            {"source": "白鷺", "target": "白鹭", "type": "地名"},
            {"source": "旦那様", "target": "老爷", "type": "敬称",
             "aliases": ["旦那"]},
        ])

    def test_only_terms_present_in_chunk_are_returned(self) -> None:
        """裁剪正确性：不能整表倾泻。"""
        self.seed()
        self.chunk(1, "氷室の門をくぐる。\n")
        r = g("hits", "--state", self.state, "--chunk", "1")
        self.assertOk(r)
        self.assertEqual([t["source"] for t in r.get("terms")], ["氷室"])
        self.assertEqual(r.get("count"), 1)
        self.assertFalse(r.get("truncated"))

    def test_alias_hit_counts(self) -> None:
        self.seed()
        self.chunk(2, "静ちゃんは笑った。\n")
        r = g("hits", "--state", self.state, "--chunk", "2")
        self.assertEqual([t["source"] for t in r.get("terms")], ["御堂 静"],
                         "别名命中必须算数")

    def test_source_only_types_ignore_aliases(self) -> None:
        """§3.6：称谓/敬称/口癖/固定表达四类只按 source 匹配。"""
        self.seed()
        self.chunk(3, "旦那と呼ばれた。\n")           # 只有别名「旦那」
        r = g("hits", "--state", self.state, "--chunk", "3")
        self.assertEqual(r.get("count"), 0,
                         "敬称类的 alias 不应参与匹配")
        self.chunk(4, "旦那様と呼ばれた。\n")
        r = g("hits", "--state", self.state, "--chunk", "4")
        self.assertEqual([t["source"] for t in r.get("terms")], ["旦那様"])

    def test_no_match_returns_empty(self) -> None:
        self.seed()
        self.chunk(5, "空は青い。\n")
        r = g("hits", "--state", self.state, "--chunk", "5")
        self.assertEqual(r.get("count"), 0)

    def test_nfkc_fullwidth_halfwidth_equivalence(self) -> None:
        """§4.3 步骤 1：NFKC 归一化后匹配。全角 ABC 应命中半角术语。"""
        self.init_policy_c()
        self.upsert([{"source": "ABC社", "target": "ABC公司"}])
        self.chunk(1, "ＡＢＣ社の社長。\n")
        r = g("hits", "--state", self.state, "--chunk", "1")
        self.assertEqual(r.get("count"), 1, "全角/半角应经 NFKC 等价")

    def test_katakana_halfwidth_normalizes(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "カメラ", "target": "相机"}])
        self.chunk(1, "ｶﾒﾗを持って。\n")             # 半角片假名
        r = g("hits", "--state", self.state, "--chunk", "1")
        self.assertEqual(r.get("count"), 1, "半角片假名应经 NFKC 命中")

    def test_iteration_mark_and_long_vowel_and_ke(self) -> None:
        """日文特殊字符：々 / 長音ー / ヶ 必须能原样匹配。"""
        self.init_policy_c()
        self.upsert([{"source": "佐々木", "target": "佐佐木", "type": "人物"},
                     {"source": "コーヒー", "target": "咖啡", "type": "物品"},
                     {"source": "関ヶ原", "target": "关原", "type": "地名"}])
        self.chunk(1, "佐々木はコーヒーを飲みながら関ヶ原の話をした。\n")
        r = g("hits", "--state", self.state, "--chunk", "1")
        self.assertEqual(sorted(t["source"] for t in r.get("terms")),
                         sorted(["佐々木", "コーヒー", "関ヶ原"]))

    def test_overlapping_terms_both_reported(self) -> None:
        """重叠术语：§4.3 步骤 6「任一键命中即命中」，长短词都会返回。

        本用例锁定当前契约语义，同时暴露风险：注入的术语块里会同时出现
        「田中→A」与「田中太郎→B」两条指令。
        """
        self.init_policy_c()
        self.upsert([{"source": "田中", "target": "田中", "type": "人物"},
                     {"source": "田中太郎", "target": "田中太郎", "type": "人物"}])
        self.chunk(1, "田中太郎が来た。\n")
        r = g("hits", "--state", self.state, "--chunk", "1")
        self.assertEqual(sorted(t["source"] for t in r.get("terms")),
                         ["田中", "田中太郎"],
                         "契约为「任一键命中即命中」，两条都应返回")

    def test_ascii_word_boundary(self) -> None:
        """§4.3 步骤 3：Ann 不应命中 Anna。"""
        self.init_policy_c()
        self.upsert([{"source": "Ann", "target": "安"}])
        self.chunk(1, "Anna went home.\n")
        r = g("hits", "--state", self.state, "--chunk", "1")
        self.assertEqual(r.get("count"), 0, "ASCII 键必须有词边界保护")
        self.chunk(2, "Ann went home.\n")
        r = g("hits", "--state", self.state, "--chunk", "2")
        self.assertEqual(r.get("count"), 1)

    def test_ascii_case_insensitive(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "Ann", "target": "安"}])
        self.chunk(1, "ANN went home.\n")
        r = g("hits", "--state", self.state, "--chunk", "1")
        self.assertEqual(r.get("count"), 1, "casefold 后应大小写不敏感")

    def test_cyrillic_word_boundary(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "гад", "target": "坏蛋"}])
        self.chunk(1, "гадкий человек\n")
        r = g("hits", "--state", self.state, "--chunk", "1")
        self.assertEqual(r.get("count"), 0, "西里尔字母也需要词边界保护")

    def test_scope_full_returns_whole_table(self) -> None:
        self.seed()
        self.chunk(1, "無関係な文章。\n")
        r = g("hits", "--state", self.state, "--chunk", "1", "--scope", "full")
        self.assertEqual(r.get("count"), 4)

    def test_max_truncation_prefers_locked(self) -> None:
        """§4.3：超上限时 locked 优先，并报 truncated:true。"""
        self.init_with_user("B")                       # 御堂 静 / 氷室 为 locked
        self.upsert([{"source": "白鷺", "target": "白鹭"},
                     {"source": "氷刃", "target": "冰刃"}])
        self.chunk(1, "御堂 静と氷室と白鷺と氷刃。\n")
        r = g("hits", "--state", self.state, "--chunk", "1", "--max", "2")
        self.assertOk(r)
        self.assertTrue(r.get("truncated"))
        self.assertEqual(r.get("count"), 2)
        self.assertTrue(all(t["locked"] for t in r.get("terms")),
                        "截断时必须优先保留 locked 词条")

    def test_missing_chunk_file_exits_4(self) -> None:
        self.seed()
        r = g("hits", "--state", self.state, "--chunk", "99")
        self.assertCode(r, EXIT_STATE, "块文件不存在应退 4")

    def test_hits_without_text_source_is_usage_error(self) -> None:
        self.seed()
        r = g("hits", "--state", self.state)
        self.assertCode(r, EXIT_USAGE)

    def test_text_file_and_stdin_text(self) -> None:
        self.seed()
        path = self.write_root("t.txt", "氷室と白鷺。\n")
        r = g("hits", "--state", self.state, "--text-file", path)
        self.assertEqual(r.get("count"), 2)
        r = g("hits", "--state", self.state, "--stdin-text", stdin="御堂 静。\n")
        self.assertEqual(r.get("count"), 1)

    def test_no_event_flag(self) -> None:
        self.seed()
        self.chunk(1, "氷室。\n")
        before = len([e for e in self.events() if e["type"] == "glossary_hits"])
        g("hits", "--state", self.state, "--chunk", "1", "--no-event")
        self.assertEqual(len([e for e in self.events()
                              if e["type"] == "glossary_hits"]), before,
                         "--no-event 时不得写事件")
        g("hits", "--state", self.state, "--chunk", "1")
        self.assertEqual(len([e for e in self.events()
                              if e["type"] == "glossary_hits"]), before + 1)

    def test_md_format_sections(self) -> None:
        self.init_with_user("B")
        self.upsert([{"source": "氷刃", "target": "冰刃", "type": "招式"}])
        self.chunk(1, "御堂 静が氷刃を放つ。\n")
        r = g("hits", "--state", self.state, "--chunk", "1", "--format", "md")
        self.assertOk(r)
        self.assertIn("【本块命中术语（必须遵守）】", r.out)
        self.assertIn("■ 锁定词条（用户提供，逐字执行，不得改写）", r.out)
        self.assertIn("■ 自动词条（软件维护，如需修正请记冲突，勿直接改译）", r.out)
        self.assertIn("- 御堂 静 → 御堂静", r.out)
        self.assertIn("- 氷刃 → 冰刃（招式）", r.out)

    def test_md_format_empty(self) -> None:
        self.init_policy_c()
        self.chunk(1, "何もない。\n")
        r = g("hits", "--state", self.state, "--chunk", "1", "--format", "md")
        self.assertEqual(r.out.strip(), "【本块命中术语】（暂无）")

    def test_csv_format_header(self) -> None:
        self.seed()
        self.chunk(1, "氷室。\n")
        r = g("hits", "--state", self.state, "--chunk", "1", "--format", "csv")
        self.assertOk(r)
        self.assertEqual(r.out.splitlines()[0], "日语,中文,类型,来源,备注")

    def test_hits_is_byte_deterministic(self) -> None:
        """需求④的前提：同样输入两次调用输出必须逐字节相同。"""
        self.seed()
        self.chunk(1, "御堂 静と氷室と白鷺と旦那様。\n")
        a = g("hits", "--state", self.state, "--chunk", "1",
              "--format", "md", "--no-event").out
        b = g("hits", "--state", self.state, "--chunk", "1",
              "--format", "md", "--no-event").out
        self.assertEqual(a, b)
        self.assertEqual(a.encode(), b.encode())


# ══════════════════════════════════════════════════════════════════════════
# 5. render —— 两后端注入术语约束的唯一函数（§4.4 / §7.2）
# ══════════════════════════════════════════════════════════════════════════

class TestRender(ScriptTestCase):

    def test_render_is_byte_deterministic(self) -> None:
        self.init_with_user("B")
        self.upsert([{"source": "氷刃", "target": "冰刃", "type": "招式"},
                     {"source": "白鷺", "target": "白鹭", "type": "地名"}])
        self.chunk(1, "御堂 静が氷刃を放ち、白鷺が飛ぶ。氷室。\n")
        outs = [g("render", "--state", self.state, "--chunk", "1",
                  "--policy").out for _ in range(3)]
        self.assertEqual(len(set(outs)), 1, "render 三次输出必须逐字节相同")

    def test_render_equals_policy_prompt_plus_hits_md(self) -> None:
        self.init_with_user("B")
        self.chunk(1, "御堂 静と氷室。\n")
        block = g("hits", "--state", self.state, "--chunk", "1",
                  "--format", "md", "--no-event").out.rstrip("\n")
        rendered = g("render", "--state", self.state, "--chunk", "1",
                     "--policy").out
        self.assertIn(block, rendered, "render 必须逐字包含 hits --format md 的块")
        self.assertTrue(rendered.startswith("【术语表策略｜情形 B"))

    def test_render_uses_stored_policy_when_no_value(self) -> None:
        for policy, marker in (("A", "情形 A：用户表锁定 · 禁止新增"),
                               ("B", "情形 B：用户表锁定 + 自动补充"),
                               ("C", "情形 C：全自动术语表"),
                               ("D", "情形 D：不维护术语表")):
            with self.subTest(policy=policy):
                self.setUp()
                if policy in ("A", "B"):
                    self.init_with_user(policy)
                else:
                    g("init", "--state", self.state, "--policy", policy)
                self.chunk(1, "本文。\n")
                r = g("render", "--state", self.state, "--chunk", "1", "--policy")
                self.assertOk(r)
                self.assertIn(marker, r.out)

    def test_render_forced_policy_overrides_store(self) -> None:
        """跨端 diff 验收用：--policy B 应强制输出 B 段，无视库里存的策略。"""
        self.init_policy_c()
        self.chunk(1, "本文。\n")
        r = g("render", "--state", self.state, "--chunk", "1", "--policy", "B")
        self.assertIn("情形 B：用户表锁定 + 自动补充", r.out)

    def test_render_invalid_policy_is_usage_error(self) -> None:
        """--policy 给了非法值时必须报错，不得静默回落到库里的策略。"""
        self.init_policy_c()
        self.chunk(1, "本文。\n")
        r = g("render", "--state", self.state, "--chunk", "1", "--policy", "Z")
        self.assertCode(r, EXIT_USAGE, "非法 --policy 值应退 1 而非静默回落")

    def test_render_without_policy_emits_block_only(self) -> None:
        self.init_policy_c()
        self.chunk(1, "本文。\n")
        r = g("render", "--state", self.state, "--chunk", "1")
        self.assertEqual(r.out.strip(), "【本块命中术语】（暂无）")

    def test_render_without_chunk_degrades_to_full(self) -> None:
        self.init_with_user("B")
        r = g("render", "--state", self.state, "--policy")
        self.assertOk(r)
        self.assertIn("御堂 静", r.out)
        self.assertIn("氷室", r.out)

    def test_render_policy_prompts_mention_hard_timing(self) -> None:
        """需求③：B/C 的策略段必须写明「翻译第 N 块之前先 upsert --phase pre」。"""
        for policy in ("B", "C"):
            with self.subTest(policy=policy):
                self.setUp()
                if policy == "B":
                    self.init_with_user("B")
                else:
                    self.init_policy_c()
                self.chunk(1, "本文。\n")
                out = g("render", "--state", self.state, "--chunk", "1",
                        "--policy").out
                self.assertIn("【硬性时序】", out)
                self.assertIn("--phase pre", out)


# ══════════════════════════════════════════════════════════════════════════
# 6. conflicts / resolve（§4.5 / §4.6）
# ══════════════════════════════════════════════════════════════════════════

class TestConflictsAndResolve(ScriptTestCase):

    def make_conflict(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "白鷺", "target": "白鹭"}])
        self.upsert([{"source": "白鷺", "target": "白鹭鸶"}], "--chunk", "3",
                    "--phase", "post")

    def test_conflicts_json_shape(self) -> None:
        self.make_conflict()
        r = g("conflicts", "--state", self.state)
        self.assertOk(r)
        self.assertEqual(r.get("open"), 1)
        self.assertEqual(r.get("total"), 1)
        item = r.get("items")[0]
        for key in ("id", "source", "existing_target", "proposed_target",
                    "chunk", "phase", "resolved", "resolution", "created_at"):
            self.assertIn(key, item)

    def test_conflicts_md_format(self) -> None:
        self.make_conflict()
        r = g("conflicts", "--state", self.state, "--format", "md")
        self.assertOk(r)
        self.assertIn("【术语冲突】", r.out)
        self.assertIn("白鷺", r.out)

    def test_conflicts_md_empty(self) -> None:
        self.init_policy_c()
        r = g("conflicts", "--state", self.state, "--format", "md")
        self.assertEqual(r.out.strip(), "【术语冲突】（无）")

    def test_fail_if_open_exits_5(self) -> None:
        self.make_conflict()
        r = g("conflicts", "--state", self.state, "--fail-if-open")
        self.assertCode(r, EXIT_CHECK, "存在未决冲突应退 5")

    def test_fail_if_open_passes_after_resolve(self) -> None:
        self.make_conflict()
        g("resolve", "--state", self.state, "--source", "白鷺", "--take", "existing")
        r = g("conflicts", "--state", self.state, "--fail-if-open")
        self.assertOk(r)

    def test_conflicts_filter_by_source(self) -> None:
        self.make_conflict()
        self.upsert([{"source": "氷室", "target": "冰室"}])
        self.upsert([{"source": "氷室", "target": "冰之室"}])
        r = g("conflicts", "--state", self.state, "--source", "氷室")
        self.assertEqual(len(r.get("items")), 1)
        self.assertEqual(r.get("items")[0]["source"], "氷室")

    def test_resolve_take_existing(self) -> None:
        self.make_conflict()
        r = g("resolve", "--state", self.state, "--source", "白鷺",
              "--take", "existing")
        self.assertOk(r)
        self.assertEqual(r.get("target"), "白鹭")
        self.assertEqual(r.get("resolved_conflicts"), 1)
        self.assertEqual(r.get("open_conflicts"), 0)
        term = self.terms_by_source()["白鷺"]
        self.assertEqual(term["target"], "白鹭")
        self.assertEqual(term["status"], "ok", "裁决后 status 必须回到 ok")
        self.assertEqual(self.conflicts()[0]["resolution"], "resolved_by_user")

    def test_resolve_take_proposed(self) -> None:
        self.make_conflict()
        r = g("resolve", "--state", self.state, "--source", "白鷺",
              "--take", "proposed")
        self.assertOk(r)
        self.assertEqual(self.terms_by_source()["白鷺"]["target"], "白鹭鸶")

    def test_resolve_explicit_target_and_lock(self) -> None:
        self.make_conflict()
        r = g("resolve", "--state", self.state, "--source", "白鷺",
              "--target", "白鹭鸟", "--lock", "--by", "agent")
        self.assertOk(r)
        term = self.terms_by_source()["白鷺"]
        self.assertEqual(term["target"], "白鹭鸟")
        self.assertTrue(term["locked"])
        self.assertEqual(self.conflicts()[0]["resolution"], "resolved_by_agent")
        # 锁定后自动流程不得再改
        r2 = self.upsert([{"source": "白鷺", "target": "白鹭鸶"}])
        self.assertEqual(r2.get("summary.rejected_by_lock"), 1)
        self.assertEqual(self.terms_by_source()["白鷺"]["target"], "白鹭鸟")

    def test_resolve_status_flow_ok_conflict_ok(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "白鷺", "target": "白鹭"}])
        self.assertEqual(self.terms_by_source()["白鷺"]["status"], "ok")
        self.upsert([{"source": "白鷺", "target": "白鹭鸶"}])
        self.assertEqual(self.terms_by_source()["白鷺"]["status"], "conflict")
        g("resolve", "--state", self.state, "--source", "白鷺", "--take", "existing")
        self.assertEqual(self.terms_by_source()["白鷺"]["status"], "ok")
        # 再次冲突应能重新置为 conflict
        self.upsert([{"source": "白鷺", "target": "白鹭鸟"}])
        self.assertEqual(self.terms_by_source()["白鷺"]["status"], "conflict")

    def test_resolve_multiple_open_conflicts_at_once(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "白鷺", "target": "白鹭"}])
        self.upsert([{"source": "白鷺", "target": "白鹭鸶"}], "--chunk", "2",
                    "--phase", "pre")
        self.upsert([{"source": "白鷺", "target": "白鹭鸟"}], "--chunk", "5",
                    "--phase", "post")
        r = g("resolve", "--state", self.state, "--source", "白鷺",
              "--target", "白鹭")
        self.assertEqual(r.get("resolved_conflicts"), 2)
        self.assertEqual(r.get("open_conflicts"), 0)

    def test_resolve_take_proposed_picks_latest(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "白鷺", "target": "白鹭"}])
        self.upsert([{"source": "白鷺", "target": "候选甲"}], "--chunk", "2",
                    "--phase", "pre")
        self.upsert([{"source": "白鷺", "target": "候选乙"}], "--chunk", "5",
                    "--phase", "post")
        g("resolve", "--state", self.state, "--source", "白鷺", "--take", "proposed")
        self.assertEqual(self.terms_by_source()["白鷺"]["target"], "候选乙",
                         "缺省应取最新的未决冲突")

    def test_resolve_with_conflict_id(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "白鷺", "target": "白鹭"}])
        self.upsert([{"source": "白鷺", "target": "候选甲"}])
        self.upsert([{"source": "白鷺", "target": "候选乙"}])
        first_id = self.conflicts()[0]["id"]
        g("resolve", "--state", self.state, "--source", "白鷺",
          "--take", "proposed", "--conflict-id", str(first_id))
        self.assertEqual(self.terms_by_source()["白鷺"]["target"], "候选甲")

    def test_resolve_conflict_id_source_mismatch(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "白鷺", "target": "白鹭"},
                     {"source": "氷室", "target": "冰室"}])
        self.upsert([{"source": "白鷺", "target": "候选甲"}])
        cid = self.conflicts()[0]["id"]
        r = g("resolve", "--state", self.state, "--source", "氷室",
              "--take", "proposed", "--conflict-id", str(cid))
        self.assertCode(r, EXIT_USAGE, "冲突 id 与 source 不符应退 1")

    def test_resolve_unknown_source_exits_4(self) -> None:
        self.init_policy_c()
        r = g("resolve", "--state", self.state, "--source", "不存在",
              "--target", "x")
        self.assertCode(r, EXIT_STATE)

    def test_resolve_requires_target_or_take(self) -> None:
        self.make_conflict()
        r = g("resolve", "--state", self.state, "--source", "白鷺")
        self.assertCode(r, EXIT_USAGE)

    def test_resolve_target_and_take_mutually_exclusive(self) -> None:
        self.make_conflict()
        r = g("resolve", "--state", self.state, "--source", "白鷺",
              "--target", "x", "--take", "existing")
        self.assertCode(r, EXIT_USAGE)

    def test_resolve_take_proposed_without_open_conflict_exits_4(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "白鷺", "target": "白鹭"}])
        r = g("resolve", "--state", self.state, "--source", "白鷺",
              "--take", "proposed")
        self.assertCode(r, EXIT_STATE)

    def test_resolve_writes_event(self) -> None:
        self.make_conflict()
        g("resolve", "--state", self.state, "--source", "白鷺", "--take", "existing")
        ev = [e for e in self.events() if e["type"] == "glossary_resolved"]
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]["data"]["source"], "白鷺")
        self.assertEqual(ev[0]["data"]["by"], "user")


# ══════════════════════════════════════════════════════════════════════════
# 7. export / import（§4.7 / §4.8）
# ══════════════════════════════════════════════════════════════════════════

class TestExportImport(ScriptTestCase):

    def seed(self) -> None:
        self.init_with_user("B")
        self.upsert([{"source": "氷刃", "target": "冰刃", "type": "招式",
                      "note": "主角绝技"}])

    def test_export_csv2_header_and_rows(self) -> None:
        self.seed()
        out = os.path.join(self.root, "g2.csv")
        r = g("export", "--state", self.state, "--out", out, "--format", "csv2")
        self.assertOk(r)
        self.assertEqual(r.get("rows"), 3)
        lines = self.read(out).splitlines()
        self.assertEqual(lines[0], "日语,中文")
        self.assertEqual(len(lines), 4)

    def test_export_csv5_header_and_origin_column(self) -> None:
        self.seed()
        out = os.path.join(self.root, "g5.csv")
        g("export", "--state", self.state, "--out", out, "--format", "csv5")
        lines = self.read(out).splitlines()
        self.assertEqual(lines[0], "日语,中文,类型,来源,备注")
        self.assertTrue(any(",用户," in ln for ln in lines[1:]))
        self.assertTrue(any(",自动," in ln for ln in lines[1:]))

    def test_export_origin_filter(self) -> None:
        self.seed()
        out = os.path.join(self.root, "auto.csv")
        r = g("export", "--state", self.state, "--out", out,
              "--format", "csv2", "--origin", "auto")
        self.assertEqual(r.get("rows"), 1, "--origin auto 只导出自动词条")

    def test_export_only_ok_filter(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "白鷺", "target": "白鹭"}])
        self.upsert([{"source": "白鷺", "target": "白鹭鸶"}])   # → status=conflict
        self.upsert([{"source": "氷室", "target": "冰室"}])
        out = os.path.join(self.root, "ok.csv")
        r = g("export", "--state", self.state, "--out", out,
              "--format", "csv2", "--only-ok")
        self.assertEqual(r.get("rows"), 1)

    def test_export_json_roundtrip_schema(self) -> None:
        self.seed()
        out = os.path.join(self.root, "g.json")
        g("export", "--state", self.state, "--out", out, "--format", "json")
        data = json.loads(self.read(out))
        self.assertEqual(data["schema_version"], 1)
        self.assertEqual(data["policy"], "B")
        for term in data["terms"]:
            for key in ("source", "target", "reading", "type", "gender",
                        "aliases", "note", "origin", "locked", "status",
                        "first_chunk", "hits", "created_at", "updated_at"):
                self.assertIn(key, term, f"§3.6 字段 {key} 缺失")

    def test_export_csv_quoting(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "A,B", "target": '说"话"', "note": "含,逗号"}])
        out = os.path.join(self.root, "q.csv")
        g("export", "--state", self.state, "--out", out, "--format", "csv5")
        text = self.read(out)
        self.assertIn('"A,B"', text)
        self.assertIn('""话""', text)

    def test_import_legacy_two_column_csv_becomes_user_locked(self) -> None:
        """v3.2 遗留两栏 CSV 导入后必须是 origin=user, locked=true。"""
        self.init_policy_c()
        path = self.write_root("legacy.csv", "日语,中文\n御堂 静,御堂静\n氷室,冰室\n")
        r = g("import", "--state", self.state, "--file", path, "--origin", "user")
        self.assertOk(r)
        self.assertEqual(r.get("added"), 2)
        for term in self.glossary()["terms"]:
            self.assertEqual(term["origin"], "user")
            self.assertTrue(term["locked"])

    def test_import_headerless_two_column_csv(self) -> None:
        self.init_policy_c()
        path = self.write_root("nohdr.csv", "御堂 静,御堂静\n氷室,冰室\n")
        r = g("import", "--state", self.state, "--file", path)
        self.assertEqual(r.get("added"), 2, "无表头的两栏 CSV 也应全量导入")

    def test_import_respects_upsert_table_without_overwrite(self) -> None:
        self.init_with_user("B")
        path = self.write_root("x.csv", "日语,中文\n御堂 静,米堂静\n")
        r = g("import", "--state", self.state, "--file", path, "--origin", "auto")
        self.assertOk(r)
        self.assertEqual(r.get("skipped"), 1, "不给 --overwrite 时遵循判定表")
        self.assertEqual(self.terms_by_source()["御堂 静"]["target"], "御堂静")

    def test_import_overwrite_forces_target(self) -> None:
        self.init_with_user("B")
        path = self.write_root("x.csv", "日语,中文\n御堂 静,米堂静\n")
        r = g("import", "--state", self.state, "--file", path,
              "--origin", "user", "--overwrite")
        self.assertOk(r)
        self.assertEqual(r.get("updated"), 1)
        self.assertEqual(self.terms_by_source()["御堂 静"]["target"], "米堂静")

    def test_import_overwrite_only_allowed_for_user_origin(self) -> None:
        self.init_with_user("B")
        path = self.write_root("x.csv", "日语,中文\n御堂 静,米堂静\n")
        r = g("import", "--state", self.state, "--file", path,
              "--origin", "auto", "--overwrite")
        self.assertCode(r, EXIT_USAGE, "auto + --overwrite 应退 1")

    def test_import_overwrite_supersedes_open_conflicts(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "白鷺", "target": "白鹭"}])
        self.upsert([{"source": "白鷺", "target": "白鹭鸶"}])
        path = self.write_root("x.csv", "日语,中文\n白鷺,白鹭鸟\n")
        g("import", "--state", self.state, "--file", path,
          "--origin", "user", "--overwrite")
        self.assertTrue(all(c["resolved"] for c in self.conflicts()))
        self.assertEqual(self.conflicts()[0]["resolution"], "superseded")

    def test_import_promotes_auto_to_user_with_lock(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "氷室", "target": "冰室"}])
        path = self.write_root("x.csv", "日语,中文\n氷室,冰室\n")
        g("import", "--state", self.state, "--file", path,
          "--origin", "user", "--lock")
        term = self.terms_by_source()["氷室"]
        self.assertEqual(term["origin"], "user")
        self.assertTrue(term["locked"], "同值导入 + --lock 应把 auto 提升为锁定")

    def test_import_json_file(self) -> None:
        self.init_policy_c()
        path = self.write_root("t.json", json.dumps(
            {"terms": [{"source": "氷室", "target": "冰室", "type": "地名",
                        "aliases": ["ひむろ"]}]}, ensure_ascii=False))
        r = g("import", "--state", self.state, "--file", path)
        self.assertOk(r)
        self.assertEqual(self.terms_by_source()["氷室"]["aliases"], ["ひむろ"])

    def test_import_missing_file_exits_4(self) -> None:
        self.init_policy_c()
        r = g("import", "--state", self.state, "--file",
              os.path.join(self.root, "nope.csv"))
        self.assertCode(r, EXIT_STATE)

    def test_import_skips_incomplete_rows(self) -> None:
        self.init_policy_c()
        path = self.write_root("x.csv", "日语,中文\n氷室,冰室\n只有原文,\n\n,只有译名\n")
        r = g("import", "--state", self.state, "--file", path)
        self.assertOk(r)
        self.assertEqual(r.get("added"), 1)
        self.assertEqual(len(self.glossary()["terms"]), 1)

    def test_export_import_export_is_idempotent(self) -> None:
        """csv5 往返：export → import 到全新 state → export，内容应一致。"""
        self.seed()
        first = os.path.join(self.root, "a.csv")
        g("export", "--state", self.state, "--out", first, "--format", "csv5")

        other = os.path.join(self.root, "state2")
        os.makedirs(other, exist_ok=True)
        g("init", "--state", other, "--policy", "C")
        g("import", "--state", other, "--file", first, "--origin", "user")
        second = os.path.join(self.root, "b.csv")
        g("export", "--state", other, "--out", second, "--format", "csv5")
        third = os.path.join(self.root, "c.csv")
        g("export", "--state", other, "--out", third, "--format", "csv5")
        self.assertEqual(self.read(second), self.read(third),
                         "同一库连续两次 export 必须逐字节相同")
        # 原文 → 译名映射必须完整保留
        def pairs(path: str) -> dict[str, str]:
            rows = [ln.split(",") for ln in self.read(path).splitlines()[1:]]
            return {r[0]: r[1] for r in rows if len(r) >= 2}
        self.assertEqual(pairs(first), pairs(second),
                         "export → import → export 后原文/译名映射不得改变")

    def test_import_writes_event(self) -> None:
        self.init_policy_c()
        path = self.write_root("x.csv", "日语,中文\n氷室,冰室\n")
        g("import", "--state", self.state, "--file", path)
        ev = [e for e in self.events() if e["type"] == "glossary_imported"]
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]["data"]["origin"], "user")


# ══════════════════════════════════════════════════════════════════════════
# 8. stats（§4.9）
# ══════════════════════════════════════════════════════════════════════════

class TestStats(ScriptTestCase):

    def test_stats_fields(self) -> None:
        self.init_with_user("B")
        self.upsert([{"source": "氷刃", "target": "冰刃", "type": "招式"}])
        self.upsert([{"source": "氷刃", "target": "冰之刃"}])       # → conflict
        r = g("stats", "--state", self.state)
        self.assertOk(r)
        self.assertEqual(r.get("terms"), 3)
        self.assertEqual(r.get("locked"), 2)
        self.assertEqual(r.get("auto"), 1)
        self.assertEqual(r.get("open_conflicts"), 1)
        self.assertEqual(r.get("policy"), "B")
        self.assertEqual(r.get("by_status"), {"ok": 2, "conflict": 1})
        self.assertEqual(r.get("by_type").get("招式"), 1)

    def test_stats_md_format(self) -> None:
        self.init_policy_c()
        r = g("stats", "--state", self.state, "--format", "md")
        self.assertOk(r)
        self.assertIn("【术语库统计】", r.out)
        self.assertIn("- 策略：C", r.out)


# ══════════════════════════════════════════════════════════════════════════
# 9. 排序稳定性与落盘格式
# ══════════════════════════════════════════════════════════════════════════

class TestPersistence(ScriptTestCase):

    def test_terms_sorted_by_type_then_source(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "z地", "target": "Z", "type": "地名"},
                     {"source": "a地", "target": "A", "type": "地名"},
                     {"source": "m人", "target": "M", "type": "人物"}])
        keys = [(t["type"], t["source"]) for t in self.glossary()["terms"]]
        self.assertEqual(keys, sorted(keys), "§3.6 要求稳定排序 (type, source)")

    def test_repeated_upsert_produces_stable_file(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "氷室", "target": "冰室"}])
        first = self.read("glossary.json")
        self.upsert([{"source": "氷室", "target": "冰室"}])
        second = self.read("glossary.json")
        # 只有 updated_at 允许变化
        a = json.loads(first)
        b = json.loads(second)
        a.pop("updated_at"), b.pop("updated_at")
        for terms in (a["terms"], b["terms"]):
            for t in terms:
                t.pop("updated_at")
        self.assertEqual(a, b, "同值重复 upsert 不应改变实质内容")

    def test_no_tmp_file_left_behind(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "氷室", "target": "冰室"}])
        leftovers = [n for n in os.listdir(self.state) if n.endswith(".tmp")]
        self.assertEqual(leftovers, [], "正常路径不应残留 .tmp 文件")

    def test_glossary_json_is_utf8_no_bom_lf(self) -> None:
        self.init_policy_c()
        self.upsert([{"source": "氷室", "target": "冰室"}])
        with open(os.path.join(self.state, "glossary.json"), "rb") as fh:
            raw = fh.read()
        self.assertFalse(raw.startswith(b"\xef\xbb\xbf"), "不得写 BOM")
        self.assertNotIn(b"\r\n", raw, "换行必须是 LF")
        self.assertIn("氷室".encode("utf-8"), raw, "必须 ensure_ascii=False")


if __name__ == "__main__":
    unittest.main(verbosity=2)
