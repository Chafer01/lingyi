"""PDF 翻译（BabelDOC）所需的离线资源：版面分析模型、字体、字符映射表、tiktoken 词表。

BabelDOC 首次运行时会从 GitHub / HuggingFace / ModelScope / 微软 下载这些资源到
~/.cache/babeldoc；公司网络或代理拦截时会报 ConnectError，PDF 翻译完全无法使用。

做法：
- 构建时（CI，有网络）调用 collect() 把资源下载到 backend/babeldoc_assets/，PyInstaller 打进安装包；
- 运行时 install() 把缺少或损坏的文件从安装包复制到 BabelDOC 缓存目录，之后翻译无需联网；
- patch_fonts() 把 BabelDOC 的字体族精简为中英文所需：它原本对任何语言都加载全部 34 个字体（266 MB，
  含日文、韩文、繁体），精简后 13 个约 69 MB。逐字选字体的顺序（斜体 → 正文 → 后备）不变，
  去掉的霞鹜文楷只用于斜体中文，去掉后斜体中文用正体宋体显示，不会缺字。
"""
from __future__ import annotations

import logging
import shutil
import sys
from pathlib import Path

log = logging.getLogger("lingyi.pdf")

_ITALIC = ["NotoSans-Italic.ttf", "NotoSans-BoldItalic.ttf", "NotoSerif-Italic.ttf", "NotoSerif-BoldItalic.ttf"]
_LATIN = ["NotoSerif-Regular.ttf", "NotoSerif-Bold.ttf", "NotoSans-Regular.ttf", "NotoSans-Bold.ttf"]
_HAN = ["SourceHanSerifCN-Bold.ttf", "SourceHanSerifCN-Regular.ttf",
        "SourceHanSansCN-Bold.ttf", "SourceHanSansCN-Regular.ttf"]

# 与 BabelDOC 原有 EN/CN 字体族的顺序一致，只去掉繁体、港台、日、韩字体和霞鹜文楷。
EN_FAMILY = {"script": _ITALIC, "normal": _LATIN + _HAN, "fallback": ["GoNotoKurrent-Regular.ttf"],
             "base": ["NotoSans-Regular.ttf"]}
CN_FAMILY = {"script": _ITALIC, "normal": _HAN + _LATIN, "fallback": ["GoNotoKurrent-Regular.ttf"],
             "base": ["SourceHanSansCN-Regular.ttf"]}
FONT_FILES = sorted({f for fam in (EN_FAMILY, CN_FAMILY) for files in fam.values() for f in files})

LAYOUT_MODEL = "doclayout_yolo_docstructbench_imgsz1024.onnx"
SUBDIRS = ("models", "fonts", "cmap", "tiktoken")


def font_family(lang_code: str) -> dict:
    u = (lang_code or "").upper()
    return CN_FAMILY if ("ZH" in u or "CN" in u) else EN_FAMILY


def patch_fonts():
    """让 BabelDOC 只加载中英文需要的字体（必须在创建 TranslationConfig / FontMapper 之前调用）。"""
    from babeldoc.assets import assets
    assets.get_font_family = font_family


def bundled_dir() -> Path | None:
    """安装包里的资源目录（PyInstaller 解包目录或源码目录下的 babeldoc_assets）。"""
    roots = []
    if getattr(sys, "frozen", False):
        roots.append(Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent)))
        roots.append(Path(sys.executable).parent)
    roots.append(Path(__file__).resolve().parents[1])
    for r in roots:
        d = r / "babeldoc_assets"
        if (d / "models" / LAYOUT_MODEL).exists():
            return d
    return None


def _expected_hashes() -> dict[str, dict[str, str]]:
    from babeldoc.assets import embedding_assets_metadata as m
    return {
        "models": {LAYOUT_MODEL: m.DOCLAYOUT_YOLO_DOCSTRUCTBENCH_IMGSZ1024ONNX_SHA3_256},
        "fonts": {f: m.EMBEDDING_FONT_METADATA[f]["sha3_256"] for f in FONT_FILES},
        "cmap": {name: meta["sha3_256"] for name, meta in m.CMAP_METADATA.items()},
        "tiktoken": dict(m.TIKTOKEN_CACHES),
    }


def install(src: Path | None = None) -> dict:
    """把安装包里的资源复制到 BabelDOC 缓存目录（已有且校验通过的跳过）。返回各类复制的文件数。"""
    src = src or bundled_dir()
    if src is None:
        log.info("安装包里没有 PDF 离线资源，将按需联网下载")
        return {"bundled": False}
    from babeldoc.assets.assets import verify_file
    from babeldoc.const import get_cache_file_path

    copied = {k: 0 for k in SUBDIRS}
    for sub, files in _expected_hashes().items():
        for name, sha in files.items():
            s = src / sub / name
            if not s.exists():
                continue
            dst = get_cache_file_path(name, sub)
            if verify_file(dst, sha):
                continue
            tmp = dst.with_name(dst.name + ".part")
            shutil.copyfile(s, tmp)
            tmp.replace(dst)
            copied[sub] += 1
    log.info("PDF 离线资源已就绪（本次复制：%s）", copied)
    return {"bundled": True, **copied}


def collect(dest: Path) -> dict:
    """构建时调用：下载所需资源（版面模型、精简字体、全部字符映射表、tiktoken 词表）到 dest。"""
    import asyncio

    import httpx
    from babeldoc.assets import assets as A
    from babeldoc.const import get_cache_file_path  # 导入时会设置 TIKTOKEN_CACHE_DIR

    async def fetch():
        async with httpx.AsyncClient(timeout=httpx.Timeout(120, connect=30)) as c:
            await A.get_doclayout_onnx_model_path_async(c)
            for f in FONT_FILES:
                await A.get_font_and_metadata_async(f, c)
            await A.download_all_cmaps_async(c)

    import tiktoken
    tiktoken.encoding_for_model("gpt-4o")
    asyncio.run(fetch())

    from babeldoc.assets.assets import verify_file
    sizes = {}
    for sub, files in _expected_hashes().items():
        (dest / sub).mkdir(parents=True, exist_ok=True)
        total = 0
        for name, sha in files.items():
            s = get_cache_file_path(name, sub)
            if not verify_file(s, sha):
                raise RuntimeError(f"资源下载不完整：{sub}/{name}")
            shutil.copyfile(s, dest / sub / name)
            total += s.stat().st_size
        sizes[sub] = round(total / 1e6, 1)
    return sizes


if __name__ == "__main__":
    # python -m lingyi_backend.pdf_assets collect babeldoc_assets
    logging.basicConfig(level=logging.INFO)
    if len(sys.argv) >= 3 and sys.argv[1] == "collect":
        print("已收集（MB）：", collect(Path(sys.argv[2])))
    else:
        print(__doc__)
