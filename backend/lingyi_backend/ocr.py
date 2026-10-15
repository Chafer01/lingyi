"""文字识别（RapidOCR，离线）与公式识别（RapidLaTeXOCR，离线）。

模型在第一次使用时加载，之后常驻内存。
"""
from __future__ import annotations

import io
import re
import threading
from dataclasses import dataclass

import numpy as np
from PIL import Image

_lock = threading.Lock()
_text_engine = None
_formula_engine = None


def _text():
    global _text_engine
    with _lock:
        if _text_engine is None:
            from rapidocr_onnxruntime import RapidOCR
            _text_engine = RapidOCR()
        return _text_engine


def _formula():
    global _formula_engine
    with _lock:
        if _formula_engine is None:
            import rapid_latex_ocr
            # 0.0.9 起类名为 LaTeXOCR，旧版为 LatexOCR
            cls = getattr(rapid_latex_ocr, "LaTeXOCR", None) or getattr(rapid_latex_ocr, "LatexOCR")
            _formula_engine = cls()
        return _formula_engine


def load_image(data: bytes) -> Image.Image:
    img = Image.open(io.BytesIO(data))
    if img.mode in ("RGBA", "LA", "P"):
        # 透明背景（截图工具常见）铺白底，否则识别成黑底
        img = img.convert("RGBA")
        bg = Image.new("RGB", img.size, "white")
        bg.paste(img, mask=img.split()[-1])
        return bg
    return img.convert("RGB")


# ---------------------------------------------------------------- 文字
@dataclass
class Line:
    text: str
    x0: float
    y0: float
    x1: float
    y1: float
    score: float

    @property
    def h(self):
        return self.y1 - self.y0

    @property
    def cy(self):
        return (self.y0 + self.y1) / 2


_CJK = re.compile(r"[　-〿㐀-鿿＀-￯]")


def _is_cjk(ch: str) -> bool:
    return bool(_CJK.match(ch))


def _join(a: str, b: str) -> str:
    """把两行拼成一段：英文加空格并处理连字符断词，中文直接相连。"""
    if not a:
        return b
    if not b:
        return a
    if a.endswith("-") and len(a) > 1 and a[-2].isalpha() and b[:1].islower():
        return a[:-1] + b                       # trans- mission → transmission
    if _is_cjk(a[-1]) or _is_cjk(b[0]):
        return a + b
    return a + " " + b


# 识别模型偶尔会吞掉英文单词间的空格（“Isolationbetweenports…”）。
# 只在整行明显缺少空格时，用词频切分长字母串；切开后若能拼回专业词则保持原样。
_KEEP = {
    "metasurface", "metasurfaces", "beamwidth", "beamwidths", "beamforming", "downtilt", "uptilt",
    "waveguide", "waveguides", "microstrip", "stripline", "bandwidth", "bandwidths", "wideband",
    "broadband", "multiband", "dualband", "narrowband", "passband", "stopband", "baseband",
    "sidelobe", "sidelobes", "feedline", "groundplane", "crosstalk", "datasheet", "radiofrequency",
    "throughput", "submatrix", "eigenmode", "eigenmodes", "metamaterial", "metamaterials",
}
_LONG_RUN = re.compile(r"[A-Za-z]{8,}")


def _split_run(run: str) -> str:
    try:
        import wordninja
        parts = wordninja.split(run)
    except Exception:  # noqa: BLE001  词频表缺失等情况下保持原样
        return run
    if run.lower() in _KEEP:
        return run
    if len(parts) < 2 or "".join(parts) != run:
        return run
    merged: list[str] = []
    i = 0
    while i < len(parts):
        # 尽量把相邻的片段拼回保护词，例如 meta + surface
        for j in range(len(parts), i + 1, -1):
            if "".join(parts[i:j]).lower() in _KEEP:
                merged.append("".join(parts[i:j]))
                i = j
                break
        else:
            merged.append(parts[i])
            i += 1
    return " ".join(merged)


def fix_spaces(line: str) -> str:
    letters = sum(c.isascii() and c.isalpha() for c in line)
    if letters < 16 or line.count(" ") > letters / 14:
        return line
    out = _LONG_RUN.sub(lambda m: _split_run(m.group(0)), line)
    return re.sub(r"(?<=[a-z]{2})(?=\d)", " ", out)       # than28dB → than 28dB


def _rows(lines: list[Line]) -> list[list[Line]]:
    """把文本框按行归组（同一行可能被识别成多个框，例如表格或分栏）。"""
    rows: list[list[Line]] = []
    for ln in sorted(lines, key=lambda l: l.cy):
        if rows:
            last = rows[-1]
            ref_h = np.median([l.h for l in last])
            ref_cy = np.mean([l.cy for l in last])
            if abs(ln.cy - ref_cy) < 0.5 * min(ref_h, ln.h):
                last.append(ln)
                continue
        rows.append([ln])
    return [sorted(r, key=lambda l: l.x0) for r in rows]


def paragraphs(lines: list[Line]) -> str:
    """把识别出的行合并成段落：行距明显变大、缩进或上一行很短时另起一段。"""
    if not lines:
        return ""
    rows = _rows(lines)
    merged = []
    for r in rows:
        text = r[0].text
        for nxt in r[1:]:
            gap = nxt.x0 - r[0].x1
            text = text + ("\t" if gap > 2 * r[0].h else " ") + nxt.text
        merged.append(Line(text, min(l.x0 for l in r), min(l.y0 for l in r),
                           max(l.x1 for l in r), max(l.y1 for l in r),
                           float(np.mean([l.score for l in r]))))
    width = max(l.x1 for l in merged) - min(l.x0 for l in merged)
    left = np.median([l.x0 for l in merged])
    paras = [merged[0].text]
    for prev, cur in zip(merged, merged[1:]):
        gap = cur.y0 - prev.y1
        h = (prev.h + cur.h) / 2
        short_prev = (prev.x1 - prev.x0) < 0.6 * width and not prev.text.endswith("-")
        indent = cur.x0 - left > 1.2 * h
        ends_sentence = prev.text[-1:] in "。！？.!?:：;；"
        new_para = gap > 0.9 * h or indent or (short_prev and ends_sentence) or "\t" in cur.text
        if new_para:
            paras.append(cur.text)
        else:
            paras[-1] = _join(paras[-1], cur.text)
    return "\n".join(paras)


def recognize_text(img: Image.Image) -> dict:
    arr = np.asarray(img)[:, :, ::-1]          # RapidOCR 用 BGR
    result, _ = _text()(arr)
    lines = []
    for box, text, score in result or []:
        xs = [p[0] for p in box]
        ys = [p[1] for p in box]
        lines.append(Line(fix_spaces(text.strip()), min(xs), min(ys), max(xs), max(ys), float(score)))
    lines = [l for l in lines if l.text]
    return {
        "text": paragraphs(lines),
        "lines": [{"text": l.text, "box": [l.x0, l.y0, l.x1, l.y1], "score": round(l.score, 4)}
                  for l in lines],
    }


# ---------------------------------------------------------------- 公式
def _pad(img: Image.Image, margin: int = 12) -> Image.Image:
    """截图常常紧贴公式边缘，补一圈白边识别更稳。"""
    w, h = img.size
    out = Image.new("RGB", (w + 2 * margin, h + 2 * margin), "white")
    out.paste(img, (margin, margin))
    return out


def tidy_latex(s: str) -> str:
    s = s.strip()
    s = re.sub(r"\\\s+(?=[=+\-])", "", s)       # 模型常输出 "\ =" 这样的多余空格
    s = re.sub(r"\s{2,}", " ", s)
    return s


def to_mathml(latex: str) -> str | None:
    try:
        import latex2mathml.converter as conv
        return conv.convert(latex)
    except Exception:  # noqa: BLE001
        return None


def recognize_formula(img: Image.Image) -> dict:
    buf = io.BytesIO()
    _pad(img).save(buf, format="PNG")
    latex, _elapse = _formula()(buf.getvalue())
    latex = tidy_latex(latex)
    return {"latex": latex, "mathml": to_mathml(latex), "text": latex}
