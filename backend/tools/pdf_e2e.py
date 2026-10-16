"""PDF 翻译端到端测试（需要联网下载版面模型；用本地假 AI 接口代替真实大模型）。

    python tools/pdf_e2e.py dist/lingyi_backend/lingyi_backend.exe
    python tools/pdf_e2e.py                     # 测源码

流程：生成一页英文 PDF → 启动后端 → 提交翻译任务（AI 接口指向本地假服务）→ 等待完成 → 检查输出文件。
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
TOKEN = "e2e"


class FakeOpenAI(BaseHTTPRequestHandler):
    """最小的 OpenAI 兼容 /chat/completions：把原文前面加上“译：”返回。"""
    calls = 0
    busy = 0

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if body.get("model") == "busy":     # 模拟首选模型限流，验证自动切换
            FakeOpenAI.busy += 1
            data = b'{"error":{"message":"Request limit exceeded"}}'
            self.send_response(429)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        FakeOpenAI.calls += 1
        user = next((m["content"] for m in reversed(body.get("messages", [])) if m.get("role") == "user"), "")
        if isinstance(user, list):
            user = " ".join(p.get("text", "") for p in user if isinstance(p, dict))
        reply = "译：" + str(user)[-200:]
        out = {
            "id": "x", "object": "chat.completion", "created": int(time.time()), "model": body.get("model", "m"),
            "choices": [{"index": 0, "message": {"role": "assistant", "content": reply}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20},
        }
        data = json.dumps(out, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


def make_pdf(path: Path):
    import pymupdf
    doc = pymupdf.open()
    page = doc.new_page()
    text = ("Base station antennas use phase shifters to adjust the electrical downtilt. "
            "The half-power beamwidth in the horizontal plane is typically 65 degrees, "
            "and the front-to-back ratio exceeds 25 dB across the operating band.")
    page.insert_textbox(pymupdf.Rect(72, 72, 520, 300), text, fontsize=12)
    page.insert_text((72, 340), "1. Introduction", fontsize=16)
    doc.save(path)


def wait_port(p, started: float, timeout: float = 120) -> int:
    """与灵译相同的就绪判断：优先读标准输出的 READY 行，读不到时退回端口文件。"""
    import os
    import queue
    q: "queue.Queue[str]" = queue.Queue()
    def drain():  # 持续读取，避免管道写满（与灵译的做法一致）
        for line in p.stdout:
            q.put(line)
    threading.Thread(target=drain, daemon=True).start()
    port_file = Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".cache") / "lingyi" / "backend.port"
    end = time.time() + timeout
    while time.time() < end:
        try:
            line = q.get(timeout=0.3)
            if line.startswith("LINGYI_BACKEND_READY"):
                return int(line.split()[-1])
        except queue.Empty:
            pass
        if port_file.exists() and port_file.stat().st_mtime >= started - 1:
            port, pid = port_file.read_text().split()[:2]
            if int(pid) == p.pid:
                return int(port)
        if p.poll() is not None:
            raise RuntimeError(f"后端已退出，代码 {p.returncode}")
    raise TimeoutError("后端启动超时")


def call(port, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                 headers={"X-Lingyi-Token": TOKEN, "Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=60) as r:
        return json.load(r)


def main():
    fake = ThreadingHTTPServer(("127.0.0.1", 0), FakeOpenAI)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    fake_url = f"http://127.0.0.1:{fake.server_address[1]}/v1"

    tmp = Path(tempfile.mkdtemp())
    pdf = tmp / "sample.pdf"
    make_pdf(pdf)

    cmd = sys.argv[1:] or [sys.executable, "-m", "lingyi_backend"]
    started = time.time()
    p = subprocess.Popen(cmd + ["--port", "0", "--token", TOKEN, "--watch-stdin"], cwd=HERE,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         text=True, encoding="utf-8", errors="replace")
    try:
        port = wait_port(p, started)
        endpoints = [{"label": "限流模型", "base_url": fake_url, "api_key": "x", "model": "busy",
                      "extra_body": {"enable_thinking": False}},
                     {"label": "备用模型", "base_url": fake_url, "api_key": "x", "model": "fake"}]
        job = call(port, "/pdf/jobs", {"path": str(pdf), "endpoints": endpoints,
                                       "output": "both", "extract_terms": False,
                                       "glossary": [["phase shifter", "移相器"]]})
        last = ""
        deadline = time.time() + 900
        while time.time() < deadline:
            s = call(port, f"/pdf/jobs/{job['id']}")
            line = f"{s['status']} {s['stage']} {s['progress']}%"
            if line != last:
                print(line, flush=True)
                last = line
            if s["status"] in ("done", "error", "cancelled"):
                break
            time.sleep(2)
        assert s["status"] == "done", s
        outs = s["outputs"]
        print("输出：", outs, "AI 调用次数：", FakeOpenAI.calls, "限流次数：", FakeOpenAI.busy, "模型：", s.get("models"))
        assert outs.get("dual") and Path(outs["dual"]).stat().st_size > 1000
        assert outs.get("mono") and Path(outs["mono"]).stat().st_size > 1000
        assert FakeOpenAI.calls > 0
        assert FakeOpenAI.busy >= 1 and s["models"].get("备用模型", 0) > 0, s
        # 译文里的中文要用精简后字体族里的思源字体渲染，且能提取出来（没有缺字方框）
        import pymupdf
        mono = pymupdf.open(outs["mono"])
        fonts = sorted({f"{f[3]}|{f[4]}" for page in mono for f in page.get_fonts()})
        text = "".join(page.get_text() for page in mono)
        print("译文 PDF 字体：", fonts)
        assert any("SourceHan" in f for f in fonts), fonts
        assert "译" in text, text[:200]
        print("PDF 端到端测试通过")
    finally:
        p.stdin.close()
        try:
            p.wait(15)
        except subprocess.TimeoutExpired:
            p.kill()


if __name__ == "__main__":
    main()
