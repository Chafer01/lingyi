import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../util/text_utils.dart';
import '../settings.dart';
import 'engine.dart';

/// DeepL API。免费版密钥以 ":fx" 结尾，每月 50 万字符。
class DeepLEngine extends TranslateEngine {
  final _s = Settings.instance;

  @override
  String get id => 'deepl';
  @override
  String get name => 'DeepL';
  @override
  bool get configured => _s.deeplKey.isNotEmpty;
  @override
  String get setupHint => '在设置中填写 DeepL API 密钥';

  @override
  Future<TranslateResult> translate(TranslateRequest req) async {
    final key = _s.deeplKey;
    final host = key.endsWith(':fx') ? 'api-free.deepl.com' : 'api.deepl.com';
    final resp = await http
        .post(
          Uri.https(host, '/v2/translate'),
          headers: {
            'Authorization': 'DeepL-Auth-Key $key',
            'Content-Type': 'application/json',
          },
          body: utf8.encode(jsonEncode({
            'text': [req.text],
            'target_lang': req.to == Lang.zh ? 'ZH-HANS' : 'EN-US',
          })),
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode == 403) throw TranslateException('DeepL：密钥无效（403）');
    if (resp.statusCode == 456) throw TranslateException('DeepL：本月免费额度已用完（456）');
    if (resp.statusCode != 200) {
      throw TranslateException('DeepL：请求失败（HTTP ${resp.statusCode}）');
    }
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final list = (body['translations'] as List).cast<Map<String, dynamic>>();
    if (list.isEmpty) throw TranslateException('DeepL：没有返回结果');
    return TranslateResult(list.first['text'] as String,
        detected: list.first['detected_source_language'] as String?);
  }
}
