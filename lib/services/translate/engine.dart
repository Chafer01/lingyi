import '../../util/text_utils.dart';

/// 翻译请求。
class TranslateRequest {
  TranslateRequest(this.text, {Lang? from, Lang? to, this.glossary = const {}})
      : from = from ?? detectLang(text),
        to = to ?? (detectLang(text) == Lang.zh ? Lang.en : Lang.zh);

  final String text;
  final Lang from;
  final Lang to;

  /// 本次原文命中的术语（原文术语 -> 目标译法）。
  final Map<String, String> glossary;
}

/// 翻译结果。
class TranslateResult {
  TranslateResult(this.text, {this.detected});
  final String text;
  final String? detected;
}

/// 引擎调用失败时抛出，message 直接展示给用户。
class TranslateException implements Exception {
  TranslateException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class TranslateEngine {
  /// 唯一 id，用于设置中保存。
  String get id;

  /// 显示名称。
  String get name;

  /// 是否已配置好（例如填写了密钥）。
  bool get configured;

  /// 未配置时的提示。
  String get setupHint;

  Future<TranslateResult> translate(TranslateRequest req);
}
