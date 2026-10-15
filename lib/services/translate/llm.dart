import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../util/text_utils.dart';
import '../settings.dart';
import 'engine.dart';

/// OpenAI 兼容的大模型接口（DeepSeek、通义千问、Kimi、OpenAI、本地 Ollama 等）。
/// 用于“技术翻译”（强制使用术语表）和“AI 讲解”。
class LlmEngine extends TranslateEngine {
  final _s = Settings.instance;

  @override
  String get id => 'llm';
  @override
  String get name => 'AI 翻译';
  @override
  bool get configured =>
      _s.llmBaseUrl.isNotEmpty &&
      _s.llmModel.isNotEmpty &&
      (_s.llmKey.isNotEmpty || _isLocal(_s.llmBaseUrl));

  static bool _isLocal(String url) => url.contains('localhost') || url.contains('127.0.0.1');

  @override
  String get setupHint => '在设置中填写大模型接口地址、密钥和模型名';

  @override
  Future<TranslateResult> translate(TranslateRequest req) async {
    final target = req.to == Lang.zh ? '简体中文' : 'English';
    final terms = req.glossary.entries.map((e) => '- ${e.key} → ${e.value}').join('\n');
    final system = StringBuffer()
      ..writeln('你是专业的科技翻译，熟悉射频、天线、电磁仿真和通信工程。')
      ..writeln('把用户给出的文本翻译成$target。要求：准确、通顺、符合技术文档习惯；')
      ..writeln('保留公式、变量名、单位、代码和专有名词的原样；不要解释，不要加引号，只输出译文。');
    if (terms.isNotEmpty) {
      system
        ..writeln('必须使用以下术语译法：')
        ..writeln(terms);
    }
    final out = await chat(system.toString(), req.text, temperature: 0.2);
    return TranslateResult(out.trim());
  }

  /// 查词时的“AI 讲解”：解释词义区别、常见搭配和例句。
  Future<String> explainWord(String word, String dictTranslation) {
    const system = '你是一名耐心的英语老师，同时熟悉射频与通信工程。用简体中文回答，使用简洁的 Markdown。';
    final user = '请讲解英文单词「$word」。词典释义：$dictTranslation\n'
        '请包括：1) 核心含义与各义项的区别；2) 常见搭配；3) 两到三个例句（附中文）；'
        '4) 如果它在射频/通信/工程领域有专门含义，单独说明。';
    return chat(system, user, temperature: 0.5);
  }

  /// 讲解一句话：语法结构 + 难点词汇。
  Future<String> explainSentence(String text) {
    const system = '你是一名英语老师，同时熟悉射频与通信工程。用简体中文回答，使用简洁的 Markdown。';
    final user = '请解析下面这段文字：先给出准确译文，再拆解句子结构，最后列出难点词汇和术语。\n\n$text';
    return chat(system, user, temperature: 0.4);
  }

  Future<String> chat(String system, String user, {double temperature = 0.3}) async {
    var base = _s.llmBaseUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final resp = await http
        .post(
          Uri.parse('$base/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            if (_s.llmKey.isNotEmpty) 'Authorization': 'Bearer ${_s.llmKey}',
          },
          body: utf8.encode(jsonEncode({
            'model': _s.llmModel,
            'temperature': temperature,
            'messages': [
              {'role': 'system', 'content': system},
              {'role': 'user', 'content': user},
            ],
          })),
        )
        .timeout(const Duration(seconds: 60));
    final text = utf8.decode(resp.bodyBytes);
    if (resp.statusCode == 429) {
      throw TranslateException('AI 接口：请求过于频繁（免费模型通常只允许 1 个并发，请稍后再试）');
    }
    if (resp.statusCode != 200) {
      var msg = 'HTTP ${resp.statusCode}';
      try {
        final err = (jsonDecode(text) as Map<String, dynamic>)['error'];
        if (err is Map && err['message'] != null) msg = '${err['message']}';
      } catch (_) {}
      throw TranslateException('AI 接口：$msg');
    }
    final body = jsonDecode(text) as Map<String, dynamic>;
    final choices = body['choices'] as List?;
    if (choices == null || choices.isEmpty) throw TranslateException('AI 接口没有返回内容');
    final content = (choices.first as Map)['message']?['content'];
    return content is String ? content : '';
  }
}
