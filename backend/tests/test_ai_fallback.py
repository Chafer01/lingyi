"""AI 接口自动切换。"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lingyi_backend import ai_fallback as af  # noqa: E402


class HttpErr(Exception):
    def __init__(self, status):
        super().__init__(f"HTTP {status}")
        self.status_code = status


class RateLimitError(Exception):
    pass


class APITimeoutError(Exception):
    pass


def eps():
    return [af.Endpoint("Qwen3.5-397B（魔搭）", "Qwen/Qwen3.5-397B-A17B"),
            af.Endpoint("Qwen3.5-27B（魔搭）", "Qwen/Qwen3.5-27B"),
            af.Endpoint("GLM-4-Flash（智谱）", "glm-4-flash-250414")]


def test_classify():
    assert af.classify(HttpErr(429)) == "rate"
    assert af.classify(RateLimitError()) == "rate"
    assert af.classify(HttpErr(401)) == "auth"
    assert af.classify(HttpErr(503)) == "transient"
    assert af.classify(APITimeoutError()) == "transient"
    assert af.classify(af.EmptyReply()) == "transient"
    assert af.classify(HttpErr(400)) == "bad"
    assert af.cooldown("rate", 1) == 30 and af.cooldown("rate", 3) == 120 and af.cooldown("rate", 30) == 600
    assert af.cooldown("bad", 1) == 0


def test_fallback_and_cooldown():
    now = [0.0]
    pool = af.EndpointPool(eps(), clock=lambda: now[0])
    calls = []

    def fn(ep):
        calls.append(ep.model)
        if ep.model.endswith("397B-A17B"):
            raise HttpErr(429)
        return "译文 " + ep.label

    assert pool.call(fn) == "译文 Qwen3.5-27B（魔搭）"
    assert calls == ["Qwen/Qwen3.5-397B-A17B", "Qwen/Qwen3.5-27B"]
    # 冷却中：直接从 27B 开始
    calls.clear()
    pool.call(fn)
    assert calls == ["Qwen/Qwen3.5-27B"]
    # 冷却结束：回到首选
    now[0] = 31
    calls.clear()
    pool.call(fn)
    assert calls[0] == "Qwen/Qwen3.5-397B-A17B"
    assert pool.usage == {"Qwen3.5-27B（魔搭）": 3}


def test_all_rate_limited_waits_then_succeeds():
    pool = af.EndpointPool(eps())
    state = {"n": 0}
    sleeps = []

    def fn(ep):
        state["n"] += 1
        if state["n"] <= 3:
            raise HttpErr(429)
        return "ok"

    assert pool.call(fn, sleep=sleeps.append) == "ok"
    assert sleeps == [5]


def test_all_fail_reports_each():
    pool = af.EndpointPool(eps())
    with pytest.raises(af.AllEndpointsFailed) as ei:
        pool.call(lambda ep: (_ for _ in ()).throw(HttpErr(401)), sleep=lambda s: None)
    msg = str(ei.value)
    assert "Qwen3.5-397B" in msg and "GLM-4-Flash" in msg and "401" in msg


class _Fake(BaseHTTPRequestHandler):
    seen: list = []

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        _Fake.seen.append(body)
        if body["model"] == "busy":
            data = b'{"error":{"message":"Request limit exceeded"}}'
            self.send_response(429)
        else:
            data = json.dumps({"id": "x", "object": "chat.completion", "created": 0, "model": body["model"],
                               "choices": [{"index": 0, "finish_reason": "stop",
                                            "message": {"role": "assistant", "content": "<think>…</think>天线罩"}}],
                               "usage": {"prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5}},
                              ensure_ascii=False).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


def test_babeldoc_translator_switches(tmp_path, monkeypatch):
    pytest.importorskip("babeldoc")
    monkeypatch.setenv("NO_PROXY", "127.0.0.1")
    srv = ThreadingHTTPServer(("127.0.0.1", 0), _Fake)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_address[1]}/v1"
    try:
        tr = af.make_translator("en", "zh", [
            {"label": "忙", "base_url": url, "api_key": "k", "model": "busy", "extra_body": {"enable_thinking": False}},
            {"label": "备用", "base_url": url, "api_key": "k", "model": "ok"},
        ])
        assert tr.do_translate("radome") == "天线罩"
        assert tr.do_llm_translate("radome") == "天线罩"
        assert tr.pool.usage == {"备用": 2}
        assert _Fake.seen[0]["model"] == "busy" and _Fake.seen[0]["enable_thinking"] is False
        assert tr.token_count.value > 0
    finally:
        srv.shutdown()
