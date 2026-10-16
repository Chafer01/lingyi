"""灵译本地后端 HTTP 接口。只监听 127.0.0.1，并要求请求头携带启动时生成的令牌。"""
from __future__ import annotations

import base64
import io
import os
import threading
from dataclasses import asdict
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

from . import __version__, ocr
from .pdf_jobs import JobManager, PdfRequest

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff", ".webp"}


class OcrBody(BaseModel):
    mode: str = "text"            # text / formula / none（只读取图片，不识别；智能识别由界面端调用视觉模型）
    image: str | None = None      # base64（可带 data:image/png;base64, 前缀）
    path: str | None = None       # 或本地图片路径


class ClipBody(BaseModel):
    mode: str = "text"


class LatexBody(BaseModel):
    latex: str


class PdfBody(BaseModel):
    path: str
    out_dir: str | None = None
    pages: str | None = None
    lang_in: str = "en"
    lang_out: str = "zh"
    output: str = "dual"
    endpoints: list[dict] = []
    base_url: str = ""
    api_key: str = ""
    model: str = ""
    qps: int = 1
    glossary: list[list[str]] = []
    extract_terms: bool = True


# 各功能实际用到的模块。启动时在主线程预先导入（见 __main__.preload），健康检查再确认一遍。
FEATURE_MODULES = {
    "ocr": ("rapidocr_onnxruntime",),
    "formula": ("rapid_latex_ocr", "latex2mathml.converter"),
    "pdf": ("babeldoc.format.pdf.high_level", "babeldoc.format.pdf.translation_config",
            "babeldoc.translator.translator", "babeldoc.docvision.doclayout", "babeldoc.glossary"),
}


def preload() -> dict:
    """在主线程导入所有重型模块。

    Windows 打包程序里，在工作线程中首次导入 scipy 等带原生 DLL 的库可能卡死，
    因此必须在启动时、事件循环开始前由主线程完成导入。返回 {功能: 错误信息}。
    """
    errors = {}
    for name, mods in FEATURE_MODULES.items():
        try:
            for mod in mods:
                _timed_import(mod)
        except Exception as e:  # noqa: BLE001
            errors[name] = f"{e.__class__.__name__}: {e}"
    return errors


def _timed_import(mod: str):
    """导入模块并记录耗时；超过 60 秒把所有线程的调用栈写进日志，便于排查卡死。"""
    import faulthandler
    import logging
    import sys
    import time

    if mod in sys.modules:
        return
    log = logging.getLogger("lingyi.import")
    log.info("import %s ...", mod)
    t = time.time()
    out = getattr(sys.stderr, "fileno", None) and sys.stderr
    timer = None
    if out:
        try:
            timer = threading.Timer(60, lambda: faulthandler.dump_traceback(file=out, all_threads=True))
            timer.daemon = True
            timer.start()
        except Exception:  # noqa: BLE001
            timer = None
    try:
        __import__(mod)
    finally:
        if timer:
            timer.cancel()
    log.info("import %s done in %.1fs", mod, time.time() - t)


def create_app(token: str, jobs: JobManager | None = None) -> FastAPI:
    app = FastAPI(title="lingyi-backend", version=__version__, docs_url=None, redoc_url=None)
    jobs = jobs or JobManager()
    app.state.jobs = jobs

    def auth(x_lingyi_token: str = Header(default="")):
        if token and x_lingyi_token != token:
            raise HTTPException(401, "令牌错误")

    def _png_b64(img) -> str:
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return base64.b64encode(buf.getvalue()).decode()

    def _run(img, mode: str, with_image: bool) -> dict:
        if img.width < 4 or img.height < 4:
            raise HTTPException(400, "图片太小")
        if mode == "formula":
            res = ocr.recognize_formula(img)
        elif mode == "none":
            res = {"text": ""}
        elif mode == "text":
            res = ocr.recognize_text(img)
        else:
            raise HTTPException(400, f"未知模式：{mode}")
        res["mode"] = mode
        res["size"] = [img.width, img.height]
        if with_image:
            res["image"] = _png_b64(img)
        return res

    @app.get("/ping", dependencies=[Depends(auth)])
    def ping():
        return {"ok": True, "pid": os.getpid()}

    @app.get("/health", dependencies=[Depends(auth)])
    def health():
        feats = {}
        errors = {}
        for name, mods in FEATURE_MODULES.items():
            try:
                for mod in mods:
                    _timed_import(mod)
                feats[name] = True
            except Exception as e:  # noqa: BLE001
                feats[name] = False
                errors[name] = f"{e.__class__.__name__}: {e}"
        return {"name": "lingyi-backend", "version": __version__, "features": feats,
                "errors": errors, "pid": os.getpid()}

    @app.post("/ocr", dependencies=[Depends(auth)])
    def ocr_image(body: OcrBody):
        if body.image:
            data = body.image.split(",", 1)[-1] if body.image.startswith("data:") else body.image
            try:
                img = ocr.load_image(base64.b64decode(data))
            except Exception as e:  # noqa: BLE001
                raise HTTPException(400, f"无法读取图片：{e}") from e
            return _run(img, body.mode, with_image=False)
        if body.path:
            p = Path(body.path)
            if not p.is_file() or p.suffix.lower() not in IMAGE_EXT:
                raise HTTPException(400, "不是可识别的图片文件")
            return _run(ocr.load_image(p.read_bytes()), body.mode, with_image=True)
        raise HTTPException(400, "缺少 image 或 path")

    @app.post("/ocr/clipboard", dependencies=[Depends(auth)])
    def ocr_clipboard(body: ClipBody):
        try:
            from PIL import ImageGrab
            got = ImageGrab.grabclipboard()
        except Exception as e:  # noqa: BLE001
            raise HTTPException(400, f"读取剪贴板失败：{e}") from e
        if isinstance(got, list):            # 复制的是文件
            files = [Path(f) for f in got if Path(f).suffix.lower() in IMAGE_EXT]
            if not files:
                raise HTTPException(404, "剪贴板里没有图片")
            img = ocr.load_image(files[0].read_bytes())
        elif got is None:
            raise HTTPException(404, "剪贴板里没有图片")
        else:
            buf = io.BytesIO()
            got.save(buf, format="PNG")
            img = ocr.load_image(buf.getvalue())
        return _run(img, body.mode, with_image=True)

    @app.post("/latex/mathml", dependencies=[Depends(auth)])
    def latex_mathml(body: LatexBody):
        """LaTeX → MathML（粘贴到 Word 即为可编辑公式）。"""
        latex = ocr.tidy_latex(body.latex.strip().strip("$").strip())
        mathml = ocr.to_mathml(latex)
        if not mathml:
            raise HTTPException(400, "无法转换为 Word 公式，请检查 LaTeX")
        return {"latex": latex, "mathml": mathml}

    @app.post("/pdf/jobs", dependencies=[Depends(auth)])
    def pdf_submit(body: PdfBody):
        try:
            job = jobs.submit(PdfRequest(**body.model_dump()))
        except (FileNotFoundError, ValueError) as e:
            raise HTTPException(400, str(e)) from e
        return job.public()

    @app.get("/pdf/jobs", dependencies=[Depends(auth)])
    def pdf_list():
        return [j.public() for j in sorted(jobs.jobs.values(), key=lambda j: -j.created)]

    @app.get("/pdf/jobs/{job_id}", dependencies=[Depends(auth)])
    def pdf_get(job_id: str):
        if job_id not in jobs.jobs:
            raise HTTPException(404, "任务不存在")
        return jobs.jobs[job_id].public()

    @app.post("/pdf/jobs/{job_id}/cancel", dependencies=[Depends(auth)])
    def pdf_cancel(job_id: str):
        if job_id not in jobs.jobs:
            raise HTTPException(404, "任务不存在")
        return jobs.cancel(job_id).public()

    @app.post("/shutdown", dependencies=[Depends(auth)])
    def shutdown():
        threading.Timer(0.2, lambda: os._exit(0)).start()
        return {"ok": True}

    return app
