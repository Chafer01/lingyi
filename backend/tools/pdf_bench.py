"""PDF 翻译速度实测：真实论文 + 真实 AI 线路，对比不同并发数和“自动提取术语”开关。

    python tools/pdf_bench.py paper.pdf 1-5

需要环境变量 MODELSCOPE_API_KEY、AMD_API_KEY、ZHIPU_API_KEY（线路与灵译默认一致）。
每种配置记录：总耗时、各阶段开始时间、各模型调用次数、是否超时。
"""
from __future__ import annotations

import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lingyi_backend.pdf_jobs import JobManager, PdfRequest  # noqa: E402

MS = os.environ.get("MODELSCOPE_API_KEY", "").strip()
AMD = os.environ.get("AMD_API_KEY", "").strip()
ZP = os.environ.get("ZHIPU_API_KEY", "").strip()
NOTHINK = {"enable_thinking": False}


def endpoints():
    eps = []
    if MS:
        eps += [
            {"label": "Qwen3.5-397B（魔搭）", "base_url": "https://api-inference.modelscope.cn/v1", "api_key": MS,
             "model": "Qwen/Qwen3.5-397B-A17B", "extra_body": NOTHINK},
            {"label": "Qwen3.5-27B（魔搭）", "base_url": "https://api-inference.modelscope.cn/v1", "api_key": MS,
             "model": "Qwen/Qwen3.5-27B", "extra_body": NOTHINK},
        ]
    if AMD:
        eps += [
            {"label": "MiMo-V2.6-Flash（AMD）", "base_url": "https://developer.amd.com.cn/radeon/api/v1",
             "api_key": AMD, "model": "MiMo-V2.6-Flash", "extra_body": {}},
            {"label": "Gemma-4-31B（AMD）", "base_url": "https://developer.amd.com.cn/radeon/api/v1",
             "api_key": AMD, "model": "Gemma-4-31B-IT", "extra_body": {}},
        ]
    if ZP:
        eps.append({"label": "GLM-4-Flash（智谱）", "base_url": "https://open.bigmodel.cn/api/paas/v4", "api_key": ZP,
                    "model": "glm-4-flash-250414", "extra_body": {}})
    return eps


GLOSSARY = [["radiation pattern", "方向图"], ["beamwidth", "波束宽度"], ["attention", "注意力"]]


def run(mgr: JobManager, pdf: str, pages: str, qps: int, terms: bool, limit: float) -> str:
    out = tempfile.mkdtemp()
    job = mgr.submit(PdfRequest(path=pdf, out_dir=out, pages=pages, output="mono", endpoints=endpoints(),
                                qps=qps, glossary=GLOSSARY, extract_terms=terms))
    t0 = time.time()
    stages: list[str] = []
    last = None
    while job.status in ("queued", "running"):
        if job.stage != last and job.stage:
            stages.append(f"{time.time() - t0:.0f}s {job.stage}")
            last = job.stage
        if time.time() - t0 > limit:
            mgr.cancel(job.id)
            while job.status == "running":
                time.sleep(1)
            break
        time.sleep(1)
    dt = time.time() - t0
    state = {"done": "完成", "error": f"失败：{job.error[:200]}", "cancelled": f"超过 {limit / 60:.0f} 分钟未完成，已取消"}
    res = state.get(job.status, job.status)
    return (f"qps={qps} 提取术语={'开' if terms else '关'}：{res}，{dt:.0f}s（进度 {job.progress:.0f}%）\n"
            f"    阶段：{' → '.join(stages)}\n    调用：{dict(job._usage)}")


def main():
    pdf, pages = sys.argv[1], sys.argv[2]
    if not endpoints():
        print("没有密钥，跳过")
        return 0
    mgr = JobManager()
    configs = [(4, False), (8, False), (4, True), (1, True)]   # 最后一个是旧默认
    for qps, terms in configs:
        print(run(mgr, pdf, pages, qps, terms, limit=12 * 60), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
