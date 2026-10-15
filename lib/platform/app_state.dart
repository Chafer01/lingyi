import 'package:flutter/foundation.dart';

/// 外部传入的查询（全局热键划词、剪贴板、安卓“选中文字 → 灵译”、分享）。
class IncomingQuery {
  IncomingQuery(this.text, this.serial);
  final String text;

  /// 递增序号，保证同样的文字再次传入时也会触发刷新。
  final int serial;
}

class AppState {
  AppState._();
  static final AppState instance = AppState._();

  int _serial = 0;

  /// 最新的外部查询。查词页监听它并自动执行查询。
  final ValueNotifier<IncomingQuery?> incoming = ValueNotifier(null);

  /// Windows 迷你窗口模式（划词弹窗）。
  final ValueNotifier<bool> mini = ValueNotifier(false);

  /// 迷你窗口是否钉住（失去焦点时不自动隐藏）。
  final ValueNotifier<bool> pinned = ValueNotifier(false);

  /// 底部导航当前页。
  final ValueNotifier<int> tab = ValueNotifier(0);

  void push(String text) {
    tab.value = 0;
    incoming.value = IncomingQuery(text, ++_serial);
  }
}
