"""精简实现与真正的 scikit-image / scikit-learn 逐一比对（需要开发环境装有这两个库）。"""
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lingyi_backend import _compat  # noqa: E402



def _real(name: str, attr: str):
    """绕过 _compat 注册的替身，取得真正库中的对象（没有安装则跳过测试）。"""
    import importlib
    pkg = name.split(".")[0]
    saved = {k: sys.modules.pop(k) for k in list(sys.modules) if k == pkg or k.startswith(pkg + ".")}
    try:
        mod = importlib.import_module(name)
        obj = getattr(mod, attr)        # scikit-image 是延迟加载的，必须在恢复替身前取出
    except ImportError:
        pytest.skip(f"未安装 {pkg}")
    finally:
        sys.modules.update(saved)
    assert getattr(mod, "__file__", None), "拿到的是替身而不是真正的库"
    return obj


real_ssim = _real("skimage.metrics", "structural_similarity")
RealDBSCAN = _real("sklearn.cluster", "DBSCAN")


def test_ssim_matches_skimage():
    rng = np.random.default_rng(0)
    for shape in [(40, 52), (612, 792)]:
        a = rng.integers(0, 256, shape, dtype=np.uint8)
        b = np.clip(a.astype(int) + rng.integers(-25, 26, shape), 0, 255).astype(np.uint8)
        c = (a * 0.5 + 60).astype(np.uint8)
        for x, y in [(a, a), (a, b), (a, c)]:
            assert _compat.structural_similarity(x, y) == pytest.approx(real_ssim(x, y), abs=1e-9)


@pytest.mark.parametrize("metric", ["euclidean", "manhattan"])
@pytest.mark.parametrize("min_samples", [1, 3])
def test_dbscan_matches_sklearn(metric, min_samples):
    rng = np.random.default_rng(1)
    for _ in range(20):
        n = int(rng.integers(1, 300))
        dim = int(rng.integers(1, 3))
        X = np.round(rng.uniform(0, 100, (n, dim)), 1)      # 含距离恰好等于 eps 的情况
        eps = float(rng.choice([2.0, 5.0, 10.0]))
        ref = RealDBSCAN(eps=eps, min_samples=min_samples, metric=metric).fit(X).labels_
        got = _compat.DBSCAN(eps=eps, min_samples=min_samples, metric=metric).fit(X).labels_
        assert got.tolist() == ref.tolist()
