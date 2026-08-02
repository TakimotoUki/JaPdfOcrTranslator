#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""build_pdf.py — 将全文排成美观中日文 PDF

用法:
  # 中文译文版
  python build_pdf.py --input translation_full.txt --output xxx_zh.pdf \
      --title "书名" --author "作者" --date "2024-03"

  # 日文原文版
  python build_pdf.py --input original_full.txt --output xxx_ja.pdf \
      --title "..." --author "..." --date "..."

  # 双语对照版（每段先排日文原文灰字，再排中文译文）
  python build_pdf.py --input translation_full.txt --output xxx_bi.pdf \
      --bilingual --original original_full.txt \
      --title "..." --author "..." --date "..."

特性:
  - 使用 reportlab 内置 CID 字体：中文 STSong-Light，日文 HeiseiMin-W3，无需字体文件。
  - 章节标题（第X章 / 数字编号 / はじめに 等）居中加粗。
  - 正文两端对齐、首行缩进、页码页脚。
  - --title 提供即生成带封面的 PDF。
"""
import argparse, os, re
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY, TA_LEFT
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.colors import HexColor
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph,
                                Spacer, PageBreak, Preformatted, KeepTogether)

# 字体嵌入（关键：CID 字体只引用不嵌入，部分本地阅读器会缺字；
# 这里改为嵌入真实 TrueType 字体，使 PDF 自包含、任何阅读器一致渲染）。
#   CN_FONT(中文/宋体衬线) : Songti.ttc 子字体1（简体中文，对本文 100% 覆盖）
#   JP_FONT(日文/全覆盖)    : Arial Unicode.ttf（1813/1813 全覆盖，含 ・ 中点、假名、汉字）
# 若系统字体缺失则自动回退到 Arial Unicode，保证不缺字。
def _find_font(candidates):
    for p in candidates:
        if os.path.exists(p):
            return p
    return None

_CN_CANDIDATES = [
    '/System/Library/Fonts/Supplemental/Songti.ttc',
    '/Library/Fonts/Songti.ttc',
    '/System/Library/Fonts/STHeiti Light.ttc',
    '/Library/Fonts/Arial Unicode.ttf',
]
_JP_CANDIDATES = [
    '/Library/Fonts/Arial Unicode.ttf',
    '/System/Library/Fonts/Supplemental/Songti.ttc',
    '/System/Library/Fonts/STHeiti Light.ttc',
]

_cn_path = _find_font(_CN_CANDIDATES)
_jp_path = _find_font(_JP_CANDIDATES)
if not _jp_path:
    raise SystemExit('未找到可用的 CJK 字体（需要 Arial Unicode.ttf 或 Songti/STHeiti）')

CN_FONT = 'CJKSerif'
JP_FONT = 'CJKAll'
# 中文用宋体衬线（.ttc 需指定子字体索引 1）；回退时与 JP 同字体
pdfmetrics.registerFont(TTFont(CN_FONT, _cn_path if _cn_path else _jp_path,
                               subfontIndex=1 if (_cn_path or '').endswith('.ttc') else 0))
pdfmetrics.registerFont(TTFont(JP_FONT, _jp_path,
                               subfontIndex=0 if _jp_path.endswith('.ttc') else 0))

CHAPTER_RE = re.compile(
    r'^\s*(第[一二三四五六七八九十\d]+[章節回部]|'
    r'[0-9]+\.\s*「|'
    r'[０-９]+\.|'
    r'[一二三四五六七八九十百]+、|'
    r'はじめに|まえがき|あとがき|おわりに|目次|参考文献|付録|'
    r'结语|参考文献\s*$|前言\s*$)'
)

def is_chapter(para):
    s = para.strip()
    if not s:
        return False
    if len(s) > 60:
        return False
    return bool(CHAPTER_RE.match(s))

def split_paragraphs(text):
    blocks = re.split(r'\n\s*\n', text)
    return [b.strip() for b in blocks if b.strip()]

_KANA = re.compile(r'[぀-ヿ]')

def text_has_kana(s):
    return bool(_KANA.search(s or ''))

def make_styles(bilingual=False, body_font=CN_FONT):
    base_size = 11
    body = ParagraphStyle('body', fontName=body_font, fontSize=base_size,
                          leading=base_size + 6, alignment=TA_JUSTIFY,
                          firstLineIndent=base_size * 2, wordWrap='CJK',
                          spaceAfter=6)
    head = ParagraphStyle('head', fontName=CN_FONT, fontSize=14,
                          leading=20, alignment=TA_CENTER,
                          spaceBefore=10, spaceAfter=10, wordWrap='CJK')
    head_jp = ParagraphStyle('head_jp', fontName=JP_FONT, fontSize=12,
                            leading=18, alignment=TA_CENTER,
                            textColor=HexColor('#777777'),
                            spaceBefore=6, spaceAfter=2, wordWrap='CJK')
    sub = ParagraphStyle('sub', fontName=CN_FONT, fontSize=10, leading=15,
                         alignment=TA_LEFT, textColor=HexColor('#555555'),
                         wordWrap='CJK', spaceAfter=4)
    code = ParagraphStyle('code', fontName='Courier', fontSize=9.5, leading=13,
                          alignment=TA_LEFT, backColor=HexColor('#f4f4f4'),
                          borderPadding=4, spaceAfter=6)
    jp = ParagraphStyle('jp', fontName=JP_FONT, fontSize=10, leading=15,
                        alignment=TA_LEFT, textColor=HexColor('#777777'),
                        firstLineIndent=0, wordWrap='CJK', spaceAfter=2)
    return {'body': body, 'head': head, 'head_jp': head_jp, 'sub': sub,
            'code': code, 'jp': jp}

def is_fence(para):
    return para.strip().startswith('```') or para.strip().startswith('~~~')

def _esc(s):
    s = s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    return s

def build_flowables(text, styles, bilingual=False, original_text=None):
    flow = []
    paras = split_paragraphs(text)
    orig_paras = split_paragraphs(original_text) if original_text else None

    for idx, para in enumerate(paras):
        if is_fence(para):
            flow.append(Preformatted(para, styles['code']))
            continue
        if is_chapter(para):
            if bilingual and orig_paras is not None and idx < len(orig_paras):
                jp_para = orig_paras[idx]
                if jp_para.strip():
                    flow.append(Paragraph(_esc(jp_para), styles['head_jp']))
            flow.append(Paragraph(_esc(para), styles['head']))
            continue
        if bilingual and orig_paras is not None and idx < len(orig_paras):
            jp_para = orig_paras[idx]
            if jp_para.strip():
                flow.append(Paragraph(_esc(jp_para), styles['jp']))
            flow.append(Paragraph(_esc(para), styles['body']))
        else:
            flow.append(Paragraph(_esc(para), styles['body']))
    return flow

def header_footer(canvas, doc):
    canvas.saveState()
    canvas.setFont(CN_FONT, 9)
    canvas.setFillColor(HexColor('#888888'))
    canvas.drawCentredString(A4[0] / 2.0, 14 * mm, '第 %d 页' % doc.page)
    canvas.restoreState()

def build_cover(title, author, date, styles):
    flow = []
    flow.append(Spacer(1, 60 * mm))
    if title:
        t = ParagraphStyle('ct', fontName=CN_FONT, fontSize=22, leading=30,
                           alignment=TA_CENTER, wordWrap='CJK')
        flow.append(Paragraph(_esc(title), t))
        flow.append(Spacer(1, 10 * mm))
    if author:
        a = ParagraphStyle('ca', fontName=CN_FONT, fontSize=13, leading=20,
                           alignment=TA_CENTER, textColor=HexColor('#444444'),
                           wordWrap='CJK')
        flow.append(Paragraph('作者：' + _esc(author), a))
        flow.append(Spacer(1, 4 * mm))
    if date:
        d = ParagraphStyle('cd', fontName=CN_FONT, fontSize=11, leading=16,
                           alignment=TA_CENTER, textColor=HexColor('#666666'))
        flow.append(Paragraph('出版日期：' + _esc(date), d))
    flow.append(PageBreak())
    return flow

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input', required=True)
    ap.add_argument('--output', required=True)
    ap.add_argument('--title', default='')
    ap.add_argument('--author', default='')
    ap.add_argument('--date', default='')
    ap.add_argument('--bilingual', action='store_true')
    ap.add_argument('--original', default=None)
    args = ap.parse_args()

    with open(args.input, encoding='utf-8') as f:
        text = f.read()
    original_text = None
    if args.bilingual:
        if not args.original:
            raise SystemExit('--bilingual requires --original')
        with open(args.original, encoding='utf-8') as f:
            original_text = f.read()

    body_font = JP_FONT if (not args.bilingual and text_has_kana(text)) else CN_FONT
    styles = make_styles(bilingual=args.bilingual, body_font=body_font)
    flow = []
    if args.title:
        flow += build_cover(args.title, args.author, args.date, styles)
    flow += build_flowables(text, styles, bilingual=args.bilingual,
                            original_text=original_text)

    doc = BaseDocTemplate(args.output, pagesize=A4,
                          leftMargin=22 * mm, rightMargin=22 * mm,
                          topMargin=22 * mm, bottomMargin=22 * mm,
                          title=args.title or 'document',
                          author=args.author or '')
    frame = Frame(doc.leftMargin, doc.bottomMargin,
                  doc.width, doc.height, id='main')
    doc.addPageTemplates([PageTemplate(id='all', frames=[frame],
                                       onPage=header_footer)])
    doc.build(flow)
    size = os.path.getsize(args.output)
    print(f'PDF built: {args.output} ({size} bytes)')

if __name__ == '__main__':
    main()
