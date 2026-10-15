"""启动入口。

    python -m lingyi_backend --port 0 --token XXX --watch-stdin

启动成功后向标准输出打印一行  LINGYI_BACKEND_READY <端口>，灵译据此连接。
--watch-stdin：标准输入被关闭（灵译退出）时自动退出，避免残留进程。
"""
from __future__ import annotations

import argparse
import logging
import os
import socket
import sys
import threading
from pathlib import Path


def _log_dir() -> Path:
    base = os.environ.get("LOCALAPPDATA") or str(Path.home() / ".cache")
    d = Path(base) / "lingyi"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _watch_stdin():
    """灵译通过管道启动后端；管道关闭（灵译退出或崩溃）时后端随之退出。"""
    stream = getattr(sys.stdin, "buffer", None)
    if stream is None:          # 没有可用的标准输入（例如手动双击运行），不做监视
        return
    try:
        while stream.read(1024):
            pass
    except Exception:  # noqa: BLE001
        return                  # 读取出错不代表父进程退出，保守起见继续运行
    os._exit(0)


def _redirect_output():
    """报告就绪后，把标准输出 / 错误（包括 C 扩展直接写 fd 的内容）全部转到日志文件。

    灵译只读第一行；如果之后还往管道里写而没人读，Windows 上管道缓冲很小，写满后整个后端会卡住。
    """
    log = open(_log_dir() / "backend.out.log", "a", encoding="utf-8", buffering=1)  # noqa: SIM115
    for fd in (1, 2):
        try:
            os.dup2(log.fileno(), fd)
        except OSError:
            pass
    sys.stdout = sys.stderr = log


def main(argv=None):
    ap = argparse.ArgumentParser(prog="lingyi_backend")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0, help="0 = 自动选择空闲端口")
    ap.add_argument("--token", default=os.environ.get("LINGYI_TOKEN", ""))
    ap.add_argument("--watch-stdin", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=[logging.FileHandler(_log_dir() / "backend.log", encoding="utf-8")],
    )

    import uvicorn

    from .server import create_app

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.host, args.port))
    port = sock.getsockname()[1]
    # 先开始监听再报告就绪：之后到达的连接会在队列里等 uvicorn 接手，不会被拒绝。
    sock.listen(128)

    app = create_app(args.token)
    config = uvicorn.Config(app, log_level="warning", log_config=None, access_log=False)
    server = uvicorn.Server(config)

    if args.watch_stdin:
        threading.Thread(target=_watch_stdin, daemon=True).start()

    # 打包成窗口程序后标准输出可能不可用，同时写一份端口文件供灵译读取。
    (_log_dir() / "backend.port").write_text(f"{port} {os.getpid()}", encoding="utf-8")
    line = f"LINGYI_BACKEND_READY {port}\n"
    try:
        if sys.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
    except Exception:  # noqa: BLE001
        pass
    _redirect_output()
    logging.getLogger("lingyi").info("listening on %s:%s", args.host, port)
    # 就绪行已发出，此时到达的请求在监听队列中等待；先在主线程导入重型模块，再开始处理请求。
    from .server import preload
    errs = preload()
    if errs:
        logging.getLogger("lingyi").error("preload errors: %s", errs)
    server.run(sockets=[sock])


if __name__ == "__main__":
    main()
