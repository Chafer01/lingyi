import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../util/text_utils.dart';
import '../settings.dart';
import 'engine.dart';

/// 腾讯云机器翻译（TMT）文本翻译，每月 500 万字符免费额度。
/// 文档：https://cloud.tencent.com/document/api/551/15619
class TencentEngine extends TranslateEngine {
  static const _host = 'tmt.tencentcloudapi.com';
  static const _service = 'tmt';
  static const _action = 'TextTranslate';
  static const _version = '2018-03-21';

  final _s = Settings.instance;

  @override
  String get id => 'tencent';
  @override
  String get name => '腾讯翻译';
  @override
  bool get configured => _s.tencentId.isNotEmpty && _s.tencentKey.isNotEmpty;
  @override
  String get setupHint => '在设置中填写腾讯云 SecretId 和 SecretKey';

  @override
  Future<TranslateResult> translate(TranslateRequest req) async {
    final payload = jsonEncode({
      'SourceText': req.text,
      'Source': 'auto',
      'Target': req.to == Lang.zh ? 'zh' : 'en',
      'ProjectId': 0,
    });
    final headers = signedHeaders(
      secretId: _s.tencentId,
      secretKey: _s.tencentKey,
      region: _s.tencentRegion,
      payload: payload,
      now: DateTime.now().toUtc(),
    );
    final resp = await http
        .post(Uri.https(_host, '/'), headers: headers, body: utf8.encode(payload))
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final r = body['Response'] as Map<String, dynamic>?;
    if (r == null) throw TranslateException('腾讯翻译返回异常（HTTP ${resp.statusCode}）');
    final err = r['Error'] as Map<String, dynamic>?;
    if (err != null) throw TranslateException('腾讯翻译：${err['Message']}（${err['Code']}）');
    return TranslateResult(r['TargetText'] as String? ?? '', detected: r['Source'] as String?);
  }

  /// 腾讯云 API 3.0 的 TC3-HMAC-SHA256 签名。
  static Map<String, String> signedHeaders({
    required String secretId,
    required String secretKey,
    required String region,
    required String payload,
    required DateTime now,
  }) {
    const contentType = 'application/json; charset=utf-8';
    final timestamp = now.millisecondsSinceEpoch ~/ 1000;
    final date = now.toIso8601String().substring(0, 10); // yyyy-MM-dd（UTC）

    String hexSha256(String s) => sha256.convert(utf8.encode(s)).toString();
    List<int> hmac256(List<int> key, String msg) => Hmac(sha256, key).convert(utf8.encode(msg)).bytes;

    const signedHeaderNames = 'content-type;host;x-tc-action';
    final canonicalRequest = [
      'POST',
      '/',
      '',
      'content-type:$contentType\nhost:$_host\nx-tc-action:${_action.toLowerCase()}\n',
      signedHeaderNames,
      hexSha256(payload),
    ].join('\n');

    final scope = '$date/$_service/tc3_request';
    final stringToSign = ['TC3-HMAC-SHA256', '$timestamp', scope, hexSha256(canonicalRequest)].join('\n');

    final secretDate = hmac256(utf8.encode('TC3$secretKey'), date);
    final secretService = hmac256(secretDate, _service);
    final secretSigning = hmac256(secretService, 'tc3_request');
    final signature = Hmac(sha256, secretSigning).convert(utf8.encode(stringToSign)).toString();

    return {
      'Authorization':
          'TC3-HMAC-SHA256 Credential=$secretId/$scope, SignedHeaders=$signedHeaderNames, Signature=$signature',
      'Content-Type': contentType,
      // Host 头由 HTTP 客户端根据 URL 自动填写，与签名中的 host 一致。
      'X-TC-Action': _action,
      'X-TC-Timestamp': '$timestamp',
      'X-TC-Version': _version,
      'X-TC-Region': region,
    };
  }
}
