"""多个 OpenAI 兼容接口按顺序自动切换（PDF 翻译用）。

默认线路：魔搭 Qwen3.5-397B → 魔搭 Qwen3.5-27B → 智谱 GLM-4-Flash。
某个接口限流、额度用完、超时或服务端出错时，立即换下一个，并让它“冷却”一段时间；
冷却期间优先用后面的接口，冷却结束后再回到首选。所有接口都暂时不可用时，等一会儿整体重试。
"""
from __future__ import annotations

import os
import logging
import re
import threading
import time
from dataclasses import dataclass, field

log = logging.getLogger("lingyi.ai")

_THINK = re.compile(r"<think>[\s\S]*?</think>")


@dataclass
class Endpoint:
    label: str
    model: str
    base_url: str = ""
    api_key: str = ""
    extra_body: dict = field(default_factory=dict)
    client: object = None


class EmptyReply(Exception):
    """接口返回 200 但没有内容。"""
    status_code = 502


class AllEndpointsFailed(RuntimeError):
    def __init__(self, errors: list[tuple[str, Exception]]):
        self.errors = errors
        lines = [f"{label}：{_short(e)}" for label, e in errors]
        super().__init__("AI 接口均不可用：\n" + "\n".join(lines))


def _short(e: Exception) -> str:
    msg = str(e) or e.__class__.__name__
    return msg if len(msg) <= 200 else msg[:200] + "…"


def classify(e: Exception) -> str:
    """把异常分成：auth / rate / transient / missing / bad。只有 bad 不需要冷却。"""
    status = getattr(e, "status_code", None)
    if status is None:
        resp = getattr(e, "response", None)
        status = getattr(resp, "status_code", None)
    name = e.__class__.__name__
    if status in (401, 403):
        return "auth"
    if status == 429 or name == "RateLimitError":
        return "rate"
    if status == 404:
        return "missing"
    if (isinstance(status, int) and status >= 500) or "Timeout" in name or "Connection" in name \
            or isinstance(e, (TimeoutError, ConnectionError, EmptyReply)):
        return "transient"
    return "bad"


def cooldown(kind: str, consecutive: int) -> float:
    """冷却秒数（与灵译界面端 failCooldown 一致）。"""
    n = max(1, consecutive)
    grow = lambda base, cap: min(cap, base * (2 ** min(n - 1, 10)))  # noqa: E731
    if kind in ("auth", "missing"):
        return 600
    if kind == "rate":
        return grow(30, 600)
    if kind == "transient":
        return grow(15, 300)
    return 0


class EndpointPool:
    def __init__(self, endpoints: list[Endpoint], clock=time.monotonic):
        if not endpoints:
            raise ValueError("没有可用的 AI 接口")
        self.endpoints = endpoints
        self._clock = clock
        self._lock = threading.Lock()
        self._cool_until: dict[int, float] = {}
        self._fails: dict[int, int] = {}
        self.usage: dict[str, int] = {}

    def ordered(self) -> list[Endpoint]:
        now = self._clock()
        with self._lock:
            cooling = [now < self._cool_until.get(i, 0) for i in range(len(self.endpoints))]
        ready = [e for e, c in zip(self.endpoints, cooling) if not c]
        return ready + [e for e, c in zip(self.endpoints, cooling) if c]

    def ok(self, ep: Endpoint):
        i = self.endpoints.index(ep)
        with self._lock:
            self._fails.pop(i, None)
            self._cool_until.pop(i, None)
            self.usage[ep.label] = self.usage.get(ep.label, 0) + 1

    def fail(self, ep: Endpoint, e: Exception) -> str:
        kind = classify(e)
        i = self.endpoints.index(ep)
        with self._lock:
            n = self._fails.get(i, 0) + 1
            self._fails[i] = n
            cd = cooldown(kind, n)
            if cd:
                self._cool_until[i] = self._clock() + cd
        log.warning("AI 接口 %s 失败（%s），切换下一个：%s", ep.label, kind, _short(e))
        return kind

    def call(self, fn, *, rounds: int = 6, sleep=time.sleep):
        """依次尝试各接口。全部失败且都是限流/临时错误时，等待后整体重试。"""
        for r in range(rounds):
            errors: list[tuple[str, Exception]] = []
            kinds = []
            for ep in self.ordered():
                try:
                    out = fn(ep)
                except Exception as e:  # noqa: BLE001
                    kinds.append(self.fail(ep, e))
                    errors.append((ep.label, e))
                    continue
                self.ok(ep)
                return out
            if r < rounds - 1 and kinds and all(k in ("rate", "transient") for k in kinds):
                wait = min(60, 5 * 2 ** r)
                log.warning("AI 接口暂时都不可用，%s 秒后重试", wait)
                sleep(wait)
                continue
            raise AllEndpointsFailed(errors) from errors[-1][1]
        raise AssertionError("unreachable")


def make_translator(lang_in: str, lang_out: str, endpoints: list[dict], timeout: float = 90):
    """创建 BabelDOC 用的翻译器：继承 OpenAITranslator，只替换实际发请求的两个方法。"""
    import httpx
    import openai
    from babeldoc.translator.translator import OpenAITranslator

    try:
        from babeldoc.babeldoc_exception.BabelDOCException import ContentFilterError
    except Exception:  # noqa: BLE001
        ContentFilterError = None  # noqa: N806

    eps = []
    for d in endpoints:
        base = (d.get("base_url") or "").rstrip("/")
        key = d.get("api_key") or "none"
        eps.append(Endpoint(
            label=d.get("label") or d["model"], model=d["model"], base_url=base, api_key=key,
            extra_body=dict(d.get("extra_body") or {}),
            # max_retries=0：失败立即切换，由 EndpointPool 负责重试
            client=openai.OpenAI(base_url=base, api_key=key, max_retries=0,
                                 http_client=httpx.Client(timeout=httpx.Timeout(timeout, connect=15))),
        ))
    first = eps[0]

    class FallbackTranslator(OpenAITranslator):
        def __init__(self):
            super().__init__(lang_in=lang_in, lang_out=lang_out, model=first.model,
                             base_url=first.base_url, api_key=first.api_key)
            self.pool = EndpointPool(eps)
            if os.environ.get("LINGYI_IGNORE_CACHE") == "1":  # 速度实测用：不读翻译缓存
                self.ignore_cache = True
            self.add_cache_impact_parameters("endpoints", "|".join(e.model for e in eps))

        def _create(self, ep: Endpoint, **kw) -> str:
            resp = ep.client.chat.completions.create(model=ep.model, extra_body=ep.extra_body or None, **kw)
            self.update_token_count(resp)
            content = resp.choices[0].message.content if resp.choices else None
            content = _THINK.sub("", content or "").strip()
            if not content:
                raise EmptyReply("没有返回内容")
            return content

        def do_translate(self, text, rate_limit_params: dict = None) -> str:
            opts = dict(self.options) if self.send_temperature else {}
            messages = self.prompt(text)
            return self.pool.call(lambda ep: self._create(ep, messages=messages, **opts))

        def do_llm_translate(self, text, rate_limit_params: dict = None):
            if text is None:
                return None
            opts = dict(self.options) if self.send_temperature else {}
            if self.enable_json_mode_if_requested and (rate_limit_params or {}).get("request_json_mode", False):
                opts["response_format"] = {"type": "json_object"}
            messages = [{"role": "user", "content": text}]
            try:
                return self.pool.call(lambda ep: self._create(ep, max_tokens=2048, messages=messages, **opts))
            except AllEndpointsFailed as e:
                last = e.errors[-1][1] if e.errors else None
                if ContentFilterError and isinstance(last, openai.BadRequestError) and "敏感" in str(last):
                    raise ContentFilterError(str(last)) from e
                raise

    return FallbackTranslator()
