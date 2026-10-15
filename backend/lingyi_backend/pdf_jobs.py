"""PDF 双语翻译任务（BabelDOC 引擎，保留原排版）。

任务在后台线程里串行执行（免费大模型通常只允许 1 个并发），
界面通过轮询 /pdf/jobs/{id} 取得进度。
"""
from __future__ import annotations

import asyncio
import logging
import threading
import time
import traceback
import uuid
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger("lingyi.pdf")

STAGE_NAMES = {  # BabelDOC 阶段名 → 中文
    "Parse PDF and Create Intermediate Representation": "解析 PDF",
    "DetectScannedFile": "检测扫描件",
    "Parse Page Layout": "版面分析",
    "Parse Paragraphs": "识别段落",
    "Parse Formulas and Styles": "识别公式与样式",
    "Remove Char Descent": "整理字符",
    "Automatic Term Extraction": "提取术语",
    "Translate Paragraphs": "翻译段落",
    "Typesetting": "排版",
    "Add Fonts": "嵌入字体",
    "Generate drawing instructions": "生成绘制指令",
    "Subset font": "字体子集化",
    "Save PDF": "保存 PDF",
}


@dataclass
class PdfRequest:
    path: str
    out_dir: str | None = None
    pages: str | None = None            # 例 "1-5,8"
    lang_in: str = "en"
    lang_out: str = "zh"
    output: str = "dual"                # dual / alternating / mono / both
    base_url: str = ""
    api_key: str = ""
    model: str = ""
    qps: int = 1
    glossary: list = field(default_factory=list)   # [[原文, 译文], ...]
    extract_terms: bool = True


@dataclass
class Job:
    id: str
    req: PdfRequest
    status: str = "queued"              # queued / running / done / error / cancelled
    stage: str = ""
    progress: float = 0.0
    error: str = ""
    outputs: dict = field(default_factory=dict)
    created: float = field(default_factory=time.time)
    finished: float | None = None
    _config: object = None
    _cancel: bool = False

    def public(self) -> dict:
        return {
            "id": self.id, "status": self.status, "stage": self.stage,
            "progress": round(self.progress, 1), "error": self.error,
            "outputs": self.outputs, "file": Path(self.req.path).name,
            "elapsed": round((self.finished or time.time()) - self.created, 1),
        }


class JobManager:
    def __init__(self, runner=None):
        self.jobs: dict[str, Job] = {}
        self._queue: list[str] = []
        self._cv = threading.Condition()
        self._runner = runner or run_babeldoc
        threading.Thread(target=self._loop, daemon=True, name="pdf-worker").start()

    def submit(self, req: PdfRequest) -> Job:
        p = Path(req.path)
        if not p.is_file():
            raise FileNotFoundError(f"找不到文件：{req.path}")
        if p.suffix.lower() != ".pdf":
            raise ValueError("只支持 PDF 文件")
        if not (req.base_url and req.model):
            raise ValueError("请先在灵译设置里配置 AI 翻译接口（PDF 翻译使用 AI 引擎）")
        job = Job(uuid.uuid4().hex[:12], req)
        with self._cv:
            self.jobs[job.id] = job
            self._queue.append(job.id)
            self._cv.notify()
        return job

    def cancel(self, job_id: str) -> Job:
        job = self.jobs[job_id]
        job._cancel = True
        if job.status == "queued":
            job.status, job.finished = "cancelled", time.time()
            with self._cv:
                if job_id in self._queue:
                    self._queue.remove(job_id)
        elif job._config is not None:
            try:
                job._config.cancel_translation()
            except Exception:  # noqa: BLE001
                pass
        return job

    def _loop(self):
        while True:
            with self._cv:
                while not self._queue:
                    self._cv.wait()
                job = self.jobs[self._queue.pop(0)]
            if job._cancel:
                continue
            job.status = "running"
            try:
                job.outputs = self._runner(job) or {}
                job.status = "cancelled" if job._cancel else "done"
                if job.status == "done":
                    job.progress = 100.0
            except asyncio.CancelledError:
                job.status = "cancelled"
            except Exception as e:  # noqa: BLE001
                log.error("PDF 任务失败：%s", traceback.format_exc())
                job.status = "cancelled" if job._cancel else "error"
                job.error = _friendly_error(e)
            finally:
                job.finished = time.time()


def _friendly_error(e: Exception) -> str:
    msg = str(e) or e.__class__.__name__
    low = msg.lower()
    if "401" in msg or "unauthorized" in low or "api key" in low:
        return f"AI 接口鉴权失败，请检查密钥。（{msg[:200]}）"
    if "429" in msg or "rate limit" in low:
        return f"AI 接口请求过于频繁，可把“每秒请求数”调低后重试。（{msg[:200]}）"
    if "connect" in low or "timeout" in low:
        return f"连接失败：可能是网络问题，或首次运行需要下载版面分析模型。（{msg[:200]}）"
    return msg[:500]


# ---------------------------------------------------------------- BabelDOC
_babel_lock = threading.Lock()
_layout_model = None


def _babel_init():
    """加载版面模型（首次运行会自动下载模型和字体，之后走缓存）。"""
    global _layout_model
    with _babel_lock:
        if _layout_model is None:
            import babeldoc.format.pdf.high_level as hl
            from babeldoc.docvision.doclayout import DocLayoutModel
            hl.init()
            _layout_model = DocLayoutModel.load_onnx()
        return _layout_model


def run_babeldoc(job: Job) -> dict:
    from babeldoc.format.pdf import high_level as hl
    from babeldoc.format.pdf.translation_config import TranslationConfig, WatermarkOutputMode
    from babeldoc.glossary import Glossary, GlossaryEntry
    from babeldoc.translator.translator import OpenAITranslator, set_translate_rate_limiter

    req = job.req
    job.stage = "加载版面模型（首次需下载）"
    layout = _babel_init()
    if job._cancel:
        return {}

    translator = OpenAITranslator(
        lang_in=req.lang_in, lang_out=req.lang_out, model=req.model,
        base_url=req.base_url.rstrip("/"), api_key=req.api_key or "none",
    )
    set_translate_rate_limiter(max(1, int(req.qps)))
    glossaries = []
    entries = [GlossaryEntry(s.strip(), t.strip(), req.lang_out)
               for s, t in req.glossary if s.strip() and t.strip()]
    if entries:
        glossaries.append(Glossary("灵译术语表", entries))

    src = Path(req.path)
    out_dir = Path(req.out_dir) if req.out_dir else src.parent
    out_dir.mkdir(parents=True, exist_ok=True)
    config = TranslationConfig(
        translator=translator,
        input_file=str(src),
        lang_in=req.lang_in,
        lang_out=req.lang_out,
        doc_layout_model=layout,
        pages=req.pages or None,
        output_dir=str(out_dir),
        no_dual=req.output == "mono",
        no_mono=req.output in ("dual", "alternating"),
        use_alternating_pages_dual=req.output == "alternating",
        qps=max(1, int(req.qps)),
        watermark_output_mode=WatermarkOutputMode.NoWatermark,
        glossaries=glossaries,
        auto_extract_glossary=req.extract_terms,
        use_rich_pbar=False,
        pool_max_workers=max(1, int(req.qps)),
    )
    getattr(layout, "init_font_mapper", lambda _c: None)(config)
    job._config = config

    async def _run():
        result = None
        async for ev in hl.async_translate(config):
            t = ev.get("type")
            if t in ("progress_start", "progress_update", "progress_end"):
                stage = ev.get("stage", "")
                job.stage = STAGE_NAMES.get(stage, stage)
                if "overall_progress" in ev:
                    job.progress = float(ev["overall_progress"])
            elif t == "error":
                raise RuntimeError(str(ev.get("error")))
            elif t == "finish":
                result = ev["translate_result"]
                break
        return result

    result = asyncio.run(_run())
    if result is None:
        return {}
    outs = {}
    for key, attr in (("dual", "dual_pdf_path"), ("mono", "mono_pdf_path")):
        p = getattr(result, attr, None)
        if p:
            outs[key] = str(p)
    glossary_path = getattr(result, "auto_extracted_glossary_path", None)
    if glossary_path:
        outs["glossary"] = str(glossary_path)
    return outs
