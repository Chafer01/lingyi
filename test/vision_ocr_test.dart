import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lingyi/services/translate/ai_router.dart';
import 'package:lingyi/services/vision_ocr.dart';

void main() {
  setUp(AiRouter.resetCooldowns);

  test('线路：Qwen3.5-27B → 397B（关闭思考）→ 智谱 GLM-4V → GLM-4.1V；没填密钥的跳过', () {
    final eps = VisionOcr.buildEndpoints(modelscopeKey: 'ms-x', zhipuKey: 'zp-x');
    expect(eps.map((e) => e.model).toList(),
        ['Qwen/Qwen3.5-27B', 'Qwen/Qwen3.5-397B-A17B', 'glm-4v-flash', 'glm-4.1v-thinking-flash']);
    expect(eps[2].extraBody['max_tokens'], 1024); // 智谱 GLM-4V-Flash 的上限，覆盖默认的 4096
    expect(eps.take(2).every((e) => e.extraBody['enable_thinking'] == false), isTrue);
    expect(eps.first.baseUrl, modelscopeBaseUrl);
    expect(eps.last.baseUrl, zhipuBaseUrl);
    expect(eps.last.apiKey, 'zp-x');
    expect(VisionOcr.buildEndpoints(modelscopeKey: '', zhipuKey: 'zp-x').map((e) => e.id), ['vl-zp-4v', 'vl-zp-41v']);
    expect(VisionOcr.buildEndpoints(modelscopeKey: ''), isEmpty);
  });

  test('提取独立公式和编号', () {
    const md = '等效媒质理论：\n\n'
        r'$$\frac{\varepsilon_i-\varepsilon_{eff}}{\varepsilon_i-\varepsilon_h}=(1-p) \tag{2-32}$$'
        '\n\n其中 \$\\varepsilon_h\$ 是基底介电常数。\n\n'
        r'\[ P_r=P_tG_tG_r \]';
    final f = VisionOcr.displayFormulas(md);
    expect(f.length, 2);
    expect(f[0].tag, '2-32');
    expect(f[0].latex, r'\frac{\varepsilon_i-\varepsilon_{eff}}{\varepsilon_i-\varepsilon_h}=(1-p)');
    expect(f[1].tag, isNull);
    expect(f[1].latex, r'P_r=P_tG_tG_r');
  });

  test('清理模型输出', () {
    expect(VisionOcr.cleanReply('```markdown\n文字 \$x\$\n```'), '文字 \$x\$');
    expect(VisionOcr.cleanReply('<think>想一想</think><|begin_of_box|>结果<|end_of_box|>'), '结果');
  });

  test('统一公式写法（GLM-4V 实测输出）', () {
    const raw = '微带线的有效介电常数：\n\n\\[ \n\\varepsilon_{eff} = \\frac{\\varepsilon_r + 1}{2}\n\\]\n\n'
        '式中 \\( h \\) 为介质基板厚度。\n\n\\(\\tag{2-7}\\)';
    final t = VisionOcr.cleanReply(raw);
    expect(t, contains(r'$$\varepsilon_{eff} = \frac{\varepsilon_r + 1}{2} \tag{2-7}$$'));
    expect(t, contains(r'式中 $h$ 为介质基板厚度。'));
    expect(t.trim().endsWith('厚度。'), isTrue);
    final f = VisionOcr.displayFormulas(t);
    expect(f.single.tag, '2-7');
    // 已有编号的公式不会被覆盖
    expect(VisionOcr.normalizeMath('\$\$a \\tag{1}\$\$\n\n\$\\tag{2}\$'), '\$\$a \\tag{1}\$\$\n\n\$\$\\tag{2}\$\$');
  });

  test('MIME 类型', () {
    expect(VisionOcr.mimeOf(r'C:\a\b.JPG'), 'image/jpeg');
    expect(VisionOcr.mimeOf('x.png'), 'image/png');
    expect(VisionOcr.mimeOf('x.webp'), 'image/webp');
  });

  test('图片请求格式：image_url 数据 URL + 提示词，首选失败时切换', () async {
    final seen = <Map>[];
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map;
      seen.add(body);
      if (body['model'] == 'Qwen/Qwen3.5-27B') {
        return http.Response('{"errors":{"message":"Request rate increased too quickly"}}', 429);
      }
      return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': r'$$P_r=P_t$$'}
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final r = await AiRouter(client: client).complete(
      VisionOcr.buildEndpoints(modelscopeKey: 'ms-x'),
      (_) => [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,AAAA'}
            },
            {'type': 'text', 'text': visionPrompt},
          ],
        },
      ],
      maxTokens: 4096,
    );
    expect(r.endpoint.id, 'vl-ms-397b');
    expect(r.switched, isTrue);
    final first = seen.first;
    expect(first['enable_thinking'], false);
    expect(first['max_tokens'], 4096);
    final content = (first['messages'] as List).single['content'] as List;
    expect(content[0]['image_url']['url'], startsWith('data:image/png;base64,'));
    expect(content[1]['text'], contains(r'\tag{2-32}'));
  });
}
