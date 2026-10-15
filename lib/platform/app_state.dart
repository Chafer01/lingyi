import 'package:flutter/foundation.dart';

/// 外部传入的查询（全局热键划词、自动划词、剪贴板、安卓“选中文字 → 灵译”、分享）。
class IncomingQuery {
  IncomingQuery(this.text, this.serial);
  final String text;

  /// 递增序号，保证同样的文字再次传入时也会触发刷新。
  final int serial;
}

/// Windows 窗口的三种形态。安卓上始终是 [main]。
enum WinView {
  /// 普通主窗口。
  main,

  /// 划词翻译的迷你弹窗（置顶、无标题栏）。
  mini,

  /// 选中文字后鼠标旁的小“译”图标。
  icon,
}

class AppState {
  AppState._();
  static final AppState instance = AppState._();

  int _serial = 0;

  /// 最新的外部查询。查词页监听它并自动执行查询。
  final ValueNotifier<IncomingQuery?> incoming = ValueNotifier(null);

  /// 当前窗口形态。
  final ValueNotifier<WinView> view = ValueNotifier(WinView.main);

  /// 迷你窗口是否钉住（失去焦点时不自动隐藏）。
  final ValueNotifier<bool> pinned = ValueNotifier(false);

  /// 主窗口当前页。
  final ValueNotifier<int> tab = ValueNotifier(0);

  void push(String text) {
    tab.value = 0;
    incoming.value = IncomingQuery(text, ++_serial);
  }
}
