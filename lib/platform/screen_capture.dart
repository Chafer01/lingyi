import 'dart:async';
import 'dart:io';

import 'win_input.dart';

/// 调用 Windows 自带的截图工具（与 Win + Shift + S 相同的框选界面）。
///
/// 截图工具会把截图放进剪贴板，这里通过剪贴板序号判断用户是否完成了截图。
class ScreenCapture {
  ScreenCapture._();

  static bool _busy = false;
  static DateTime _deadline = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> _launch() async {
    try {
      await Process.start('explorer.exe', ['ms-screenclip:'], mode: ProcessStartMode.detached);
    } on ProcessException {
      await Process.start('cmd', ['/c', 'start', '', 'ms-screenclip:'], mode: ProcessStartMode.detached);
    }
  }

  /// 返回 true 表示剪贴板里已经有新截图；超时返回 false。
  ///
  /// 用户按 Esc 取消时截图工具不会通知我们。等待期间再次触发会重新打开截图界面，
  /// 并由第一次调用继续等待结果（这次调用直接返回 false）。
  static Future<bool> snip({Duration timeout = const Duration(seconds: 60)}) async {
    _deadline = DateTime.now().add(timeout);
    if (_busy) {
      await _launch();
      return false;
    }
    _busy = true;
    try {
      final seq = WinInput.clipboardSequence;
      await _launch();
      while (DateTime.now().isBefore(_deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (WinInput.clipboardSequence != seq && WinInput.clipboardHasNonText) {
          // 截图工具可能分几次写入不同格式，稍等再读。
          await Future<void>.delayed(const Duration(milliseconds: 250));
          return true;
        }
      }
      return false;
    } finally {
      _busy = false;
    }
  }
}
