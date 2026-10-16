"""AMD Radeon Cloud Token Factory 诊断：列出模型 ID，逐个测首字延迟（流式）和总耗时。"""
import json
import os
import time
import urllib.error
import urllib.request

KEY = os.environ.get("AMD_API_KEY", "").strip()
BASE = os.environ.get("AMD_BASE_URL", "https://developer.amd.com.cn/radeon/api/v1").rstrip("/")
HDR = {"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"}


def get_models():
    req = urllib.request.Request(f"{BASE}/models", headers=HDR)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.loads(r.read().decode())
        return [m.get("id") for m in data.get("data", [])], None
    except urllib.error.HTTPError as e:
        return [], f"HTTP {e.code} {e.read().decode()[:300]}"
    except Exception as e:  # noqa: BLE001
        return [], f"{type(e).__name__}: {e}"


def stream_test(model):
    body = {"model": model, "stream": True, "max_tokens": 64, "temperature": 0.2,
            "messages": [{"role": "user", "content": "把这句话翻译成中文，只输出译文：The antenna gain is 18 dBi."}]}
    req = urllib.request.Request(f"{BASE}/chat/completions", data=json.dumps(body).encode(), headers=HDR, method="POST")
    t0 = time.time()
    first = None
    text = ""
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            for raw in r:
                line = raw.decode("utf-8", "ignore").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    d = json.loads(payload)
                except ValueError:
                    continue
                ch = (d.get("choices") or [{}])[0].get("delta") or {}
                piece = ch.get("content") or ""
                if (piece or ch.get("reasoning_content")) and first is None:
                    first = time.time() - t0
                text += piece
        ft = "无" if first is None else f"{first:.1f}s"
        return f"首字 {ft}，总 {time.time() - t0:.1f}s → {text.strip()[:80]!r}"
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code} {e.read().decode()[:200]} ({time.time() - t0:.1f}s)"
    except Exception as e:  # noqa: BLE001
        return f"{type(e).__name__}: {e} ({time.time() - t0:.1f}s)"


print(f"密钥长度 {len(KEY)}，接口 {BASE}")
if not KEY:
    print("没有读到 AMD_API_KEY")
    raise SystemExit(0)
ids, err = get_models()
print("模型列表：", err or ", ".join(ids))
for m in ids:
    print(f"[{m}] {stream_test(m)}")
