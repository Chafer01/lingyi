import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../util/text_utils.dart';
import '../settings.dart';
import 'engine.dart';

/// 火山引擎机器翻译，每月 200 万字符免费。
/// 签名算法与火山官方 SDK（volc-sdk-python 的 SignerV4）一致。
class VolcEngine extends TranslateEngine {
  static const _host = 'translate.volcengineapi.com';
  static const _region = 'cn-north-1';
  static const _service = 'translate';
  static const _query = {'Action': 'TranslateText', 'Version': '2020-06-01'};

  final _s = Settings.instance;

  @override
  String get id => 'volc';
  @override
  String get name => '火山翻译';
  @override
  bool get configured => _s.volcAk.isNotEmpty && _s.volcSk.isNotEmpty;
  @override
  String get setupHint => '在设置中填写火山引擎 Access Key ID 和 Secret Access Key';

  @override
  Future<TranslateResult> translate(TranslateRequest req) async {
    final body = jsonEncode({
      'TargetLanguage': req.to == Lang.zh ? 'zh' : 'en',
      'TextList': [req.text],
    });
    final headers = signedHeaders(
      accessKey: _s.volcAk,
      secretKey: _s.volcSk,
      body: body,
      now: DateTime.now().toUtc(),
    );
    final resp = await http
        .post(Uri.https(_host, '/', _query), headers: headers, body: utf8.encode(body))
        .timeout(const Duration(seconds: 15));
    final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final err = (json['ResponseMetadata'] as Map<String, dynamic>?)?['Error'] as Map<String, dynamic>?;
    if (err != null) throw TranslateException('火山翻译：${err['Message']}（${err['Code']}）');
    final list = (json['TranslationList'] as List?)?.cast<Map<String, dynamic>>();
    if (list == null || list.isEmpty) {
      throw TranslateException('火山翻译返回异常（HTTP ${resp.statusCode}）');
    }
    return TranslateResult(list.first['Translation'] as String? ?? '',
        detected: list.first['DetectedSourceLanguage'] as String?);
  }

  /// 火山引擎 HMAC-SHA256 签名（V4）。
  static Map<String, String> signedHeaders({
    required String accessKey,
    required String secretKey,
    required String body,
    required DateTime now,
  }) {
    String two(int n) => n.toString().padLeft(2, '0');
    final shortDate = '${now.year}${two(now.month)}${two(now.day)}';
    final xDate = '${shortDate}T${two(now.hour)}${two(now.minute)}${two(now.second)}Z';
    final bodyHash = sha256.convert(utf8.encode(body)).toString();
    const contentType = 'application/json';

    // 参与签名的请求头（按名称排序）。
    final signed = <String, String>{
      'content-type': contentType,
      'host': _host,
      'x-content-sha256': bodyHash,
      'x-date': xDate,
    };
    final signedNames = signed.keys.join(';');
    final canonicalHeaders = signed.entries.map((e) => '${e.key}:${e.value}\n').join();
    final keys = _query.keys.toList()..sort();
    final canonicalQuery = keys
        .map((k) => '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(_query[k]!)}')
        .join('&');
    final canonicalRequest =
        ['POST', '/', canonicalQuery, canonicalHeaders, signedNames, bodyHash].join('\n');

    final scope = '$shortDate/$_region/$_service/request';
    final stringToSign = [
      'HMAC-SHA256',
      xDate,
      scope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');

    List<int> hmac(List<int> key, String msg) => Hmac(sha256, key).convert(utf8.encode(msg)).bytes;
    final kDate = hmac(utf8.encode(secretKey), shortDate);
    final kRegion = hmac(kDate, _region);
    final kService = hmac(kRegion, _service);
    final kSigning = hmac(kService, 'request');
    final signature = Hmac(sha256, kSigning).convert(utf8.encode(stringToSign)).toString();

    return {
      'Content-Type': contentType,
      'X-Date': xDate,
      'X-Content-Sha256': bodyHash,
      'Authorization': 'HMAC-SHA256 Credential=$accessKey/$scope, SignedHeaders=$signedNames, Signature=$signature',
    };
  }
}
