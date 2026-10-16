"""用真实密钥验证 PDF 翻译后端的 AI 线路（EndpointPool + OpenAI 客户端）。

由“AI 线路实测”工作流运行：
    python tools/chain_live.py
需要环境变量 MODELSCOPE_API_KEY、ZHIPU_API_KEY。检查：
  1. 默认线路 397B → 27B → 智谱 依次可用，翻译 PDF 里常见的整段文字；
  2. 首选失效（不存在的模型）时自动切换，并记录调用次数；
  3. 连续翻译多段时，各模型的实际调用次数（对应 PDF 任务卡片上的“AI 调用”）。
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import httpx  # noqa: E402
import openai  # noqa: E402

from lingyi_backend.ai_fallback import Endpoint, EndpointPool  # noqa: E402

MS = os.environ.get("MODELSCOPE_API_KEY", "").strip()
ZP = os.environ.get("ZHIPU_API_KEY", "").strip()
MS_URL = "https://api-inference.modelscope.cn/v1"
ZP_URL = "https://open.bigmodel.cn/api/paas/v4"

PARAGRAPHS = [
    "The antenna achieves a gain of 18 dBi with a half-power beamwidth of 65° in the azimuth plane. "
    "Electrical downtilt is adjusted by the remote electrical tilt (RET) unit, which drives the phase shifters "
    "in the feed network.",
    "Grating lobes appear when the element spacing exceeds one wavelength at the highest operating frequency. "
    "Mutual coupling between adjacent columns degrades the scan performance of the array.",
    "A metasurface lens was placed above the dipole array to narrow the beam and suppress the sidelobes, "
    "while the radome introduces a slight beam squint at the upper end of the band.",
]

SYSTEM = ("You are a professional translator for RF and antenna engineering. Translate the user's text into "
          "Simplified Chinese. Output only the translation. Use these terms: radome → 天线罩; beam squint → 波束偏斜; "
          "mutual coupling → 互耦; grating lobe → 栅瓣; electrical downtilt → 电下倾.")


def make(label, base, key, model, extra=None):
    return Endpoint(label=label, model=model, base_url=base, api_key=key, extra_body=extra or {},
                    client=openai.OpenAI(base_url=base, api_key=key, max_retries=0,
                                         http_client=httpx.Client(timeout=httpx.Timeout(90, connect=15))))


def chain():
    nothink = {"enable_thinking": False}
    return [
        make("Qwen3.5-397B（魔搭）", MS_URL, MS, "Qwen/Qwen3.5-397B-A17B", nothink),
        make("Qwen3.5-27B（魔搭）", MS_URL, MS, "Qwen/Qwen3.5-27B", nothink),
        make("GLM-4-Flash（智谱）", ZP_URL, ZP, "glm-4-flash-250414"),
    ]


def ask(ep: Endpoint, text: str) -> str:
    r = ep.client.chat.completions.create(
        model=ep.model, temperature=0.2, extra_body=ep.extra_body or None,
        messages=[{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}])
    out = (r.choices[0].message.content or "").strip() if r.choices else ""
    if not out:
        raise RuntimeError("没有返回内容")
    return out


def main() -> int:
    if not (MS and ZP):
        print("没有配置 MODELSCOPE_API_KEY / ZHIPU_API_KEY，跳过")
        return 0
    failures = 0

    print("== 1. 默认线路翻译整段文字")
    pool = EndpointPool(chain())
    for p in PARAGRAPHS:
        t0 = time.time()
        used = {}

        def fn(ep, p=p, used=used):
            used["ep"] = ep.label
            return ask(ep, p)

        try:
            out = pool.call(fn, rounds=2)
            print(f"  [{used['ep']}] {time.time() - t0:.1f}s  {out}")
        except Exception as e:  # noqa: BLE001
            failures += 1
            print(f"  ❌ {e}")
    print(f"  调用次数：{pool.usage}")

    print("== 2. 首选失效时自动切换")
    broken = make("不存在的模型", MS_URL, MS, "Qwen/Not-A-Real-Model")
    pool2 = EndpointPool([broken, *chain()])
    try:
        out = pool2.call(lambda ep: ask(ep, PARAGRAPHS[2]), rounds=1)
        print(f"  调用次数：{pool2.usage}")
        print(f"  译文：{out}")
        if "不存在的模型" in pool2.usage:
            failures += 1
            print("  ❌ 不存在的模型居然调用成功了")
        if "天线罩" not in out:
            print("  ⚠ 译文里没有“天线罩”")
    except Exception as e:  # noqa: BLE001
        failures += 1
        print(f"  ❌ {e}")

    print("== 结果：" + ("全部通过" if failures == 0 else f"{failures} 项失败"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
