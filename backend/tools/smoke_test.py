"""冒烟测试：以灵译同样的方式启动后端（标准输入管道 + 随机端口 + 令牌），检查各功能可用。

    python tools/smoke_test.py dist/lingyi_backend/lingyi_backend.exe   # 测打包后的 exe
    python tools/smoke_test.py                                          # 测源码（python -m lingyi_backend）

打包遗漏模型或数据文件时，这里会失败，CI 据此报错。
"""
from __future__ import annotations

import base64
import json
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
FIX = HERE / "tests" / "fixtures"
TOKEN = "smoke"


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


def call(port, path, body=None, timeout=300):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                 headers={"X-Lingyi-Token": TOKEN, "Content-Type": "application/json"})
    # 不走系统代理（CI 或公司网络可能设置了 HTTP_PROXY）
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as r:
        return json.load(r)


def dump_logs():
    import os
    d = Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".cache") / "lingyi"
    for name in ("backend.log", "backend.out.log"):
        f = d / name
        if f.exists():
            print(f"----- {name}（末尾）-----")
            print(f.read_text(encoding="utf-8", errors="replace")[-4000:])


def main():
    cmd = sys.argv[1:] or [sys.executable, "-m", "lingyi_backend"]
    started = time.time()
    p = subprocess.Popen(cmd + ["--port", "0", "--token", TOKEN, "--watch-stdin"], cwd=HERE,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         text=True, encoding="utf-8", errors="replace")
    try:
        port = wait_port(p, started)
        print("端口", port)
        t = time.time()
        print("ping", call(port, "/ping", timeout=30), f"{time.time() - t:.1f}s")
        t = time.time()
        h = call(port, "/health")
        print(f"health {time.time() - t:.1f}s")
        print("health", h)
        assert all(h["features"].values()), h

        t = time.time()
        img = base64.b64encode((FIX / "text_paragraphs.png").read_bytes()).decode()
        r = call(port, "/ocr", {"mode": "text", "image": img})
        print(f"文字识别 {time.time() - t:.1f}s：", r["text"].replace("\n", " | "))
        assert "beamwidth" in r["text"] and "隔离度" in r["text"]

        t = time.time()
        img = base64.b64encode((FIX / "formula_gain.png").read_bytes()).decode()
        r = call(port, "/ocr", {"mode": "formula", "image": img})
        print(f"公式识别 {time.time() - t:.1f}s：", r["latex"])
        assert r["latex"].startswith("G=") and r["mathml"]

        # PDF：只验证 BabelDOC 能被加载、参数校验正常（真正翻译需要网络和 API 密钥）
        try:
            call(port, "/pdf/jobs", {"path": str(FIX / "nope.pdf"), "base_url": "x", "model": "y"})
            raise AssertionError("应当报错")
        except urllib.error.HTTPError as e:
            assert e.code == 400
        print("全部通过")
    except Exception as e:  # noqa: BLE001
        print(f"失败：{e.__class__.__name__}: {e}", flush=True)
        dump_logs()
        sys.exit(1)
    finally:
        p.stdin.close()          # 模拟灵译退出
        try:
            p.wait(10)
        except subprocess.TimeoutExpired:
            p.kill()
            print("后端没有随标准输入关闭而退出")
            sys.exit(1)


if __name__ == "__main__":
    main()
