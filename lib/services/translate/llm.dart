import '../../util/text_utils.dart';
import '../settings.dart';
import 'ai_router.dart';
import 'engine.dart';

/// AI 翻译：按设置中的线路顺序（默认 魔搭 Qwen3.5-397B → 魔搭 Qwen3.5-27B → 智谱 GLM-4-Flash）
/// 调用 OpenAI 兼容接口，限流、额度用完、超时或服务端出错时自动换下一个。
/// 用于“技术翻译”（强制使用术语表）、“AI 讲解”和 PDF 翻译。
class LlmEngine extends TranslateEngine {
  LlmEngine({AiRouter? router}) : _router = router ?? AiRouter();
  final _s = Settings.instance;
  final AiRouter _router;

  @override
  String get id => 'llm';
  @override
  String get name => 'AI 翻译';
  @override
  bool get configured => endpoints.isNotEmpty;

  static bool _isLocal(String url) => url.contains('localhost') || url.contains('127.0.0.1');

  @override
  String get setupHint => '在设置中填写魔搭（ModelScope）或智谱的密钥';

  /// 当前可用的接口，按尝试顺序（没填密钥的线路跳过）。
  List<AiEndpoint> get endpoints => buildEndpoints(
        chain: _s.aiChain,
        modelscopeKey: _s.modelscopeKey,
        zhipuKey: _s.zhipuKey,
        customBaseUrl: _s.llmBaseUrl,
        customKey: _s.llmKey,
        customModel: _s.llmModel,
      );

  /// 用于界面显示的线路说明，如“Qwen3.5-397B（魔搭）→ GLM-4-Flash（智谱）”。
  String get chainLabel => endpoints.map((e) => e.label).join(' → ');

  static List<AiEndpoint> buildEndpoints({
    required List<String> chain,
    required String modelscopeKey,
    required String zhipuKey,
    String customBaseUrl = '',
    String customKey = '',
    String customModel = '',
  }) {
    final out = <AiEndpoint>[];
    for (final id in chain) {
      final r = aiRouteById(id);
      if (r == null) continue;
      if (r.provider == 'modelscope') {
        if (modelscopeKey.isNotEmpty) {
          out.add(AiEndpoint(
              id: r.id, label: r.label, baseUrl: modelscopeBaseUrl, apiKey: modelscopeKey,
              model: r.model, extraBody: r.extraBody));
        }
      } else if (r.provider == 'zhipu') {
        if (zhipuKey.isNotEmpty) {
          out.add(AiEndpoint(
              id: r.id, label: r.label, baseUrl: zhipuBaseUrl, apiKey: zhipuKey, model: r.model,
              extraBody: r.extraBody));
        }
      } else if (r.provider == 'custom') {
        final ok = customBaseUrl.isNotEmpty && customModel.isNotEmpty && (customKey.isNotEmpty || _isLocal(customBaseUrl));
        if (ok) {
          out.add(AiEndpoint(id: r.id, label: customModel, baseUrl: customBaseUrl, apiKey: customKey, model: customModel));
        }
      }
    }
    return out;
  }

  @override
  Future<TranslateResult> translate(TranslateRequest req) async {
    final target = req.to == Lang.zh ? '简体中文' : 'English';
    final terms = req.glossary.entries.map((e) => '- ${e.key} → ${e.value}').join('\n');
    final system = StringBuffer()
      ..writeln('你是专业的科技翻译，熟悉射频、天线、电磁仿真和通信工程。')
      ..writeln('把用户给出的文本翻译成$target。要求：准确、通顺、符合技术文档习惯；')
      ..writeln('保留公式、变量名、单位、代码和专有名词的原样；不要解释，不要加括号注释，不要加引号，只输出译文。');
    if (terms.isNotEmpty) {
      system
        ..writeln('必须使用以下术语译法：')
        ..writeln(terms);
    }
    // 超时随长度放宽：短句 20 秒，长段落最多 90 秒。
    final secs = (20 + req.text.length ~/ 25).clamp(20, 90);
    final r = await _router.chat(endpoints, system.toString(), req.text,
        temperature: 0.2, timeout: Duration(seconds: secs));
    return TranslateResult(r.text, via: r.endpoint.label, skipped: r.skipped);
  }

  /// 查词时的“AI 讲解”：解释词义区别、常见搭配和例句。
  Future<AiReply> explainWord(String word, String dictTranslation) {
    const system = '你是一名耐心的英语老师，同时熟悉射频与通信工程。用简体中文回答，使用简洁的 Markdown。';
    final user = '请讲解英文单词「$word」。词典释义：$dictTranslation\n'
        '请包括：1) 核心含义与各义项的区别；2) 常见搭配；3) 两到三个例句（附中文）；'
        '4) 如果它在射频/通信/工程领域有专门含义，单独说明。';
    return _router.chat(endpoints, system, user, temperature: 0.5, timeout: const Duration(seconds: 60));
  }

  /// 讲解一句话：语法结构 + 难点词汇。
  Future<AiReply> explainSentence(String text) {
    const system = '你是一名英语老师，同时熟悉射频与通信工程。用简体中文回答，使用简洁的 Markdown。';
    final user = '请解析下面这段文字：先给出准确译文，再拆解句子结构，最后列出难点词汇和术语。\n\n$text';
    return _router.chat(endpoints, system, user, temperature: 0.4, timeout: const Duration(seconds: 60));
  }
}
