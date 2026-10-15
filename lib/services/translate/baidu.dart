import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../util/text_utils.dart';
import '../settings.dart';
import 'engine.dart';

/// 百度翻译开放平台“通用文本翻译”。高级版（个人认证后）每月 100 万字符免费。
/// 文档：https://fanyi-api.baidu.com/doc/21
class BaiduEngine extends TranslateEngine {
  final _s = Settings.instance;
  final _rand = Random();

  @override
  String get id => 'baidu';
  @override
  String get name => '百度翻译';
  @override
  bool get configured => _s.baiduAppId.isNotEmpty && _s.baiduKey.isNotEmpty;
  @override
  String get setupHint => '在设置中填写百度翻译 APP ID 和密钥';

  static const _errors = {
    '52001': '请求超时',
    '52002': '系统错误',
    '52003': 'APP ID 错误或未开通服务',
    '54000': '必填参数为空',
    '54001': '签名错误，请检查密钥',
    '54003': '访问频率受限（标准版每秒 1 次）',
    '54004': '账户余额不足',
    '54005': '长文本请求过于频繁',
    '58000': '客户端 IP 不在白名单内',
    '58001': '不支持该语言方向',
    '58002': '服务已关闭，请在控制台开启',
    '90107': '认证未通过或未生效',
  };

  /// 签名：MD5(appid + q + salt + 密钥)。
  static String sign(String appId, String q, String salt, String key) =>
      md5.convert(utf8.encode('$appId$q$salt$key')).toString();

  @override
  Future<TranslateResult> translate(TranslateRequest req) async {
    final appId = _s.baiduAppId;
    final salt = '${_rand.nextInt(1 << 30)}';
    final resp = await http.post(
      Uri.https('fanyi-api.baidu.com', '/api/trans/vip/translate'),
      body: {
        'q': req.text,
        'from': 'auto',
        'to': req.to == Lang.zh ? 'zh' : 'en',
        'appid': appId,
        'salt': salt,
        'sign': sign(appId, req.text, salt, _s.baiduKey),
      },
    ).timeout(const Duration(seconds: 15));
    final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final code = json['error_code']?.toString();
    if (code != null && code != '52000') {
      throw TranslateException('百度翻译：${_errors[code] ?? json['error_msg']}（$code）');
    }
    final list = (json['trans_result'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (list.isEmpty) throw TranslateException('百度翻译没有返回结果');
    return TranslateResult(list.map((e) => e['dst'] as String).join('\n'), detected: json['from'] as String?);
  }
}
