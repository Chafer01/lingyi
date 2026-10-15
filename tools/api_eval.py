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

# OpenAI 兼容的大模型接口：(名称, base_url, 密钥环境变量, 模型列表, 是否专用翻译模型)
LLMS = [
    ("智谱", "https://open.bigmodel.cn/api/paas/v4", "ZHIPU_API_KEY", ["glm-4.7-flash", "glm-4-flash-250414"], False),
    ("硅基流动", "https://api.siliconflow.cn/v1", "SILICONFLOW_API_KEY", ["tencent/Hunyuan-MT-7B"], True),
    ("魔搭", "https://api-inference.modelscope.cn/v1", "MODELSCOPE_API_KEY", ["Qwen/Qwen3.5-27B"], False),
    ("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "GEMINI_API_KEY",
     ["gemini-3.5-flash-lite", "gemini-3.8-flash"], False),
    ("百度千帆", "https://qianfan.baidubce.com/v2", "QIANFAN_API_KEY", ["ernie-speed-128k"], False),
    ("讯飞星火", "https://spark-api-open.xf-yun.com/v1", "SPARK_API_PASSWORD", ["lite"], False),
]


def llm_translate(base, key, model, text, mt_model):
    target = target_of(text)
    if mt_model:
        # Hunyuan-MT 官方推荐的提示格式：不加系统提示，直接给出指令。
        prompt = (f"把下面的文本翻译成{'中文' if target == '简体中文' else 'English'}，不要额外解释。\n\n{text}"
                  if target == "简体中文" else
                  f"Translate the following segment into English, without additional explanation.\n\n{text}")
        messages = [{"role": "user", "content": prompt}]
    else:
        messages = [
            {"role": "system", "content": SYSTEM.format(target=target, glossary=GLOSSARY)},
            {"role": "user", "content": text},
        ]
    body = {"model": model, "messages": messages, "temperature": 0.2, "stream": False}
    code, resp, dt = http("POST", f"{base}/chat/completions",
                          {"Content-Type": "application/json", "Authorization": f"Bearer {key}"}, body)
    if code != 200:
        return None, f"HTTP {code}: {resp[:300]}", dt
    try:
        j = json.loads(resp)
        out = j["choices"][0]["message"]["content"] or ""
        # 部分推理模型会带 <think>…</think>
        if "</think>" in out:
            out = out.split("</think>", 1)[1]
        return out.strip(), None, dt
    except Exception as e:
        return None, f"解析失败: {e}: {resp[:300]}", dt


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


def run_engine(name, model, fn):
    rows, total_hit, total_terms, errors, latencies = [], 0, 0, 0, []
    for t in TESTS:
        out, err, dt = fn(t["src"])
        h, n, miss = score(t, out)
        total_hit += h
        total_terms += n
        latencies.append(dt)
        if err:
            errors += 1
        rows.append({"id": t["id"], "out": out, "err": err, "hit": h, "n": n, "miss": miss,
                     "latency": round(dt, 2)})
        time.sleep(1.2)  # 照顾免费档的限流
    return {"engine": name, "model": model, "mode": "full", "term_hit": total_hit, "term_total": total_terms,
            "errors": errors, "avg_latency": round(sum(latencies) / len(latencies), 2), "rows": rows}


def listed(r):
    if "models_http" not in r:
        return "—"
    if r["model_listed"] is None:
        return f"列表不可读（HTTP {r['models_http']}）"
    return "✅ 存在" if r["model_listed"] else "❌ 不在列表中"


def main():
    results = []
    for name, base, env, models, mt in LLMS:
        key = os.environ.get(env, "").strip()
        for m in models:
            if key:
                print(f"== {name} {m}（实测）", flush=True)
                r = run_engine(name, m, lambda s, b=base, k=key, mm=m, t=mt: llm_translate(b, k, mm, s, t))
                p = probe(name, base, m, key)
                r["models_http"], r["model_listed"] = p["models_http"], p["model_listed"]
                results.append(r)
            else:
                print(f"== {name} {m}（无密钥探测）", flush=True)
                results.append(probe(name, base, m))
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
    md += ["| 接口 | 模型 | 方式 | 结果 | 模型列表中存在 | 术语命中 | 平均延迟 |", "|---|---|---|---|---|---|---|"]
    for r in results:
        if r["mode"] == "probe":
            md.append(f"| {r['engine']} | `{r['model']}` | 无密钥探测 | HTTP {r.get('http')}：{str(r.get('body'))[:120].replace('|', '/').replace(chr(10), ' ')} | {listed(r)} | — | {r.get('latency')}s |")
        else:
            md.append(f"| {r['engine']} | `{r['model']}` | 实测 | 错误 {r['errors']}/{len(TESTS)} | {listed(r)} | {r['term_hit']}/{r['term_total']} | {r['avg_latency']}s |")
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
