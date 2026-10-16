import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'engine.dart';

/// 内置的 AI 接口线路。用户在设置里选择启用哪些、按什么顺序尝试。
class AiRoute {
  const AiRoute(this.id, this.provider, this.model, this.label, {this.extraBody = const {}, this.note = ''});
  final String id;

  /// modelscope / zhipu / custom
  final String provider;
  final String model;

  /// 结果卡片上显示的名字。
  final String label;

  /// 附加请求参数（如魔搭 Qwen3.5 关闭思考模式）。
  final Map<String, dynamic> extraBody;
  final String note;
}

const modelscopeBaseUrl = 'https://api-inference.modelscope.cn/v1';
const zhipuBaseUrl = 'https://open.bigmodel.cn/api/paas/v4';

/// 魔搭的 Qwen3.5 默认开启思考，会慢很多且可能把思考过程混进输出。
const _noThinking = {'enable_thinking': false};

const aiRoutes = <AiRoute>[
  AiRoute('ms-397b', 'modelscope', 'Qwen/Qwen3.5-397B-A17B', 'Qwen3.5-397B（魔搭）',
      extraBody: _noThinking, note: '实测术语最准（41/42），约 3 秒'),
  AiRoute('ms-27b', 'modelscope', 'Qwen/Qwen3.5-27B', 'Qwen3.5-27B（魔搭）',
      extraBody: _noThinking, note: '与 397B 额度分开计算，约 2 秒'),
  AiRoute('zhipu-flash', 'zhipu', 'glm-4-flash-250414', 'GLM-4-Flash（智谱）', note: '官方永久免费，约 1 秒'),
  AiRoute('ms-122b', 'modelscope', 'Qwen/Qwen3.5-122B-A10B', 'Qwen3.5-122B（魔搭）',
      extraBody: _noThinking, note: '可选的额外备用'),
  AiRoute('custom', 'custom', '', '自定义接口', note: 'DeepSeek、通义千问、Ollama 等 OpenAI 兼容接口'),
];

/// 默认线路：397B → 27B → 智谱。
const defaultAiChain = ['ms-397b', 'ms-27b', 'zhipu-flash'];

AiRoute? aiRouteById(String id) {
  for (final r in aiRoutes) {
    if (r.id == id) return r;
  }
  return null;
}

/// 一个可调用的接口（线路 + 密钥）。
class AiEndpoint {
  const AiEndpoint({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.extraBody = const {},
  });
  final String id;
  final String label;
  final String baseUrl;
  final String apiKey;
  final String model;
  final Map<String, dynamic> extraBody;

  String get _coolKey => '$baseUrl|$model|${apiKey.hashCode}';

  /// 传给本地后端（PDF 翻译）的格式。
  Map<String, dynamic> toJson() =>
      {'label': label, 'base_url': baseUrl, 'api_key': apiKey, 'model': model, 'extra_body': extraBody};
}

/// AI 接口的回复。
class AiReply {
  AiReply(this.text, this.endpoint, {this.skipped = const []});
  final String text;
  final AiEndpoint endpoint;

  /// 本次失败并被跳过的接口及原因（按尝试顺序）。
  final List<String> skipped;

  /// 是否发生了自动切换。
  bool get switched => skipped.isNotEmpty;
}

/// 单个接口调用失败。
class AiCallError implements Exception {
  AiCallError(this.message, {this.status, this.timeout = false, this.network = false});
  final String message;
  final int? status;
  final bool timeout;
  final bool network;
  @override
  String toString() => message;
}

/// 失败后该接口暂时跳过多久（连续失败次数越多越久）。
/// 返回 Duration.zero 表示无需跳过（例如单次请求内容有问题）。
Duration failCooldown(AiCallError e, int consecutive) {
  final n = math.max(1, consecutive);
  Duration grow(int baseSec, int maxSec) => Duration(seconds: math.min(maxSec, baseSec * (1 << math.min(n - 1, 10))));
  final s = e.status;
  if (s == 401 || s == 403) return const Duration(minutes: 10); // 密钥无效、未实名、未验证邮箱等
  if (s == 429) return grow(30, 600); // 限流或当日额度用完
  if (s == 404) return const Duration(minutes: 10); // 模型下线
  if (e.timeout || e.network || (s != null && s >= 500)) return grow(15, 300);
  return Duration.zero;
}

/// 解析接口返回的错误信息。
String apiErrorMessage(int status, String body) {
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final err = j['error'];
      if (err is Map && err['message'] != null) return '${err['message']}';
      if (err is String) return err;
      if (j['message'] != null) return '${j['message']}';
      if (j['errors'] is Map && j['errors']['message'] != null) return '${j['errors']['message']}';
    }
  } catch (_) {}
  final t = body.trim();
  return t.isEmpty ? 'HTTP $status' : 'HTTP $status ${t.length > 120 ? t.substring(0, 120) : t}';
}

/// 把接口按“未在冷却的优先、保持原顺序”排列。
List<T> orderByCooldown<T>(List<T> items, bool Function(T) cooling) =>
    [...items.where((e) => !cooling(e)), ...items.where(cooling)];

/// 按顺序尝试多个 OpenAI 兼容接口：限流、额度用完、超时、服务端错误时自动换下一个。
class AiRouter {
  AiRouter({http.Client? client}) : _client = client;
  final http.Client? _client;

  static final _coolUntil = <String, DateTime>{};
  static final _fails = <String, int>{};

  bool _cooling(AiEndpoint e) {
    final t = _coolUntil[e._coolKey];
    return t != null && DateTime.now().isBefore(t);
  }

  Future<AiReply> chat(
    List<AiEndpoint> endpoints,
    String system,
    String user, {
    double temperature = 0.3,
    Duration timeout = const Duration(seconds: 20),
  }) =>
      complete(
        endpoints,
        (_) => [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        temperature: temperature,
        timeout: timeout,
      );

  /// 通用版本：[messages] 按接口生成消息（例如图片的传法因平台而异），其余与 [chat] 相同。
  Future<AiReply> complete(
    List<AiEndpoint> endpoints,
    List<Map<String, dynamic>> Function(AiEndpoint ep) messages, {
    double temperature = 0.3,
    Duration timeout = const Duration(seconds: 20),
    int? maxTokens,
  }) async {
    if (endpoints.isEmpty) throw TranslateException('请先在设置中填写魔搭或智谱的密钥');
    final skipped = <String>[];
    for (final ep in orderByCooldown(endpoints, _cooling)) {
      try {
        final text = await _call(ep, messages(ep), temperature, timeout, maxTokens);
        _fails.remove(ep._coolKey);
        _coolUntil.remove(ep._coolKey);
        return AiReply(text, ep, skipped: skipped);
      } on AiCallError catch (e) {
        final n = (_fails[ep._coolKey] ?? 0) + 1;
        _fails[ep._coolKey] = n;
        final cd = failCooldown(e, n);
        if (cd > Duration.zero) _coolUntil[ep._coolKey] = DateTime.now().add(cd);
        skipped.add('${ep.label}：${e.message}');
      }
    }
    throw TranslateException('AI 接口均不可用：\n${skipped.join('\n')}');
  }

  Future<String> _call(
      AiEndpoint ep, List<Map<String, dynamic>> messages, double temperature, Duration timeout, int? maxTokens) async {
    var base = ep.baseUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final body = <String, dynamic>{
      'model': ep.model,
      'temperature': temperature,
      'stream': false,
      'messages': messages,
      if (maxTokens != null) 'max_tokens': maxTokens,
      ...ep.extraBody,
    };
    final http.Response resp;
    try {
      final req = Uri.parse('$base/chat/completions');
      final headers = {
        'Content-Type': 'application/json',
        if (ep.apiKey.isNotEmpty) 'Authorization': 'Bearer ${ep.apiKey}',
      };
      final payload = utf8.encode(jsonEncode(body));
      final c = _client;
      resp = await (c != null ? c.post(req, headers: headers, body: payload) : http.post(req, headers: headers, body: payload))
          .timeout(timeout);
    } on TimeoutException {
      throw AiCallError('超时（${timeout.inSeconds} 秒）', timeout: true);
    } on SocketException catch (e) {
      throw AiCallError('网络错误：${e.message}', network: true);
    } on http.ClientException catch (e) {
      throw AiCallError('网络错误：${e.message}', network: true);
    }
    final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode != 200) {
      var msg = apiErrorMessage(resp.statusCode, text);
      if (resp.statusCode == 429) msg = '限流或额度用完（$msg）';
      throw AiCallError(msg, status: resp.statusCode);
    }
    final Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      throw AiCallError('返回内容无法解析', status: 502);
    }
    // 逐层取 choices[0].message.content；不在三元表达式里用 `?[`，避免 Dart 解析歧义。
    final choices = j is Map ? j['choices'] : null;
    final first = (choices is List && choices.isNotEmpty) ? choices.first : null;
    final message = first is Map ? first['message'] : null;
    final content = message is Map ? message['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      // 部分平台把额度/内容错误放在 200 响应里
      final err = j is Map ? apiErrorMessage(200, text) : '';
      throw AiCallError('没有返回内容${(err.isEmpty || err.startsWith('HTTP')) ? '' : '（$err）'}', status: 502);
    }
    return _stripThink(content).trim();
  }

  /// 去掉个别模型混在正文里的思考过程。
  static String _stripThink(String s) => s.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');

  /// 测试用：清空冷却状态。
  static void resetCooldowns() {
    _coolUntil.clear();
    _fails.clear();
  }
}
