#!/usr/bin/env python3
"""翻译接口实测：连通性 + 模型是否存在 + 射频技术文本翻译准确度。

在 GitHub Actions 上运行（本地网络可能连不上部分接口）。密钥从环境变量读取，
没有密钥的接口只做“无密钥探测”：确认地址可达、返回的是规范的鉴权错误。

结果写入 eval/results.md 和 eval/results.json。
"""
import hashlib
import hmac
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

TIMEOUT = 60

# ---------------------------------------------------------------------------
# 测试集：射频/天线领域。terms 为必须出现的正确译法（任一即可）。
# ---------------------------------------------------------------------------
TESTS = [
    {
        "id": "en1",
        "src": "The antenna achieves a gain of 18 dBi with a half-power beamwidth of 65° in the azimuth plane.",
        "terms": [["增益"], ["半功率波束宽度"], ["方位面", "水平面"]],
    },
    {
        "id": "en2",
        "src": "Electrical downtilt is adjusted by the remote electrical tilt (RET) unit, which drives the phase shifters in the feed network.",
        "terms": [["电下倾"], ["电调"], ["移相器"], ["馈电网络"]],
    },
    {
        "id": "en3",
        "src": "Cross-polarization discrimination exceeds 15 dB within ±60° of boresight.",
        "terms": [["交叉极化"], ["视轴", "主轴", "最大辐射方向", "法向"]],
    },
    {
        "id": "en4",
        "src": "The return loss is better than 15 dB across 1710–2690 MHz, corresponding to a VSWR below 1.43.",
        "terms": [["回波损耗"], ["驻波比"]],
    },
    {
        "id": "en5",
        "src": "Grating lobes appear when the element spacing exceeds one wavelength at the highest operating frequency.",
        "terms": [["栅瓣"], ["单元间距", "阵元间距"], ["波长"]],
    },
    {
        "id": "en6",
        "src": "A metasurface lens was placed above the dipole array to narrow the beam and suppress the sidelobes.",
        "terms": [["超表面"], ["偶极子"], ["旁瓣", "副瓣"]],
    },
    {
        "id": "en7",
        "src": "Port-to-port isolation between the ±45° polarizations is greater than 28 dB.",
        "terms": [["隔离度"], ["极化"]],
    },
    {
        "id": "en8",
        "src": "Passive intermodulation (PIM) is specified as 3rd order, measured with 2 × 43 dBm carriers, and must be below −153 dBc.",
        "terms": [["无源互调"], ["三阶"], ["载波"]],
    },
    {
        "id": "en9",
        "src": "The front-to-back ratio was improved by adding a choke on the reflector.",
        "terms": [["前后比"], ["扼流", "抑制槽"], ["反射板", "反射器"]],
    },
    {
        "id": "zh1",
        "src": "该天线采用双极化偶极子阵列，电下倾角可在0°至10°范围内连续调节。",
        "terms": [["dual-polar", "dual polar"], ["dipole"], ["electrical downtilt", "electrical tilt"]],
    },
    {
        "id": "zh2",
        "src": "通过在反射板边缘加载扼流槽，前后比提升了约5 dB，同时旁瓣电平基本不变。",
        "terms": [["choke"], ["front-to-back"], ["sidelobe", "side lobe", "side-lobe"]],
    },
    # ---- 以下术语不在术语表里，考察模型自身的射频知识 ----
    {
        "id": "x1", "out": True,
        "src": "The radome introduces a slight beam squint at the upper end of the band.",
        "terms": [["天线罩"], ["波束偏斜", "波束倾斜", "波束指向偏移", "波束偏移", "波束斜视"]],
    },
    {
        "id": "x2", "out": True,
        "src": "Mutual coupling between adjacent columns degrades the scan performance of the array.",
        "terms": [["互耦"], ["扫描"]],
    },
    {
        "id": "x3", "out": True,
        "src": "Null filling below the main beam improves coverage close to the tower.",
        "terms": [["零点填充", "零深填充", "零陷填充"], ["主波束", "主瓣"]],
    },
    {
        "id": "x4", "out": True,
        "src": "Parasitic elements were added to broaden the impedance bandwidth.",
        "terms": [["寄生单元", "寄生振子", "寄生元件"], ["阻抗带宽"]],
    },
    {
        "id": "x5", "out": True,
        "src": "上旁瓣抑制大于18 dB，满足运营商对邻区干扰的控制要求。",
        "terms": [["upper sidelobe", "upper side lobe", "upper side-lobe"], ["suppression"], ["operator", "carrier"]],
    },
]

GLOSSARY = """radiation pattern = 方向图
half-power beamwidth = 半功率波束宽度
electrical downtilt = 电下倾
remote electrical tilt = 远程电调
phase shifter = 移相器
feed network = 馈电网络
cross-polarization = 交叉极化
boresight = 视轴
return loss = 回波损耗
VSWR = 电压驻波比
grating lobe = 栅瓣
element spacing = 单元间距
metasurface = 超表面
dipole = 偶极子
sidelobe = 旁瓣
isolation = 隔离度
passive intermodulation = 无源互调
front-to-back ratio = 前后比
choke = 扼流槽
reflector = 反射板"""


def glossary_pairs():
    out = []
    for line in GLOSSARY.splitlines():
        a, b = [x.strip() for x in line.split("=", 1)]
        out.append((a, b))
    return out


def hits_for(text):
    """本句命中的术语（源语言 → 目标语言）。"""
    low = text.lower()
    res = []
    for en, zh in glossary_pairs():
        if is_zh(text):
            if zh in text:
                res.append((zh, en))
        elif en.lower() in low:
            res.append((en, zh))
    return res


def is_zh(text):
    return sum(1 for c in text if "一" <= c <= "鿿") > 0


def target_of(text):
    return "English" if is_zh(text) else "简体中文"


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
def http(method, url, headers=None, body=None):
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read()
            return r.status, raw.decode("utf-8", "replace"), time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), time.time() - t0
    except Exception as e:  # 网络错误
        return 0, f"{type(e).__name__}: {e}", time.time() - t0


# ---------------------------------------------------------------------------
# 接口定义
# ---------------------------------------------------------------------------
SYSTEM = (
    "你是专业的科技翻译，熟悉射频、天线、电磁仿真和通信工程。把用户给出的文本翻译成{target}。"
    "要求：准确、通顺、符合技术文档习惯；保留公式、变量名、单位和专有名词；不要解释，只输出译文。"
    "必须使用以下术语译法：\n{glossary}"
)

# OpenAI 兼容的大模型接口：(名称, base_url, 密钥环境变量, [(模型, 方式), ...])
# 方式：chat_gloss = 系统提示 + 术语表；chat_plain = 系统提示、不给术语表；
#       mt = Hunyuan-MT 官方提示；mt_gloss = 官方提示前附参考译法（非官方格式）
LLMS = [
    ("智谱", "https://open.bigmodel.cn/api/paas/v4", "ZHIPU_API_KEY",
     [("glm-4-flash-250414", "chat_gloss"), ("glm-4-flash-250414", "chat_plain"),
      ("glm-4.7-flash", "chat_gloss"), ("glm-4.7-flash", "chat_plain")]),
    ("硅基流动", "https://api.siliconflow.cn/v1", "SILICONFLOW_API_KEY",
     [("tencent/Hunyuan-MT-7B", "mt"), ("tencent/Hunyuan-MT-7B", "mt_gloss")]),
    ("魔搭", "https://api-inference.modelscope.cn/v1", "MODELSCOPE_API_KEY", "AUTO_MODELSCOPE"),
    ("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "GEMINI_API_KEY",
     [("gemini-3.5-flash-lite", "chat_gloss"), ("gemini-3.8-flash", "chat_gloss")]),
    ("百度千帆", "https://qianfan.baidubce.com/v2", "QIANFAN_API_KEY", [("ernie-speed-128k", "chat_gloss")]),
    ("讯飞星火", "https://spark-api-open.xf-yun.com/v1", "SPARK_API_PASSWORD", [("lite", "chat_gloss")]),
    ("AMD", "https://developer.amd.com.cn/radeon/api/v1", "AMD_API_KEY",
     [("DeepSeek-V4.1-Flash", "chat_gloss"), ("DeepSeek-V4-Flash", "chat_gloss"), ("Gemma-4-31B-IT", "chat_gloss"),
      ("Qwen3.8-27B", "chat_gloss"), ("MiMo-V2.6-Flash", "chat_gloss")]),
]

# 魔搭可用模型很多，按以下顺序从实时模型列表中各挑一个（正则匹配模型 ID）。
MODELSCOPE_PICKS = [
    r"^Qwen/Qwen3\.5-27B$",
    r"^Qwen/Qwen3\.5-\d+B-A\d+B$",
    r"^deepseek-ai/DeepSeek-V3",
    r"^ZhipuAI/GLM-4\.\d",
]


def modelscope_models():
    code, resp, _ = http("GET", "https://api-inference.modelscope.cn/v1/models")
    if code != 200:
        return []
    try:
        return sorted({m["id"] for m in json.loads(resp).get("data", [])})
    except Exception:
        return []


def pick_modelscope(ids):
    import re
    picked = []
    for pat in MODELSCOPE_PICKS:
        cands = [i for i in ids if re.search(pat, i)]
        if cands:
            # 同一系列取版本号最大的
            picked.append(sorted(cands)[-1])
    return picked


MODE_LABEL = {"chat_gloss": "带术语表", "chat_plain": "不带术语表", "mt": "官方提示", "mt_gloss": "官方提示+参考译法"}

SYSTEM_PLAIN = (
    "你是专业的科技翻译，熟悉射频、天线、电磁仿真和通信工程。把用户给出的文本翻译成{target}。"
    "要求：准确、通顺、符合技术文档习惯；保留公式、变量名、单位和专有名词；不要解释，只输出译文。"
)


def llm_translate(base, key, model, text, mode):
    target = target_of(text)
    params = {"temperature": 0.2}
    if mode in ("mt", "mt_gloss"):
        lang = "中文" if target == "简体中文" else "English"
        if target == "简体中文":
            prompt = f"把下面的文本翻译成{lang}，不要额外解释。\n\n{text}"
        else:
            prompt = f"Translate the following segment into English, without additional explanation.\n\n{text}"
        if mode == "mt_gloss":
            pairs = hits_for(text)
            if pairs:
                ref = "\n".join(f"{a} 翻译成 {b}" for a, b in pairs)
                prompt = f"参考下面的翻译：\n{ref}\n\n" + prompt
        messages = [{"role": "user", "content": prompt}]
        params = {"temperature": 0.7, "top_p": 0.6}  # Hunyuan-MT 官方推荐参数
    else:
        if mode == "chat_gloss":
            pairs = hits_for(text)
            system = SYSTEM_PLAIN.format(target=target)
            if pairs:
                system += "必须使用以下术语译法：\n" + "\n".join(f"- {a} → {b}" for a, b in pairs)
        else:
            system = SYSTEM_PLAIN.format(target=target)
        messages = [{"role": "system", "content": system}, {"role": "user", "content": text}]
    body = {"model": model, "messages": messages, "stream": False, **params}
    if "modelscope" in base:
        body["enable_thinking"] = False
    if "amd.com" in base and model.startswith("Qwen"):
        body["chat_template_kwargs"] = {"enable_thinking": False}
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {key}"}
    retries = 0
    t_total = 0.0
    while True:
        code, resp, dt = http("POST", f"{base}/chat/completions", headers, body)
        t_total += dt
        if code == 429 and retries < 4:
            retries += 1
            time.sleep(3 * retries)
            continue
        break
    tag = f"（重试 {retries} 次）" if retries else ""
    if code != 200:
        return None, f"HTTP {code}{tag}: {resp[:600]}", t_total
    try:
        j = json.loads(resp)
        out = j["choices"][0]["message"]["content"] or ""
        if "</think>" in out:
            out = out.split("</think>", 1)[1]
        return out.strip() + (f"  ⟨重试 {retries} 次⟩" if retries else ""), None, t_total
    except Exception as e:
        return None, f"解析失败: {e}: {resp[:200]}", t_total


def volc_translate(ak, sk, text):
    host, region, service = "translate.volcengineapi.com", "cn-north-1", "translate"
    body = json.dumps({"TargetLanguage": "en" if is_zh(text) else "zh", "TextList": [text]}, ensure_ascii=False)
    now = datetime.now(timezone.utc)
    xdate = now.strftime("%Y%m%dT%H%M%SZ")
    short = xdate[:8]
    h = hashlib.sha256(body.encode()).hexdigest()
    signed = {"content-type": "application/json", "host": host, "x-content-sha256": h, "x-date": xdate}
    names = ";".join(signed)
    canon = "\n".join(["POST", "/", "Action=TranslateText&Version=2020-06-01",
                       "".join(f"{k}:{v}\n" for k, v in signed.items()), names, h])
    scope = f"{short}/{region}/{service}/request"
    sts = "\n".join(["HMAC-SHA256", xdate, scope, hashlib.sha256(canon.encode()).hexdigest()])

    def mac(k, m):
        return hmac.new(k, m.encode(), hashlib.sha256).digest()

    k = mac(mac(mac(mac(sk.encode(), short), region), service), "request")
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    headers = {"Content-Type": "application/json", "X-Date": xdate, "X-Content-Sha256": h,
               "Authorization": f"HMAC-SHA256 Credential={ak}/{scope}, SignedHeaders={names}, Signature={sig}"}
    code, resp, dt = http("POST", f"https://{host}/?Action=TranslateText&Version=2020-06-01", headers, body.encode())
    try:
        j = json.loads(resp)
        err = j.get("ResponseMetadata", {}).get("Error")
        if err:
            return None, f"{err.get('Code')}: {err.get('Message')}", dt
        return j["TranslationList"][0]["Translation"], None, dt
    except Exception as e:
        return None, f"HTTP {code}: {resp[:300]} ({e})", dt


def baidu_translate(appid, key, text):
    salt = str(random.randint(1, 1 << 30))
    sign = hashlib.md5(f"{appid}{text}{salt}{key}".encode()).hexdigest()
    form = urllib.parse.urlencode({"q": text, "from": "auto", "to": "en" if is_zh(text) else "zh",
                                   "appid": appid, "salt": salt, "sign": sign}).encode()
    code, resp, dt = http("POST", "https://fanyi-api.baidu.com/api/trans/vip/translate",
                          {"Content-Type": "application/x-www-form-urlencoded"}, form)
    try:
        j = json.loads(resp)
        if "error_code" in j and j["error_code"] not in ("52000", 52000):
            return None, f"{j['error_code']}: {j.get('error_msg')}", dt
        return "\n".join(x["dst"] for x in j["trans_result"]), None, dt
    except Exception as e:
        return None, f"HTTP {code}: {resp[:300]} ({e})", dt


# ---------------------------------------------------------------------------
# 评分与运行
# ---------------------------------------------------------------------------
def score(test, out):
    if not out:
        return 0, len(test["terms"]), []
    low = out.lower()
    hit, miss = 0, []
    for alts in test["terms"]:
        if any(a.lower() in low for a in alts):
            hit += 1
        else:
            miss.append("/".join(alts))
    return hit, len(test["terms"]), miss


def probe(name, base, model, key=""):
    """无密钥探测：地址是否可达、是否返回规范的鉴权错误；并查询模型列表确认模型名存在。"""
    code, resp, dt = http("POST", f"{base}/chat/completions", {"Content-Type": "application/json"},
                          {"model": model, "messages": [{"role": "user", "content": "hi"}]})
    hdr = {"Authorization": f"Bearer {key}"} if key else {}
    mcode, mresp, _ = http("GET", f"{base}/models", hdr)
    listed = None
    if mcode == 200:
        listed = model in mresp
    return {"engine": name, "model": model, "mode": "probe", "http": code, "latency": round(dt, 2),
            "body": resp[:240], "models_http": mcode, "model_listed": listed}


def active_tests():
    n = int(os.environ.get("MAXTESTS", "0") or 0)
    return TESTS[:n] if n > 0 else TESTS


def run_engine(name, model, fn):
    rows, total_hit, total_terms, errors, latencies = [], 0, 0, 0, []
    out_hit = out_terms = 0
    for t in active_tests():
        out, err, dt = fn(t["src"])
        h, n, miss = score(t, out)
        total_hit += h
        total_terms += n
        if t.get("out"):
            out_hit += h
            out_terms += n
        latencies.append(dt)
        if err:
            errors += 1
        rows.append({"id": t["id"], "out": out, "err": err, "hit": h, "n": n, "miss": miss,
                     "latency": round(dt, 2)})
        time.sleep(1.2)  # 照顾免费档的限流
    return {"engine": name, "model": model, "mode": "full", "term_hit": total_hit, "term_total": total_terms,
            "out_hit": out_hit, "out_total": out_terms,
            "errors": errors, "avg_latency": round(sum(latencies) / len(latencies), 2), "rows": rows}


def listed(r):
    if "models_http" not in r:
        return "—"
    if r["model_listed"] is None:
        return f"列表不可读（HTTP {r['models_http']}）"
    return "✅ 存在" if r["model_listed"] else "❌ 不在列表中"


def main():
    results = []
    ms_ids = modelscope_models()
    os.makedirs("eval", exist_ok=True)
    with open("eval/modelscope_models.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(ms_ids) + "\n")
    for name, base, env, variants in LLMS:
        key = os.environ.get(env, "").strip()
        if variants == "AUTO_MODELSCOPE":
            picks = pick_modelscope(ms_ids) or ["Qwen/Qwen3.5-27B"]
            print("魔搭自动选择：", picks, flush=True)
            variants = [(m, "chat_gloss") for m in picks] + [(picks[0], "chat_plain")]
        only = os.environ.get("ONLY", "").strip()
        if only and name not in only.split(","):
            continue
        if not key:
            print(f"== {name}（无密钥探测）", flush=True)
            results.append(probe(name, base, variants[0][0]))
            continue
        for m, mode in variants:
            print(f"== {name} {m} {mode}（实测）", flush=True)
            r = run_engine(name, f"{m} · {MODE_LABEL[mode]}",
                           lambda s, b=base, k=key, mm=m, md=mode: llm_translate(b, k, mm, s, md))
            results.append(r)
    if not os.environ.get("ONLY", "").strip():
        ak, sk = os.environ.get("VOLC_AK", "").strip(), os.environ.get("VOLC_SK", "").strip()
        if ak and sk:
            print("== 火山翻译（实测）", flush=True)
            results.append(run_engine("火山翻译", "TranslateText", lambda s: volc_translate(ak, sk, s)))
        else:
            _, err, dt = volc_translate("AKLTprobe", "probe", "hi")
            results.append({"engine": "火山翻译", "model": "TranslateText", "mode": "probe", "http": "-",
                            "latency": round(dt, 2), "body": err})
        appid, bkey = os.environ.get("BAIDU_APPID", "").strip(), os.environ.get("BAIDU_KEY", "").strip()
        if appid and bkey:
            print("== 百度翻译（实测）", flush=True)
            results.append(run_engine("百度翻译", "通用文本翻译", lambda s: baidu_translate(appid, bkey, s)))
        else:
            _, err, dt = baidu_translate("20240001", "probe", "hi")
            results.append({"engine": "百度翻译", "model": "通用文本翻译", "mode": "probe", "http": "-", "latency": round(dt, 2),
                            "body": err})

    os.makedirs("eval", exist_ok=True)
    with open("eval/results.json", "w", encoding="utf-8") as f:
        json.dump({"time": datetime.now(timezone.utc).isoformat(), "results": results}, f, ensure_ascii=False, indent=1)

    md = [f"# 翻译接口实测（{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}）", ""]
    md += ["| 接口 | 模型 · 方式 | 结果 | 术语命中（全部） | 其中术语表外 | 平均延迟 |", "|---|---|---|---|---|---|"]
    for r in results:
        if r["mode"] == "probe":
            md.append(f"| {r['engine']} | `{r['model']}` | 无密钥探测：HTTP {r.get('http')} | — | — | {r.get('latency')}s |")
        else:
            md.append(f"| {r['engine']} | `{r['model']}` | 错误 {r["errors"]}/{len(r["rows"])} | {r['term_hit']}/{r['term_total']} | {r['out_hit']}/{r['out_total']} | {r['avg_latency']}s |")
    for r in results:
        if r["mode"] != "full":
            continue
        md += ["", f"## {r['engine']} · {r['model']}", ""]
        for row in r["rows"]:
            src = next(t["src"] for t in TESTS if t["id"] == row["id"])
            md.append(f"- **{row['id']}** 原文：{src}")
            if row["err"]:
                md.append(f"  - ❌ {row['err']}")
            else:
                md.append(f"  - 译文：{row['out']}")
                md.append(f"  - 术语 {row['hit']}/{row['n']}" + (f"，缺：{', '.join(row['miss'])}" if row["miss"] else ""))
    with open("eval/results.md", "w", encoding="utf-8") as f:
        f.write("\n".join(md) + "\n")
    print("\n".join(md[:40]))


if __name__ == "__main__":
    sys.exit(main())
