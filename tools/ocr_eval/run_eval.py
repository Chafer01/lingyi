"""截图识别（文字 + 公式）实测：本地 OCR 与各视觉大模型对比。

    python tools/ocr_eval/run_eval.py [--local] [--only 智谱,魔搭] [--out eval/ocr]

测试图由 make_fixtures.py 生成（模仿论文排版），标准答案在 fixtures/truth.json。
评分：
  公式相似度  独立公式的 LaTeX 归一化后（ε 写法、\\left/\\right、空格、\\dfrac 等等价差异）与标准答案的编辑距离相似度；
              1.00 表示完全一致。
  公式全对    归一化后与标准答案完全相同的独立公式数。
  行内符号    正文中的行内公式（如 ε_h）被正确识别为公式的比例。
  文字错字率  去掉所有公式后，正文文字的字符错误率（CER）。
  编号        公式编号（如 2-32）是否保留。
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIX = HERE / "fixtures"

PROMPT = (
    "请识别图片中的全部文字和数学公式，按原文顺序输出。要求：\n"
    "1. 普通文字原样输出，不要翻译、改写或总结；\n"
    "2. 行内公式和符号用 $...$ 包裹，独立成行的公式用 $$...$$ 包裹，公式内容使用标准 LaTeX；\n"
    "3. 公式编号（如 (2-32)）写在对应公式里，用 \\tag{2-32} 表示；\n"
    "4. 段落之间空一行；不要输出任何解释或额外内容。"
)

MS = "https://api-inference.modelscope.cn/v1"
ZP = "https://open.bigmodel.cn/api/paas/v4"

# (名称, base_url, 密钥环境变量, 模型, 附加参数)
VLMS = [
    ("智谱 GLM-4.6V-Flash", ZP, "ZHIPU_API_KEY", "glm-4.6v-flash", {"thinking": {"type": "disabled"}}),
    ("智谱 GLM-4.1V-Thinking-Flash", ZP, "ZHIPU_API_KEY", "glm-4.1v-thinking-flash", {}),
    ("智谱 GLM-4V-Flash", ZP, "ZHIPU_API_KEY", "glm-4v-flash", {}),
    ("魔搭 Qwen3.5-397B", MS, "MODELSCOPE_API_KEY", "Qwen/Qwen3.5-397B-A17B", {"enable_thinking": False}),
    ("魔搭 Qwen3.5-122B", MS, "MODELSCOPE_API_KEY", "Qwen/Qwen3.5-122B-A10B", {"enable_thinking": False}),
    ("魔搭 Qwen3.5-27B", MS, "MODELSCOPE_API_KEY", "Qwen/Qwen3.5-27B", {"enable_thinking": False}),
    ("魔搭 InternVL3.5-241B", MS, "MODELSCOPE_API_KEY", "OpenGVLab/InternVL3_5-241B-A28B", {}),
    ("魔搭 ERNIE-4.5-VL-28B", MS, "MODELSCOPE_API_KEY", "PaddlePaddle/ERNIE-4.5-VL-28B-A3B-PT", {}),
]


# ---------------------------------------------------------------- 调用
def http_json(url, key, body, timeout=150):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST", headers={
        "Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace"), time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), time.time() - t0
    except Exception as e:  # noqa: BLE001
        return 0, f"{type(e).__name__}: {e}", time.time() - t0


def clean_reply(s: str) -> str:
    s = re.sub(r"<think>[\s\S]*?</think>", "", s)
    s = s.replace("<|begin_of_box|>", "").replace("<|end_of_box|>", "")
    s = re.sub(r"^```(?:markdown|latex|md)?\s*\n?|\n?```\s*$", "", s.strip())
    return s.strip()


def vlm(base, key, model, extra, png: bytes):
    b64 = base64.b64encode(png).decode()
    total = 0.0
    for url_form in (f"data:image/png;base64,{b64}", b64):
        body = {
            "model": model, "temperature": 0.1, "max_tokens": 1024 if model == "glm-4v-flash" else 4096, "stream": False,  # 与 App 一致；glm-4v-flash 上限 1024
            "messages": [{"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": url_form}},
                {"type": "text", "text": PROMPT},
            ]}],
            **extra,
        }
        for attempt in range(4):
            code, resp, dt = http_json(f"{base}/chat/completions", key, body)
            total += dt
            if code == 429 and attempt < 3:
                time.sleep(4 * (attempt + 1))
                continue
            break
        if code == 200:
            try:
                j = json.loads(resp)
                return clean_reply(j["choices"][0]["message"]["content"] or ""), None, total
            except Exception as e:  # noqa: BLE001
                return None, f"解析失败：{e}：{resp[:300]}", total
        # data URL 不被接受时，换成纯 base64 再试一次（智谱文档示例是纯 base64）
        if code == 400 and url_form.startswith("data:"):
            continue
        return None, f"HTTP {code}：{resp[:400]}", total
    return None, f"HTTP {code}：{resp[:400]}", total


# ---------------------------------------------------------------- 评分
def norm_latex(s: str) -> str:
    s = re.sub(r"\\tag\*?\{[^}]*\}", "", s)
    s = s.replace("\\displaystyle", "").replace("\\dfrac", "\\frac").replace("\\tfrac", "\\frac")
    s = s.replace("\\varepsilon", "\\epsilon").replace("\\left", "").replace("\\right", "")
    s = s.replace("\\bigl", "").replace("\\bigr", "").replace("\\Bigl", "").replace("\\Bigr", "")
    s = re.sub(r"\\(?:mathrm|mathit|text|textrm|operatorname|mathbf|rm|it)\s*\{([^{}]*)\}", r"\1", s)
    s = re.sub(r"\\(?:,|;|:|!|quad|qquad)", "", s)
    s = s.replace("\\lvert", "|").replace("\\rvert", "|").replace("\\vert", "|").replace("\\mid", "|")
    s = s.replace("\\left|", "|").replace("\\right|", "|")
    s = re.sub(r"\s+", "", s)
    # _{i} → _i，^{2} → ^2（单个字符时）
    s = re.sub(r"([_^])\{(\\?[A-Za-z0-9])\}", r"\1\2", s)
    s = re.sub(r"[.,;。，]+$", "", s)
    return s


def lev(a: str, b: str) -> int:
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def sim(a: str, b: str) -> float:
    if not a and not b:
        return 1.0
    return 1 - lev(a, b) / max(len(a), len(b))


DISPLAY = re.compile(r"\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\begin\{(?:equation|align)\*?\}([\s\S]+?)\\end\{(?:equation|align)\*?\}")
INLINE = re.compile(r"(?<!\$)\$([^$\n]+?)\$(?!\$)|\\\(([\s\S]+?)\\\)")


def split_math(out: str):
    display = [next(g for g in m.groups() if g) for m in DISPLAY.finditer(out)]
    rest = DISPLAY.sub(" ", out)
    inline = [next(g for g in m.groups() if g) for m in INLINE.finditer(rest)]
    plain = INLINE.sub("", rest)
    return display, inline, plain


def plain_norm(s: str) -> str:
    s = re.sub(r"[#*>`_]|\\tag\{[^}]*\}", "", s)
    s = re.sub(r"\(\s*\d+(?:-\d+)?\s*\)", "", s)            # 公式编号
    s = s.replace(",", "，").replace(":", "：")
    return re.sub(r"\s+", "", s)


def score(truth: dict, out: str | None) -> dict:
    if not out:
        return {"formula_sim": 0.0, "formula_exact": 0, "inline": 0.0, "cer": 1.0, "number": False}
    display, inline, plain = split_math(out)
    # 只有一个独立公式、却被写成行内公式的情况，也纳入比较
    cands = display or inline
    fsims, exact = [], 0
    for t in truth["formulas"]:
        nt = norm_latex(t)
        best = max((sim(norm_latex(c), nt) for c in cands), default=0.0)
        fsims.append(best)
        exact += any(norm_latex(c) == nt for c in cands)
    inl_norm = {norm_latex(c) for c in inline + display}
    inl_hit = sum(norm_latex(t) in inl_norm for t in truth["inline"])
    inl = inl_hit / len(truth["inline"]) if truth["inline"] else 1.0
    t_plain = plain_norm(truth["text"])
    o_plain = plain_norm(plain)
    cer = (lev(o_plain, t_plain) / len(t_plain)) if t_plain else 0.0
    num = truth["number"] is None or truth["number"] in out
    return {"formula_sim": round(sum(fsims) / len(fsims), 3), "formula_exact": exact, "inline": round(inl, 2),
            "cer": round(min(cer, 1.0), 3), "number": num}


# ---------------------------------------------------------------- 本地对照
def local_runner():
    sys.path.insert(0, str(HERE.parents[1] / "backend"))
    from lingyi_backend import ocr  # noqa: E402

    def run(png: bytes):
        img = ocr.load_image(png)
        t0 = time.time()
        text = ocr.recognize_text(img)["text"]
        return text, None, time.time() - t0
    return run


# ---------------------------------------------------------------- 主程序
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--local", action="store_true", help="同时测本地 RapidOCR（现有“文字”模式）")
    ap.add_argument("--only", default="", help="只测名称包含这些关键字的模型（逗号分隔）")
    ap.add_argument("--out", default="eval/ocr")
    args = ap.parse_args()

    truth = json.loads((FIX / "truth.json").read_text(encoding="utf-8"))
    images = {name: (FIX / f"{name}.png").read_bytes() for name in truth}
    runners = []
    if args.local:
        runners.append(("本地 RapidOCR（现“文字”模式）", local_runner()))
    only = [x for x in args.only.split(",") if x.strip()]
    for name, base, env, model, extra in VLMS:
        if only and not any(o in name for o in only):
            continue
        key = os.environ.get(env, "").strip()
        if not key:
            print(f"跳过 {name}：没有 {env}")
            continue
        runners.append((name, lambda png, b=base, k=key, m=model, x=extra: vlm(b, k, m, x, png)))

    results = []
    for name, run in runners:
        print(f"== {name}", flush=True)
        rows = []
        for img_name, png in images.items():
            out, err, dt = run(png)
            sc = score(truth[img_name], out)
            rows.append({"image": img_name, "out": out, "err": err, "latency": round(dt, 1), **sc})
            print(f"  {img_name}: {'❌ ' + err[:120] if err else ''} 公式 {sc['formula_sim']}  "
                  f"错字率 {sc['cer']}  {dt:.1f}s", flush=True)
            time.sleep(1.5)
        ok = [r for r in rows if not r["err"]]
        n = len(rows)
        results.append({
            "name": name, "rows": rows, "errors": n - len(ok),
            "formula_sim": round(sum(r["formula_sim"] for r in rows) / n, 3),
            "formula_exact": sum(r["formula_exact"] for r in rows),
            "formula_total": sum(len(truth[r["image"]]["formulas"]) for r in rows),
            "inline": round(sum(r["inline"] for r in rows) / n, 2),
            "cer": round(sum(r["cer"] for r in rows) / n, 3),
            "number": sum(bool(r["number"]) for r in rows),
            "latency": round(sum(r["latency"] for r in ok) / max(1, len(ok)), 1),
        })

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")
    md = ["# 截图识别实测（文字 + 公式）", "",
          "| 模型 | 失败 | 公式相似度 | 公式全对 | 行内符号 | 文字错字率 | 编号保留 | 平均耗时 |",
          "|---|---|---|---|---|---|---|---|"]
    for r in sorted(results, key=lambda r: (-r["formula_sim"], r["cer"])):
        md.append(f"| {r['name']} | {r['errors']}/{len(r['rows'])} | {r['formula_sim']:.3f} | "
                  f"{r['formula_exact']}/{r['formula_total']} | {r['inline']:.2f} | {r['cer']:.3f} | "
                  f"{r['number']}/{len(r['rows'])} | {r['latency']}s |")
    for r in results:
        md += ["", f"## {r['name']}"]
        for row in r["rows"]:
            md += ["", f"### {row['image']}（公式 {row['formula_sim']}，错字率 {row['cer']}，{row['latency']}s）", ""]
            md.append("```")
            md.append(row["out"] if row["out"] else f"错误：{row['err']}")
            md.append("```")
    (out_dir / "results.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\n".join(md[:4 + len(results)]))


if __name__ == "__main__":
    main()
