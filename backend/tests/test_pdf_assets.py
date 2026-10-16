"""PDF 离线资源：字体族精简与安装。"""
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lingyi_backend import pdf_assets as pa  # noqa: E402


def test_font_family_by_language():
    assert pa.font_family("zh") is pa.CN_FAMILY
    assert pa.font_family("zh-CN") is pa.CN_FAMILY
    assert pa.font_family("en") is pa.EN_FAMILY
    assert pa.font_family("") is pa.EN_FAMILY


def test_families_are_subsets_of_babeldoc_and_keep_order():
    from babeldoc.assets import embedding_assets_metadata as m
    for ours, theirs in ((pa.EN_FAMILY, m.EN_FONT_FAMILY), (pa.CN_FAMILY, m.CN_FONT_FAMILY)):
        m.verify_font_family(ours)                       # 每个字体都在 BabelDOC 的资源清单里
        for k in ("script", "normal", "fallback"):
            kept = [f for f in theirs[k] if f in ours[k]]
            assert kept == ours[k], k                    # 相对顺序与原版一致（影响逐字选字体）
        assert ours["base"] == theirs["base"]
    # 中文正文字体、英文正文字体、后备字体都在
    for f in ("SourceHanSerifCN-Regular.ttf", "SourceHanSansCN-Regular.ttf", "NotoSerif-Regular.ttf",
              "GoNotoKurrent-Regular.ttf"):
        assert f in pa.FONT_FILES
    size = sum(m.EMBEDDING_FONT_METADATA[f]["size"] for f in pa.FONT_FILES)
    assert size < 110e6, size                             # 原版 34 个字体约 266 MB


def test_patch_fonts():
    pa.patch_fonts()
    from babeldoc.assets import assets
    assert assets.get_font_family("zh") is pa.CN_FAMILY


def test_install_copies_missing_and_skips_valid(tmp_path, monkeypatch):
    import babeldoc.const as const

    cache = tmp_path / "cache"
    monkeypatch.setattr(const, "CACHE_FOLDER", cache)
    bundle = tmp_path / "bundle"
    data = {"models": {pa.LAYOUT_MODEL: b"model"}, "fonts": {"A.ttf": b"font-a"}, "cmap": {"X.json": b"{}"},
            "tiktoken": {"abc": b"tok"}}
    hashes = {}
    for sub, files in data.items():
        (bundle / sub).mkdir(parents=True)
        hashes[sub] = {}
        for name, content in files.items():
            (bundle / sub / name).write_bytes(content)
            hashes[sub][name] = hashlib.sha3_256(content).hexdigest()
    monkeypatch.setattr(pa, "_expected_hashes", lambda: hashes)

    r = pa.install(bundle)
    assert r == {"bundled": True, "models": 1, "fonts": 1, "cmap": 1, "tiktoken": 1}
    assert (cache / "fonts" / "A.ttf").read_bytes() == b"font-a"
    # 再装一次：校验通过的文件不重复复制
    assert pa.install(bundle) == {"bundled": True, "models": 0, "fonts": 0, "cmap": 0, "tiktoken": 0}
    # 损坏的文件会被覆盖
    (cache / "fonts" / "A.ttf").write_bytes(b"broken")
    assert pa.install(bundle)["fonts"] == 1
    assert (cache / "fonts" / "A.ttf").read_bytes() == b"font-a"


def test_install_without_bundle(monkeypatch):
    monkeypatch.setattr(pa, "bundled_dir", lambda: None)
    assert pa.install() == {"bundled": False}
