#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""qa3_adversarial_test.py — QA-3 最终验收对抗性补测（只读被测源码）

覆盖工程师测试（T02/T06/T09）的盲区：
  1. hits 假阴性：正则元字符术语（C++ / No.1 / （株））、重叠术语、
     日文全角 / 浊音 / 长音符 / 叠字符 / 半角片假名 —— 术语在文中却被漏掉
     = 最坏静默错误，逐条断言"在则必报、不在必不报"。
  2. qa_consistency.py 符合率是否虚高：构造故意违规译文，手算对照
     terminology_rate（expected / violations 口径）。
  3. 并发 append_event：12 进程 × 20 事件 = 240 条，seq 不重不漏且单调。
  4. normalize_punct.py 围栏保护：围栏内 sha256 零改动、围栏外正常规范化。

运行：
  /Users/takimotouki/.workbuddy/binaries/python/versions/3.13.12/bin/python3 \
      -m unittest qa3_adversarial_test -v
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest

from qa_harness import (
    EXIT_OK, PUNCT, PY, QA, STATE, ScriptTestCase, g, run,
)

# ── 1. hits 假阴性 / 假阳性（§4.3 匹配算法盲区）─────────────────────────


class TestHitsAdversarial(ScriptTestCase):

    def seed(self) -> None:
        self.init_policy_c()
        self.upsert([
            {"source": "C++", "target": "C++语言", "type": "其他"},
            {"source": "No.1", "target": "第一", "type": "其他"},
            {"source": "（株）", "target": "股份公司", "type": "组织"},
            {"source": "田中", "target": "田中", "type": "人物"},
            {"source": "田中太郎", "target": "田中太郎", "type": "人物"},
            {"source": "佐々木", "target": "佐佐木", "type": "人物"},
            {"source": "コーヒー", "target": "咖啡", "type": "物品"},
            {"source": "ガンダム", "target": "高达", "type": "其他"},
            {"source": "ヴァンパイア", "target": "吸血鬼", "type": "其他"},
            {"source": "カメラ", "target": "相机", "type": "物品"},
            {"source": "ＡＢＣ社", "target": "ABC公司", "type": "组织"},
            {"source": "関ヶ原", "target": "关原", "type": "地名"},
        ])

    def _hits_sources(self, chunk_no: int) -> list[str]:
        r = g("hits", "--state", self.state, "--chunk", str(chunk_no))
        self.assertOk(r, f"hits chunk {chunk_no} 应退 0")
        return [t["source"] for t in r.get("terms", [])]

    def test_metachar_terms_are_hit(self) -> None:
        """正则元字符术语（+ . 全角括号）不能被误当成正则语法漏掉。"""
        self.seed()
        self.chunk(1, "C++の世界一、No.1を目指す。\n")
        got = self._hits_sources(1)
        self.assertIn("C++", got, "C++ 在文中却被漏掉 = 最坏静默错误")
        self.assertIn("No.1", got, "No.1 在文中却被漏掉")
        self.chunk(2, "（株）テックが新製品を発表。\n")
        got = self._hits_sources(2)
        self.assertIn("（株）", got, "（株）在文中却被漏掉")

    def test_metachar_terms_absent_not_reported(self) -> None:
        """假阳性反向：不存在的术语不得误报。"""
        self.seed()
        self.chunk(1, "C 言語を学ぶ。No 1 位ではない。\n")
        got = self._hits_sources(1)
        self.assertNotIn("C++", got, "C 言語不含 C++，不得误报")
        self.assertNotIn("No.1", got, "No 1 位不含 No.1，不得误报")

    def test_overlap_both_reported(self) -> None:
        """重叠术语（田中 vs 田中太郎）任一键命中即命中，两条都应返回。"""
        self.seed()
        self.chunk(1, "田中太郎が来た。\n")
        got = sorted(self._hits_sources(1))
        self.assertEqual(got, ["田中", "田中太郎"])

    def test_japanese_special_chars(self) -> None:
        """浊音 / 长音符 / 叠字符 / 半角片假名 / 全角字母 / ヶ 全部命中。"""
        self.seed()
        self.chunk(1, "ガンダムとヴァンパイアとコーヒーと佐々木とｶﾒﾗとＡＢＣ社と関ヶ原。\n")
        got = sorted(self._hits_sources(1))
        expect = sorted(["ガンダム", "ヴァンパイア", "コーヒー", "佐々木",
                         "カメラ", "ＡＢＣ社", "関ヶ原"])
        for e in expect:
            self.assertIn(e, got, f"{e} 在文中却被漏掉")
        # 额外：'カメラ'（全角）命中半角输入 ｶﾒﾗ（NFKC 等价）
        self.assertIn("カメラ", got, "半角片假名应经 NFKC 命中カメラ")

    def test_false_positive_control(self) -> None:
        """控制组：完全没有术语的纯日文段落 hits 必须为空。"""
        self.seed()
        self.chunk(1, "空は青く、風は冷たい。\n")
        self.assertEqual(self._hits_sources(1), [])


# ── 2. qa_consistency.py 符合率是否虚高（§3.9 口径手算对照）──────────────


class TestQAConsistencyManual(ScriptTestCase):

    def _run_qa(self) -> dict:
        r = run(QA, "--state", self.state)
        self.assertOk(r, f"qa_consistency 应退 0：{r.err}")
        return r.json

    def _qa_issues_on_disk(self) -> list[dict]:
        data = self.read_json("qa_issues.json")
        return data.get("issues", [])

    def test_rate_manual_computation(self) -> None:
        """手算对照：术语「御堂 静」在源文出现 2 次。
        - 块 1 译文正确用了 target（御堂静）→ 计 expected 1、violations 0
        - 块 2 译文用了别的写法（米堂静）→ 计 expected 1、violations 1
        terminology_rate = 1 - 1/2 = 0.5，且 qa_issues.json 里必须有 terminology 违例。
        """
        self.init_with_user("B")          # 御堂 静 → 御堂静（locked）
        self.chunk(1, "御堂 静が歩く。\n")
        self.chunk(1, "御堂静が歩く。\n", zh=True)
        self.chunk(2, "御堂 静が笑う。\n")
        self.chunk(2, "米堂静が笑う。\n", zh=True)

        data = self._run_qa()
        rate = data.get("terminology_rate")
        self.assertEqual(rate, 0.5, f"手算应为 0.5，实际 {rate}")
        issues = self._qa_issues_on_disk()
        kinds = [i.get("kind") for i in issues]
        self.assertIn("terminology", kinds, "故意违规必须被 terminology 扫描抓到")
        term_issues = [i for i in issues if i.get("kind") == "terminology"]
        self.assertTrue(any(i.get("chunk") == 2 for i in term_issues),
                        "违例必须定位到块 2")

    def test_rate_not_inflated_by_wrong_render(self) -> None:
        """更狠：target 一次都没用对 → 符合率必须为 0，不得虚高。"""
        self.init_with_user("B")
        self.chunk(1, "御堂 静と氷室が現れた。\n")
        self.chunk(1, "米堂静と氷之室が現れた。\n", zh=True)   # 两个全错
        data = self._run_qa()
        self.assertEqual(data.get("terminology_rate"), 0.0,
                         f"全部违例符合率应为 0，实际 {data.get('terminology_rate')}")

    def test_rate_full_compliance(self) -> None:
        """对照组：全部用对 → 符合率 1.0。"""
        self.init_with_user("B")
        self.chunk(1, "御堂 静と氷室が現れた。\n")
        self.chunk(1, "御堂静与冰室出现了。\n", zh=True)
        data = self._run_qa()
        self.assertEqual(data.get("terminology_rate"), 1.0)


# ── 3. 并发 append_event：seq 不重不漏 ───────────────────────────────────


class TestConcurrentAppendEvent(unittest.TestCase):

    def test_12x20_seq_unique_monotonic(self) -> None:
        with tempfile.TemporaryDirectory(prefix="japdf-qa-conc-") as tmp:
            state = os.path.join(tmp, "state")
            os.makedirs(state, exist_ok=True)
            procs = []
            for i in range(12):
                for j in range(20):
                    procs.append(subprocess.Popen(
                        [PY, STATE, "event", "--state", state,
                         "--type", "conc_test", "--kv", f"p={i}", "--kv", f"n={j}"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    ))
            for p in procs:
                self.assertEqual(p.wait(timeout=60), 0, "并发 event 子进程应退 0")

            events_path = os.path.join(state, "events.jsonl")
            with open(events_path, encoding="utf-8") as fh:
                evs = [json.loads(line) for line in fh if line.strip()]
            self.assertEqual(len(evs), 240, f"应恰 240 条事件，实际 {len(evs)}")
            seqs = [e["seq"] for e in evs]
            self.assertEqual(len(seqs), len(set(seqs)), "seq 不得重复")
            self.assertEqual(sorted(seqs), list(range(1, 241)),
                             "seq 必须是 1..240 不重不漏")
            self.assertEqual(seqs, sorted(seqs), "写入顺序应与 seq 一致（锁内单调）")


# ── 4. normalize_punct.py 围栏保护（sha256 零改动）───────────────────────


class TestNormalizePunctFence(unittest.TestCase):

    def _sha256(self, path: str) -> str:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            h.update(fh.read())
        return h.hexdigest()

    def test_fence_lines_untouched_outside_normalized(self) -> None:
        with tempfile.TemporaryDirectory(prefix="japdf-qa-punct-") as tmp:
            src = os.path.join(tmp, "doc.txt")
            fenced_line = "   保留（日本語）の括弧「」と...破折線--ここは変えない。"
            outside_line = "これは「」の括弧と...破折線--変換,対象。"
            content = (
                "序文（導入）\n"
                "```\n" + fenced_line + "\n"
                "~~~\n" + fenced_line + "\n"
                "```\n"
                + outside_line + "\n"
            )
            with open(src, "w", encoding="utf-8") as fh:
                fh.write(content)

            r = run(PUNCT, "--file", src)
            self.assertEqual(r.code, EXIT_OK, f"normalize_punct 应退 0：{r.err}")

            with open(src, encoding="utf-8") as fh:
                text = fh.read()
            lines = text.split("\n")
            # 围栏内两行（分别在 ``` 与 ~~~ 内）必须逐字未变（sha256 级零改动）
            self.assertIn(fenced_line, lines, "围栏内行必须原样保留")
            self.assertEqual(sum(1 for ln in lines if ln == fenced_line), 2,
                             "两个围栏内的行都应零改动")
            # 围栏外行必须已被规范化：日式括号「」→“”，... → ……，-- → ——，半角逗号 → ，
            outside_after = next(ln for ln in lines if ln.startswith("これは"))
            self.assertNotIn("「", outside_after, "围栏外「应被转换为中文引号")
            self.assertNotIn("」", outside_after, "围栏外」应被转换为中文引号")
            self.assertIn("“”", outside_after, "「」应转为中文双引号")
            self.assertIn("……", outside_after, "ASCII ... 应转为省略号")
            self.assertIn("——", outside_after, "ASCII -- 应转为破折号")
            self.assertIn("，", outside_after, "半角逗号应转为全角")
            self.assertNotIn(",対象", outside_after, "半角逗号不得残留")


if __name__ == "__main__":
    unittest.main(verbosity=2)
