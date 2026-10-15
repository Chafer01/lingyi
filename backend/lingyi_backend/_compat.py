"""兼容补丁：用轻量实现替代 babeldoc 用到的 scikit-image / scikit-learn 函数。

scikit-image 和 scikit-learn 都会连带导入 scipy，而 scipy 在 Windows 打包程序里导入时会卡死。
babeldoc 只用到其中两个函数：

- skimage.metrics.structural_similarity（检测扫描件）：按 scikit-image 默认算法
  （7×7 均匀窗口、样本协方差、K1=0.01、K2=0.03、去掉边缘后取平均）用 numpy + OpenCV 实现；
- sklearn.cluster.DBSCAN（把字符聚成行）：按 scikit-learn 的语义实现（距离 ≤ eps 为邻居，
  标签按样本顺序依次分配，噪声为 -1）。

两者在导入 babeldoc 之前注册到 sys.modules，打包时完全排除 scipy / scikit-image / scikit-learn。
tests/test_compat.py 会与真正的库逐一比对结果。
"""
from __future__ import annotations

import sys
import types

import numpy as np


def _dtype_range(img: np.ndarray) -> float:
    if img.dtype == np.uint8:
        return 255.0
    if img.dtype == np.uint16:
        return 65535.0
    if img.dtype == bool:
        return 1.0
    if np.issubdtype(img.dtype, np.floating):
        return 2.0          # 与 scikit-image 对浮点数的约定一致（-1..1）
    info = np.iinfo(img.dtype)
    return float(info.max - info.min)


def structural_similarity(im1, im2, *, win_size=None, data_range=None, channel_axis=None,
                          gaussian_weights=False, full=False, **kwargs):
    import cv2

    a = np.asarray(im1)
    b = np.asarray(im2)
    if a.shape != b.shape:
        raise ValueError("输入图像尺寸必须相同")
    if channel_axis is not None:
        a = np.moveaxis(a, channel_axis, -1)
        b = np.moveaxis(b, channel_axis, -1)
        vals = [structural_similarity(a[..., c], b[..., c], win_size=win_size, data_range=data_range)
                for c in range(a.shape[-1])]
        return float(np.mean(vals))
    if gaussian_weights or full:
        raise NotImplementedError("精简版 SSIM 只支持默认参数")
    win = int(win_size or 7)
    if min(a.shape) < win:
        raise ValueError("图像小于窗口尺寸")
    R = float(data_range) if data_range is not None else _dtype_range(a)
    K1, K2 = kwargs.get("K1", 0.01), kwargs.get("K2", 0.03)
    use_sample_cov = kwargs.get("use_sample_covariance", True)

    x = a.astype(np.float64)
    y = b.astype(np.float64)
    blur = lambda m: cv2.blur(m, (win, win), borderType=cv2.BORDER_REFLECT)  # noqa: E731
    npix = win * win
    cov_norm = npix / (npix - 1) if use_sample_cov else 1.0
    ux, uy = blur(x), blur(y)
    uxx, uyy, uxy = blur(x * x), blur(y * y), blur(x * y)
    vx = cov_norm * (uxx - ux * ux)
    vy = cov_norm * (uyy - uy * uy)
    vxy = cov_norm * (uxy - ux * uy)
    C1, C2 = (K1 * R) ** 2, (K2 * R) ** 2
    S = ((2 * ux * uy + C1) * (2 * vxy + C2)) / ((ux * ux + uy * uy + C1) * (vx + vy + C2))
    pad = (win - 1) // 2
    return float(S[pad:-pad, pad:-pad].mean())


class DBSCAN:
    """scikit-learn DBSCAN 的精简实现（支持 euclidean / manhattan 距离）。"""

    def __init__(self, eps=0.5, *, min_samples=5, metric="euclidean", **kwargs):
        if metric not in ("euclidean", "manhattan", "l1", "l2", "cityblock"):
            raise NotImplementedError(f"不支持的距离：{metric}")
        self.eps = float(eps)
        self.min_samples = int(min_samples)
        self.metric = metric
        self.labels_ = None

    def _neighbors(self, X):
        n = len(X)
        out = []
        chunk = max(1, 4_000_000 // max(n, 1))
        for start in range(0, n, chunk):
            diff = X[start:start + chunk, None, :] - X[None, :, :]
            if self.metric in ("manhattan", "l1", "cityblock"):
                d = np.abs(diff).sum(-1)
            else:
                d = np.sqrt((diff * diff).sum(-1))
            out.extend(np.flatnonzero(row <= self.eps) for row in d)
        return out

    def fit(self, X, y=None, sample_weight=None):
        X = np.asarray(X, dtype=np.float64)
        if X.ndim == 1:
            X = X[:, None]
        n = len(X)
        neigh = self._neighbors(X) if n else []
        core = np.array([len(nb) >= self.min_samples for nb in neigh], dtype=bool)
        labels = np.full(n, -1, dtype=np.intp)
        label = 0
        for i in range(n):                      # 与 scikit-learn 相同：按样本顺序从核心点扩展
            if labels[i] != -1 or not core[i]:
                continue
            labels[i] = label
            stack = [i]
            while stack:
                j = stack.pop()
                if not core[j]:
                    continue
                for k in neigh[j]:
                    if labels[k] == -1:
                        labels[k] = label
                        if core[k]:
                            stack.append(k)
            label += 1
        self.labels_ = labels
        self.core_sample_indices_ = np.flatnonzero(core)
        return self

    def fit_predict(self, X, y=None, sample_weight=None):
        return self.fit(X).labels_


def _register(pkg: str, sub: str, **attrs):
    full = f"{pkg}.{sub}"
    if full in sys.modules:       # 真正的库已经导入，不覆盖
        return
    parent = sys.modules.get(pkg)
    if parent is None:
        parent = types.ModuleType(pkg)
        parent.__path__ = []      # 标记为包，使 from pkg.sub import x 可用
        sys.modules[pkg] = parent
    mod = types.ModuleType(full)
    for k, v in attrs.items():
        setattr(mod, k, v)
    setattr(parent, sub, mod)
    sys.modules[full] = mod


def install():
    """在导入 babeldoc 之前调用。"""
    _register("skimage", "metrics", structural_similarity=structural_similarity)
    _register("sklearn", "cluster", DBSCAN=DBSCAN)
