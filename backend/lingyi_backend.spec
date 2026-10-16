# PyInstaller 打包配置：pyinstaller lingyi_backend.spec --noconfirm
# 输出 dist/lingyi_backend/（lingyi_backend.exe + _internal），CI 会把它放到灵译的 backend\ 目录。
from PyInstaller.utils.hooks import collect_all, collect_submodules

datas, binaries, hiddenimports = [], [], []
for pkg in ("rapidocr_onnxruntime", "rapid_latex_ocr", "babeldoc", "latex2mathml", "wordninja",
            "tiktoken", "tiktoken_ext", "bitstring", "pymupdf"):
    d, b, h = collect_all(pkg)
    datas += d
    binaries += b
    hiddenimports += h
hiddenimports += collect_submodules("uvicorn") + ["tiktoken_ext.openai_public"]

# wordninja 是单文件模块，词频表放在同名文件夹里，collect_all 收不到
import os
import wordninja
datas.append((os.path.join(os.path.dirname(wordninja.__file__), "wordninja", "wordninja_words.txt.gz"),
              "wordninja"))

# PDF 翻译的离线资源（版面模型、字体、字符映射表、tiktoken 词表），由 CI 预先收集：
#   python -m lingyi_backend.pdf_assets collect babeldoc_assets
if os.path.isdir("babeldoc_assets"):
    datas.append(("babeldoc_assets", "babeldoc_assets"))

a = Analysis(
    ["run_backend.py"],
    pathex=["."],
    datas=datas,
    binaries=binaries,
    hiddenimports=hiddenimports,
    # scipy / scikit-image 在 Windows 打包程序里导入会卡死，且只被 babeldoc 的扫描件检测用到，
    # 已由 lingyi_backend/_compat.py 的精简实现替代
    excludes=["tkinter", "matplotlib", "IPython", "pytest", "scipy", "skimage", "sklearn"],
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="lingyi_backend",
          console=False, upx=False, icon=None)
coll = COLLECT(exe, a.binaries, a.datas, name="lingyi_backend", upx=False)
