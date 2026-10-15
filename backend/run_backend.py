"""PyInstaller 打包入口（__main__.py 里是相对导入，不能直接作为脚本打包）。"""
import multiprocessing

from lingyi_backend.__main__ import main

if __name__ == "__main__":
    # Windows 打包程序必须调用：依赖库（babeldoc 等）使用 multiprocessing 时，
    # 子进程会重新运行本程序，freeze_support 让它只执行子任务而不是再启动一个后端。
    multiprocessing.freeze_support()
    main()
