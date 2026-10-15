import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lingyi/services/translate/ai_router.dart';
import 'package:lingyi/services/translate/engine.dart';
import 'package:lingyi/services/translate/llm.dart';

http.Response ok(String text) => http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': text}
          }
        ]
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

List<AiEndpoint> defaultEndpoints() => LlmEngine.buildEndpoints(
      chain: defaultAiChain,
      modelscopeKey: 'ms-test',
      zhipuKey: 'zp-test',
    );

void main() {
  setUp(AiRouter.resetCooldowns);

  test('默认线路：397B → 27B → 智谱 GLM-4-Flash', () {
    final eps = defaultEndpoints();
    expect(eps.map((e) => e.model).toList(),
        ['Qwen/Qwen3.5-397B-A17B', 'Qwen/Qwen3.5-27B', 'glm-4-flash-250414']);
    expect(eps[0].baseUrl, modelscopeBaseUrl);
    expect(eps[2].baseUrl, zhipuBaseUrl);
    expect(eps[0].extraBody['enable_thinking'], false);
    expect(eps[2].extraBody, isEmpty);
  });

  test('没填密钥的平台被跳过', () {
    final eps = LlmEngine.buildEndpoints(chain: defaultAiChain, modelscopeKey: '', zhipuKey: 'zp');
    expect(eps.map((e) => e.id).toList(), ['zhipu-flash']);
    final custom = LlmEngine.buildEndpoints(
        chain: ['custom'], modelscopeKey: '', zhipuKey: '', customBaseUrl: 'http://localhost:11434/v1', customModel: 'qwen3:8b');
    expect(custom.single.label, 'qwen3:8b');
  });

  test('第一个接口限流时自动切换，并记录原因', () async {
    final calls = <String>[];
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map;
      calls.add(body['model'] as String);
      if (body['model'] == 'Qwen/Qwen3.5-397B-A17B') {
        expect(body['enable_thinking'], false);
        expect(req.headers['Authorization'], 'Bearer ms-test');
        return http.Response('{"errors":{"message":"Request limit exceeded"}}', 429);
      }
      return ok('天线罩导致波束偏斜。');
    });
    final router = AiRouter(client: client);
    final r = await router.chat(defaultEndpoints(), 'sys', 'The radome causes beam squint.');
    expect(r.text, '天线罩导致波束偏斜。');
    expect(r.endpoint.id, 'ms-27b');
    expect(r.switched, isTrue);
    expect(r.skipped.single, contains('Qwen3.5-397B'));
    expect(r.skipped.single, contains('Request limit exceeded'));

    // 限流的接口进入冷却：下一次直接从 27B 开始，不再白等 397B
    calls.clear();
    final r2 = await router.chat(defaultEndpoints(), 'sys', 'again');
    expect(r2.endpoint.id, 'ms-27b');
    expect(calls, ['Qwen/Qwen3.5-27B']);
    expect(r2.switched, isFalse);
  });

  test('超时、服务端错误、空回复都会切换', () async {
    final client = MockClient((req) async {
      final model = (jsonDecode(req.body) as Map)['model'];
      if (model == 'Qwen/Qwen3.5-397B-A17B') {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return ok('太慢了');
      }
      if (model == 'Qwen/Qwen3.5-27B') return ok('   ');
      return ok('<think>想一想</think>增益');
    });
    final r = await AiRouter(client: client)
        .chat(defaultEndpoints(), 'sys', 'gain', timeout: const Duration(milliseconds: 100));
    expect(r.text, '增益');
    expect(r.endpoint.id, 'zhipu-flash');
    expect(r.skipped.length, 2);
    expect(r.skipped[0], contains('超时'));
  });

  test('全部失败时给出每个接口的原因', () async {
    final client = MockClient((req) async => http.Response('{"error":{"message":"bad key"}}', 401));
    await expectLater(
      AiRouter(client: client).chat(defaultEndpoints(), 'sys', 'x'),
      throwsA(isA<TranslateException>()
          .having((e) => e.message, 'message', allOf(contains('Qwen3.5-397B'), contains('GLM-4-Flash'), contains('bad key')))),
    );
  });

  test('冷却时间', () {
    expect(failCooldown(AiCallError('x', status: 429), 1), const Duration(seconds: 30));
    expect(failCooldown(AiCallError('x', status: 429), 3), const Duration(seconds: 120));
    expect(failCooldown(AiCallError('x', status: 429), 20), const Duration(seconds: 600));
    expect(failCooldown(AiCallError('x', status: 401), 1), const Duration(minutes: 10));
    expect(failCooldown(AiCallError('x', timeout: true), 1), const Duration(seconds: 15));
    expect(failCooldown(AiCallError('x', status: 400), 1), Duration.zero);
  });

  test('错误信息解析', () {
    expect(apiErrorMessage(429, '{"error":{"code":"1302","message":"并发数过高"}}'), '并发数过高');
    expect(apiErrorMessage(500, ''), 'HTTP 500');
  });
}
