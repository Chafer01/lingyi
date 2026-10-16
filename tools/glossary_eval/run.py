"""术语表扩充前后对比：同一批句子，分别带旧表（27 条）和新表命中的术语去翻译，统计译文里的标准术语命中数。

匹配规则与灵译 glossaryHits 一致：英文不区分大小写、整词、空格/连字符可互换、允许复数；被更长命中包含的不单独提示。
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]

TESTS = [
    ("The embedded element pattern was computed with all other ports terminated in matched loads.", ["嵌入单元方向图"]),
    ("A defected ground structure beneath the feed line suppresses the second harmonic.", ["缺陷地结构", "馈线", "谐波"]),
    ("The reflectarray uses a phase gradient to produce anomalous reflection toward 30°.", ["反射阵", "相位梯度", "异常反射"]),
    ("Scan blindness occurs near 52° due to a surface wave supported by the substrate.", ["扫描盲点", "表面波", "基板"]),
    ("Both the sector power ratio and the front-to-back ratio total power were improved.", ["扇区功率比", "总功率前后比"]),
    ("An artificial magnetic conductor allows the dipoles to be placed close to the reflector plate.", ["人工磁导体", "偶极子", "反射板"]),
    ("The circulator and isolator ensure that the power amplifier sees a matched load.", ["环行器", "隔离器", "功率放大器"]),
    ("The axial ratio bandwidth is narrower than the impedance bandwidth.", ["轴比带宽", "阻抗带宽"]),
    ("Each subarray is driven through a Butler matrix to form multiple beams.", ["子阵", "巴特勒矩阵"]),
    ("The cross-polarization discrimination at boresight exceeds 20 dB for both slant polarizations.", ["交叉极化鉴别度", "视轴", "斜极化"]),
    ("A perfectly matched layer truncates the computational domain in the finite element method.", ["完全匹配层", "有限元法"]),
    ("Measurements were performed in an anechoic chamber using a compact antenna test range.", ["微波暗室", "紧缩场"]),
    ("The aperture-coupled stacked patch achieves a fractional bandwidth of 25%.", ["口径耦合", "层叠贴片", "相对带宽"]),
    ("Passive intermodulation must remain below -153 dBc at the jumper cable connectors.", ["无源互调", "跳线"]),
    ("A Luneburg lens fed by multiple feed horns produces independent beams with low beam squint.", ["龙伯透镜", "馈源喇叭", "波束偏斜"]),
]

SYSTEM = ("你是专业的科技翻译，熟悉射频、天线、电磁仿真和通信工程。\n"
          "把用户给出的文本翻译成简体中文。要求：准确、通顺、符合技术文档习惯；\n"
          "保留公式、变量名、单位、代码和专有名词的原样；不要解释，不要加括号注释，不要加引号，只输出译文。\n")

MODELS = [
    ("Qwen3.5-397B（魔搭）", "https://api-inference.modelscope.cn/v1", "MODELSCOPE_API_KEY", "Qwen/Qwen3.5-397B-A17B",
     {"enable_thinking": False}),
    ("MiMo-V2.6-Flash（AMD）", "https://developer.amd.com.cn/radeon/api/v1", "AMD_API_KEY", "MiMo-V2.6-Flash", {}),
    ("GLM-4-Flash（智谱）", "https://open.bigmodel.cn/api/paas/v4", "ZHIPU_API_KEY", "glm-4-flash-250414", {}),
]


def parse(text):
    out = {}
    for raw in text.split("\n"):
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("const ") or line.startswith("///") or line == "''';":
            continue
        parts = re.split(r"\s*(?:=|→|\t)\s*", line)
        if len(parts) >= 2 and parts[0] and parts[1]:
            out[parts[0]] = parts[1]
    return out


def new_glossary():
    src = (ROOT / "lib/services/glossary_default.dart").read_text(encoding="utf-8")
    body = src.split("const defaultGlossary = '''", 1)[1].split("''';", 1)[0]
    return parse(body)


def hits(text, g):
    lower = text.lower()
    found = []
    for s, d in g.items():
        body = r"[\s\-]*".join(re.escape(t) for t in re.split(r"[\s\-]+", s.lower()))
        if re.search(r"(^|[^a-z])" + body + r"(?:s|es)?($|[^a-z])", lower):
            found.append((s, d))
    norm = lambda x: re.sub(r"[\s\-]+", "", x.lower())  # noqa: E731
    keys = [norm(s) for s, _ in found]
    return {s: d for (s, d), k in zip(found, keys) if not any(len(o) > len(k) and k in o for o in keys)}


def call(base, key, model, extra, system, text):
    body = {"model": model, "temperature": 0.2, "stream": False,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": text}], **extra}
    for attempt in range(5):
        req = urllib.request.Request(f"{base}/chat/completions", data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                out = json.loads(r.read().decode())["choices"][0]["message"]["content"] or ""
                return re.sub(r"<think>[\s\S]*?</think>", "", out).strip()
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 4:
                time.sleep(4 * (attempt + 1))
                continue
            return f"错误 HTTP {e.code}"
        except Exception as e:  # noqa: BLE001
            return f"错误 {type(e).__name__}"
    return "错误"


def main():
    old = parse((HERE / "old_glossary.txt").read_text(encoding="utf-8"))
    new = new_glossary()
    total = sum(len(t) for _, t in TESTS)
    print(f"旧表 {len(old)} 条，新表 {len(new)} 条；{len(TESTS)} 句，共 {total} 个术语")
    detail = []
    for name, base, env, model, extra in MODELS:
        key = os.environ.get(env, "").strip()
        if not key:
            print(f"{name}：没有密钥，跳过")
            continue
        score = {}
        for label, g in (("旧表", old), ("新表", new)):
            ok = 0
            for text, terms in TESTS:
                h = hits(text, g)
                system = SYSTEM + ("必须使用以下术语译法：\n" + "\n".join(f"- {a} → {b}" for a, b in h.items()) if h else "")
                out = call(base, key, model, extra, system, text)
                got = sum(1 for t in terms if t in out)
                ok += got
                if got < len(terms):
                    detail.append(f"  [{name}·{label}] 缺 {[t for t in terms if t not in out]}：{out[:90]}")
            score[label] = ok
        print(f"{name}：旧表 {score['旧表']}/{total} → 新表 {score['新表']}/{total}", flush=True)
    print("未命中明细：")
    print("\n".join(detail[:60]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
