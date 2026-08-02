#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ndlocr OCR 驱动 —— 由 Swift 应用通过子进程调用。

直接复用原始 vendored 的 ndlocr-lite 流水线（ocr.process_pdf_documents），
并把分页结果合并为 <out_dir>/ja_combined.txt。

用法：
    python3 ocr_driver.py <ndlocr_dir> <pdf_path> <out_dir> <stem>
"""
import os
import re
import sys
import types


def die(msg, code=1):
    sys.stderr.write("[ERROR] " + msg + "\n")
    sys.exit(code)


def main():
    if len(sys.argv) != 5:
        die("用法: ocr_driver.py <ndlocr_dir> <pdf_path> <out_dir> <stem>", 2)

    ndlocr_dir, pdf_path, out_dir, stem = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

    for p in (ndlocr_dir, pdf_path):
        if not os.path.exists(p):
            die("路径不存在: %s" % p, 2)

    os.makedirs(out_dir, exist_ok=True)

    # 优先解析 vendored ndlocr-lite（与原始 NdlOcrEngine 行为一致：sys.path 前置）
    if ndlocr_dir not in sys.path:
        sys.path.insert(0, ndlocr_dir)

    try:
        import ocr  # 触发 deim/parseq/ndl_parser/reading_order 的扁平兄弟导入
    except ImportError as exc:
        die(
            "无法加载 ndlocr-lite（import ocr 失败）：%s\n"
            "请确认 Python 环境已安装依赖：\n"
            "  onnxruntime, opencv-python, pypdfium2, pypdf, pyyaml, numpy, Pillow, networkx, lxml\n"
            "可运行：pip install onnxruntime opencv-python pypdfium2 pypdf pyyaml numpy Pillow networkx lxml"
            % exc
        )

    model_dir = os.path.join(ndlocr_dir, "model")
    config_dir = os.path.join(ndlocr_dir, "config")

    required_weights = [
        "deim-s-1024x1024.onnx",
        "parseq-ndl-24x256-30-tiny-189epoch-tegaki3-r8data-202604.onnx",
        "parseq-ndl-24x384-50-tiny-300epoch-tegaki3-r8data-202604.onnx",
        "parseq-ndl-24x768-100-tiny-153epoch-tegaki3-r8data-202604.onnx",
    ]
    for w in required_weights:
        wp = os.path.join(model_dir, w)
        if not os.path.isfile(wp):
            die("ndlocr 权重缺失: %s" % wp)

    # 与原始 NdlOcrEngine._build_args 严格一致
    args = types.SimpleNamespace(
        output=out_dir,
        sourcepdf=None,
        sourcedir=None,
        sourceimg=None,
        pdf_output=None,
        pdf_visible_text=False,
        pdf_render_dpi=150.0,
        det_weights=os.path.join(model_dir, "deim-s-1024x1024.onnx"),
        det_classes=os.path.join(config_dir, "ndl.yaml"),
        det_score_threshold=0.2,
        det_conf_threshold=0.25,
        det_iou_threshold=0.2,
        simple_mode=False,
        rec_weights=os.path.join(
            model_dir, "parseq-ndl-24x768-100-tiny-153epoch-tegaki3-r8data-202604.onnx"
        ),
        rec_weights30=os.path.join(
            model_dir, "parseq-ndl-24x256-30-tiny-189epoch-tegaki3-r8data-202604.onnx"
        ),
        rec_weights50=os.path.join(
            model_dir, "parseq-ndl-24x384-50-tiny-300epoch-tegaki3-r8data-202604.onnx"
        ),
        rec_classes=os.path.join(config_dir, "NDLmoji.yaml"),
        device="cpu",
        enable_tcy=False,
        json_only=False,
        viz=False,
    )

    try:
        ocr.process_pdf_documents(args, [pdf_path])
    except Exception as exc:  # noqa: BLE001 - 包装为可感知错误
        die("ndlocr 进程内识别失败：%s" % exc)

    txt_path = os.path.join(out_dir, stem + ".txt")
    if not os.path.isfile(txt_path):
        die("ndlocr 未产出 %s（可能 PDF 无页面或渲染失败）" % txt_path)

    def merge(txt):
        # 折叠 >=2 连续空行为一个段落分隔
        return re.sub(r"\n[ \t]*\n+", "\n\n", txt.strip())

    try:
        with open(txt_path, "r", encoding="utf-8", errors="ignore") as f:
            raw = f.read()
        combined = os.path.join(out_dir, "ja_combined.txt")
        with open(combined, "w", encoding="utf-8") as f:
            f.write(merge(raw))
    except OSError as exc:
        die("合并 ja_combined.txt 失败：%s" % exc)

    # 仅保留 ja_combined.txt，清理 ndlocr 的其它中间产物（与原始 NdlOcrEngine 行为一致）
    for suffix in (".txt", ".xml", ".json", "_text.pdf"):
        try:
            os.remove(os.path.join(out_dir, stem + suffix))
        except OSError:
            pass

    sys.stderr.write("[INFO] DONE -> %s\n" % combined)
    sys.exit(0)


if __name__ == "__main__":
    main()
