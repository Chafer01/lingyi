import 'package:flutter/foundation.dart';

import '../services/backend.dart';
import '../services/translate/ai_router.dart';

/// 外部传入的查询（全局热键划词、自动划词、剪贴板、安卓“选中文字 → 灵译”、分享）。
class IncomingQuery {
  IncomingQuery(this.text, this.serial);
  final String text;

  /// 递增序号，保证同样的文字再次传入时也会触发刷新。
  final int serial;
}

/// 截图热键等外部触发的识别结果（或错误），由“识别”页显示。
class OcrIncoming {
  OcrIncoming({this.result, this.reply, this.error, this.note});

  /// 本地识别结果（智能识别时只用它带回原图）。
  final OcrResult? result;

  /// 智能识别（视觉大模型）结果。
  final AiReply? reply;
  final String? error;

  /// 补充说明，例如“智能识别不可用，已改用本地识别”。
  final String? note;
}

/// 主窗口的页面。
enum AppPage { lookup, ocr, pdf, wordbook, history, settings }

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

  /// 最近一次自动划词的结果（设置页显示，便于排查“为什么没弹出”）。
  final ValueNotifier<String> autoSelectLog = ValueNotifier('');

  /// 当前窗口形态。
  final ValueNotifier<WinView> view = ValueNotifier(WinView.main);

  /// 迷你窗口是否钉住（失去焦点时不自动隐藏）。
  final ValueNotifier<bool> pinned = ValueNotifier(false);

  /// 最近一次外部触发的截图识别。
  final ValueNotifier<OcrIncoming?> ocrIncoming = ValueNotifier(null);

  /// 主窗口当前页。
  final ValueNotifier<AppPage> page = ValueNotifier(AppPage.lookup);

  void push(String text) {
    page.value = AppPage.lookup;
    incoming.value = IncomingQuery(text, ++_serial);
  }
}
