"""PyInstaller 打包入口（__main__.py 里是相对导入，不能直接作为脚本打包）。"""
from lingyi_backend.__main__ import main

if __name__ == "__main__":
    main()
