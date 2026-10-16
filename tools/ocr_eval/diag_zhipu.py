"""诊断智谱视觉模型调用失败的原因：密钥、传图方式、thinking 参数逐项排查。"""
import base64
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

KEY = os.environ.get("ZHIPU_API_KEY", "").strip()
URL = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
PNG = (Path(__file__).resolve().parent / "fixtures" / "friis_only.png").read_bytes()
B64 = base64.b64encode(PNG).decode()
PUBLIC = "https://raw.githubusercontent.com/Chafer01/lingyi/main/tools/ocr_eval/fixtures/friis_only.png"


def call(label, body):
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            txt = r.read().decode()
            out = json.loads(txt)["choices"][0]["message"]["content"]
            print(f"[{label}] 200 → {out[:160]!r}")
    except urllib.error.HTTPError as e:
        print(f"[{label}] HTTP {e.code} → {e.read().decode()[:300]}")
    except Exception as e:  # noqa: BLE001
        print(f"[{label}] {type(e).__name__}: {e}")


def img(url):
    return [{"type": "image_url", "image_url": {"url": url}}, {"type": "text", "text": "识别图中的公式，输出 LaTeX。"}]


print(f"密钥长度 {len(KEY)}，含点号：{'.' in KEY}")
call("文本 glm-4-flash-250414", {"model": "glm-4-flash-250414", "messages": [{"role": "user", "content": "回复 OK"}]})
for model in ["glm-4.6v-flash", "glm-4v-flash", "glm-4.1v-thinking-flash"]:
    call(f"{model} 纯文本", {"model": model, "messages": [{"role": "user", "content": "回复 OK"}]})
    call(f"{model} 公网 URL", {"model": model, "messages": [{"role": "user", "content": img(PUBLIC)}]})
    call(f"{model} 纯 base64", {"model": model, "messages": [{"role": "user", "content": img(B64)}]})
    call(f"{model} data URL", {"model": model, "messages": [{"role": "user", "content": img(f'data:image/png;base64,{B64}')}]})
sys.exit(0)
