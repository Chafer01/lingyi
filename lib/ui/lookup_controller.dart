import 'package:flutter/material.dart';

import '../platform/app_state.dart';
import '../services/dict_service.dart';
import '../services/translate/translate_service.dart';
import '../services/user_db.dart';
import '../util/text_utils.dart';

enum LookupMode {
  /// 空闲：显示最近查询。
  idle,

  /// 正在输入：显示联想词。
  typing,

  /// 命中英文单词。
  word,

  /// 中文短词：英文反查 + 机器翻译。
  zhWord,

  /// 句子/段落，或词典未收录：机器翻译。
  sentence,
}

/// 查词翻译的状态。主窗口与 Windows 迷你窗口共用一份，切换时不丢失结果。
class LookupController extends ChangeNotifier {
  LookupController._() {
    AppState.instance.incoming.addListener(_onIncoming);
    // 控制器创建前就已传入的查询（例如安卓冷启动时的选中文字）。
    _onIncoming();
  }
  static final LookupController instance = LookupController._();

  final input = TextEditingController();
  final focusNode = FocusNode();

  LookupMode mode = LookupMode.idle;
  String query = '';
  LookupResult? word;
  List<WordEntry> suggestions = const [];
  List<WordEntry> reverse = const [];
  List<EngineJob> jobs = const [];
  Map<String, String> glossary = const {};

  /// “AI 讲解”的结果；null 表示尚未请求。
  Future<String>? aiExplain;

  int _handledSerial = 0;
  int _runId = 0;

  final _dict = DictService.instance;
  final _tr = TranslateService.instance;
  final _db = UserDb.instance;

  void _onIncoming() {
    final q = AppState.instance.incoming.value;
    if (q == null || q.serial == _handledSerial) return;
    _handledSerial = q.serial;
    final text = q.text.trim();
    if (text.isEmpty) {
      input.selection = TextSelection(baseOffset: 0, extentOffset: input.text.length);
      focusNode.requestFocus();
      return;
    }
    input.text = text;
    submit(text);
  }

  /// 输入变化：英文单词显示联想，清空时回到空闲。
  void onTyping(String raw) {
    final s = normalizeQuery(raw);
    if (s.isEmpty) {
      mode = LookupMode.idle;
      notifyListeners();
      return;
    }
    if (!raw.contains('\n') && isDictionaryQuery(s) && detectLang(s) == Lang.en && s.length <= 30) {
      suggestions = _dict.suggest(s, limit: 12);
      if (suggestions.isNotEmpty) {
        mode = LookupMode.typing;
        notifyListeners();
      }
    }
  }

  void clear() {
    input.clear();
    mode = LookupMode.idle;
    query = '';
    notifyListeners();
    focusNode.requestFocus();
  }

  /// 执行查询。
  void submit([String? raw]) {
    final text = (raw ?? input.text).trim();
    if (text.isEmpty) return;
    if (raw != null && input.text != raw) input.text = raw;
    final run = ++_runId;
    query = text;
    aiExplain = null;
    word = null;
    reverse = const [];
    jobs = const [];
    glossary = const {};

    final s = normalizeQuery(text);
    if (isDictionaryQuery(text) && detectLang(s) == Lang.en) {
      final r = _dict.lookup(s);
      if (r.found) {
        word = r;
        mode = LookupMode.word;
        final e = r.entry!;
        _db.countLookup(e.word);
        _db.addHistory(e.word, e.brief);
        notifyListeners();
        return;
      }
      // 未收录：机器翻译兜底，同时给出相近词。
      word = r;
    } else if (isDictionaryQuery(text) && detectLang(s) == Lang.zh) {
      reverse = _dict.reverseLookup(s, limit: 12);
    }

    mode = reverse.isNotEmpty ? LookupMode.zhWord : LookupMode.sentence;
    glossary = _tr.glossaryFor(text);
    jobs = _tr.translateAll(text);
    // 第一个成功的结果写入历史。
    var recorded = false;
    for (final j in jobs) {
      j.future?.then((r) {
        if (!recorded && run == _runId && r.text.isNotEmpty) {
          recorded = true;
          _db.addHistory(text, r.text);
        }
      }, onError: (_) {});
    }
    notifyListeners();
  }

  void requestAiExplain() {
    final w = word?.entry;
    if (mode == LookupMode.word && w != null) {
      aiExplain = _tr.llm.explainWord(w.word, w.translation.replaceAll('\n', '；'));
    } else {
      aiExplain = _tr.llm.explainSentence(query);
    }
    notifyListeners();
  }
}
