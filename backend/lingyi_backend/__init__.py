"""灵译本地后端：截图 OCR、公式识别、PDF 双语翻译。"""

from . import _compat

# 必须在导入 babeldoc 之前注册精简版 skimage.metrics（原因见 _compat.py）
_compat.install()

__version__ = "0.1.0"
