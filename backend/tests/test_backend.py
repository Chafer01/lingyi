"""后端测试：cd backend && python -m pytest tests -q"""
import base64
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from fastapi.testclient import TestClient

from lingyi_backend import ocr, pdf_jobs
from lingyi_backend.server import create_app

FIX = Path(__file__).parent / "fixtures"
TOKEN = "t0ken"
H = {"X-Lingyi-Token": TOKEN}


def b64(p):
    return base64.b64encode((FIX / p).read_bytes()).decode()


@pytest.fixture(scope="module")
def client():
    return TestClient(create_app(TOKEN))


# ------------------------------------------------------------------ 鉴权 / 健康
def test_auth_required(client):
    assert client.get("/health").status_code == 401
    r = client.get("/health", headers=H)
    assert r.status_code == 200 and r.json()["features"]["ocr"]


# ------------------------------------------------------------------ OCR
def test_ocr_paragraphs(client):
    r = client.post("/ocr", json={"mode": "text", "image": b64("text_paragraphs.png")}, headers=H)
    assert r.status_code == 200, r.text
    paras = r.json()["text"].split("\n")
    assert len(paras) == 3, paras
    assert "beamwidth of 65 degrees" in paras[0]          # 断词合并
    assert paras[1] == "Isolation between ports is better than 28 dB." or paras[1].startswith("Isolation between")
    assert paras[2].startswith("该天线") and paras[2].replace(" ", "").endswith("28dB。")


def test_ocr_formula(client):
    r = client.post("/ocr", json={"mode": "formula", "image": b64("formula_gain.png")}, headers=H)
    assert r.status_code == 200, r.text
    d = r.json()
    assert d["latex"].replace(" ", "") in (r"G=\frac{4\piA_{e}}{\lambda^{2}}", r"G=\frac{4\piA_e}{\lambda^2}")
    assert d["mathml"].startswith("<math")


def test_ocr_by_path_returns_preview(client):
    r = client.post("/ocr", json={"mode": "text", "path": str(FIX / "text_paragraphs.png")}, headers=H)
    assert r.status_code == 200 and r.json()["image"]


def test_ocr_bad_input(client):
    assert client.post("/ocr", json={"mode": "text"}, headers=H).status_code == 400
    assert client.post("/ocr", json={"mode": "x", "image": b64("formula_gain.png")}, headers=H).status_code == 400


def test_join_rules():
    assert ocr._join("trans-", "mission") == "transmission"
    assert ocr._join("S-", "Parameter") == "S- Parameter"     # 大写开头不是断词
    assert ocr._join("天线", "增益") == "天线增益"
    assert ocr.tidy_latex(r"\Gamma\ =\frac{a}{b}") == r"\Gamma=\frac{a}{b}"


# ------------------------------------------------------------------ PDF 任务（假执行器）
def _fake_runner(job):
    for i in range(5):
        if job._cancel:
            return {}
        job.stage, job.progress = "翻译段落", i * 20
        time.sleep(0.05)
    if "fail" in job.req.path:
        raise RuntimeError("HTTP 401 Unauthorized")
    return {"dual": job.req.path.replace(".pdf", ".zh.dual.pdf")}


def _pdf(tmp_path, name="a.pdf"):
    p = tmp_path / name
    p.write_bytes(b"%PDF-1.4\n")
    return str(p)


def test_pdf_jobs_flow(tmp_path):
    jm = pdf_jobs.JobManager(runner=_fake_runner)
    c = TestClient(create_app(TOKEN, jobs=jm))
    body = {"path": _pdf(tmp_path), "base_url": "http://x/v1", "model": "m"}
    j = c.post("/pdf/jobs", json=body, headers=H).json()
    for _ in range(100):
        s = c.get(f"/pdf/jobs/{j['id']}", headers=H).json()
        if s["status"] in ("done", "error"):
            break
        time.sleep(0.05)
    assert s["status"] == "done" and s["outputs"]["dual"].endswith(".zh.dual.pdf") and s["progress"] == 100

    # 失败时给出友好提示
    j2 = c.post("/pdf/jobs", json={**body, "path": _pdf(tmp_path, "fail.pdf")}, headers=H).json()
    for _ in range(100):
        s = c.get(f"/pdf/jobs/{j2['id']}", headers=H).json()
        if s["status"] in ("done", "error"):
            break
        time.sleep(0.05)
    assert s["status"] == "error" and "鉴权" in s["error"]

    # 取消
    j3 = c.post("/pdf/jobs", json=body, headers=H).json()
    c.post(f"/pdf/jobs/{j3['id']}/cancel", headers=H)
    for _ in range(100):
        s = c.get(f"/pdf/jobs/{j3['id']}", headers=H).json()
        if s["status"] not in ("queued", "running"):
            break
        time.sleep(0.05)
    assert s["status"] == "cancelled"


def test_pdf_validation(tmp_path):
    c = TestClient(create_app(TOKEN, jobs=pdf_jobs.JobManager(runner=_fake_runner)))
    r = c.post("/pdf/jobs", json={"path": _pdf(tmp_path)}, headers=H)
    assert r.status_code == 400 and "AI" in r.json()["detail"]
    r = c.post("/pdf/jobs", json={"path": str(tmp_path / "none.pdf"), "base_url": "u", "model": "m"}, headers=H)
    assert r.status_code == 400


def test_babeldoc_config_wiring(tmp_path, monkeypatch):
    """验证传给 BabelDOC 的参数与其 TranslationConfig 签名一致（不真正下载模型和调用接口）。"""
    from babeldoc.format.pdf import high_level as hl

    class DummyLayout:
        pass

    captured = {}

    async def fake_translate(config):
        captured["config"] = config
        yield {"type": "progress_update", "stage": "Translate Paragraphs", "overall_progress": 50.0}

        class R:
            dual_pdf_path = Path(tmp_path / "a.zh.dual.pdf")
            mono_pdf_path = None
            auto_extracted_glossary_path = None
        yield {"type": "finish", "translate_result": R()}

    monkeypatch.setattr(pdf_jobs, "_babel_init", lambda: DummyLayout())
    monkeypatch.setattr(hl, "async_translate", fake_translate)
    req = pdf_jobs.PdfRequest(path=_pdf(tmp_path), base_url="http://127.0.0.1:9/v1", api_key="k",
                              model="glm", pages="1-2", output="alternating",
                              glossary=[["radiation pattern", "方向图"], ["", "x"]])
    job = pdf_jobs.Job("x", req)
    out = pdf_jobs.run_babeldoc(job)
    cfg = captured["config"]
    assert out == {"dual": str(tmp_path / "a.zh.dual.pdf")}
    assert job.stage == "翻译段落" and job.progress == 50.0
    assert cfg.use_alternating_pages_dual and cfg.no_mono and not cfg.no_dual
    assert cfg.page_ranges
    assert any(g.name == "灵译术语表" and len(g.entries) == 1 for g in cfg.shared_context_cross_split_part.user_glossaries) \
        if hasattr(cfg, "shared_context_cross_split_part") else True


def test_fix_lost_spaces():
    assert ocr.fix_spaces("Isolationbetweenportsisbetterthan28dB.") == "Isolation between ports is better than 28dB."
    assert ocr.fix_spaces("Theproposedmetasurfaceantennaachieveshighgain") == \
        "The proposed metasurface antenna achieves high gain"       # 专业词不被拆开
    normal = "The half-power beamwidth of the array is 65 deg."
    assert ocr.fix_spaces(normal) == normal                          # 正常文本不动
    assert ocr.fix_spaces("该天线的metasurface结构") == "该天线的metasurface结构"
