import '../../util/text_utils.dart';
import '../settings.dart';
import 'deepl.dart';
import 'engine.dart';
import 'llm.dart';
import 'tencent.dart';

/// 一个引擎的一次翻译任务。
class EngineJob {
  EngineJob(this.engine, this.future);
  final TranslateEngine engine;
  final Future<TranslateResult>? future; // 未配置时为 null
}

class TranslateService {
  TranslateService._();
  static final TranslateService instance = TranslateService._();

  final tencent = TencentEngine();
  final deepl = DeepLEngine();
  final llm = LlmEngine();

  List<TranslateEngine> get all => [tencent, deepl, llm];

  TranslateEngine? byId(String id) {
    for (final e in all) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 已启用的引擎（按设置中的顺序）。
  List<TranslateEngine> get enabled =>
      Settings.instance.enabledEngines.map(byId).whereType<TranslateEngine>().toList();

  /// 是否至少有一个已启用且配置好的引擎。
  bool get anyReady => enabled.any((e) => e.configured);

  /// 原文中命中的术语。
  Map<String, String> glossaryFor(String text) =>
      glossaryHits(text, parseGlossary(Settings.instance.glossary));

  /// 同时调用所有已启用的引擎。
  List<EngineJob> translateAll(String text) {
    final req = TranslateRequest(text, glossary: glossaryFor(text));
    return [
      for (final e in enabled) EngineJob(e, e.configured ? e.translate(req) : null),
    ];
  }
}
