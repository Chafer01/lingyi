// 用真实密钥验证 AI 线路（魔搭 Qwen3.5-397B → Qwen3.5-27B → AMD MiMo-V2.6-Flash → Gemma-4-31B → 智谱 GLM-4-Flash）。
// 由“AI 线路实测”工作流运行；没有密钥时整组跳过，不影响平时的 flutter test。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingyi/services/translate/ai_router.dart';
import 'package:lingyi/services/translate/llm.dart';

final _ms = Platform.environment['MODELSCOPE_API_KEY'] ?? '';
final _zp = Platform.environment['ZHIPU_API_KEY'] ?? '';
final _amd = Platform.environment['AMD_API_KEY'] ?? '';
final _skip = (_ms.isEmpty || _zp.isEmpty || _amd.isEmpty)
    ? '没有配置 MODELSCOPE_API_KEY / ZHIPU_API_KEY / AMD_API_KEY，跳过实测'
    : null;

const _system = '你是专业的科技翻译，熟悉射频、天线、电磁仿真和通信工程。把用户给出的文本翻译成简体中文。'
    '要求：准确、通顺、符合技术文档习惯；保留公式、变量名、单位和专有名词；不要解释，只输出译文。'
    '必须使用以下术语译法：\n- radome → 天线罩\n- beam squint → 波束偏斜\n- null filling → 零点填充';

List<AiEndpoint> _chain() => LlmEngine.buildEndpoints(chain: defaultAiChain, modelscopeKey: _ms, zhipuKey: _zp, amdKey: _amd);

void _log(String tag, AiReply r) {
  // ignore: avoid_print
  print('[$tag] 由「${r.endpoint.label}」返回：${r.text}'
      '${r.skipped.isEmpty ? '' : '\n    跳过：${r.skipped.join('；')}'}');
}

void main() {
  setUp(AiRouter.resetCooldowns);

  test('默认线路顺序与配置', () {
    final eps = _chain();
    expect(eps.map((e) => e.model).toList(),
        ['Qwen/Qwen3.5-397B-A17B', 'Qwen/Qwen3.5-27B', 'MiMo-V2.6-Flash', 'Gemma-4-31B-IT', 'glm-4-flash-250414']);
  }, skip: _skip);

  test('线路上每个模型单独都能调通', () async {
    for (final ep in _chain()) {
      final r = await AiRouter().chat([ep], _system, 'The radome introduces a slight beam squint.',
          temperature: 0.2, timeout: const Duration(seconds: 60));
      _log('单独', r);
      expect(r.endpoint.id, ep.id);
      expect(r.text, contains('天线罩'));
    }
  }, skip: _skip, timeout: const Timeout(Duration(minutes: 4)));

  test('划词翻译：按线路翻译并显示实际模型', () async {
    final router = AiRouter();
    for (final s in [
      'Null filling below the main beam improves coverage close to the tower.',
      'Parasitic elements were added to broaden the impedance bandwidth.',
    ]) {
      final r = await router.chat(_chain(), _system, s, temperature: 0.2, timeout: const Duration(seconds: 30));
      _log('翻译', r);
      expect(r.text.trim(), isNotEmpty);
      expect(r.text, isNot(contains('<think>')));
    }
  }, skip: _skip, timeout: const Timeout(Duration(minutes: 4)));

  test('首选不可用时自动切换到下一个', () async {
    // 在线路最前面放一个不存在的魔搭模型，模拟首选失效。
    final eps = _chain();
    final broken = AiEndpoint(
        id: 'broken', label: '不存在的模型', baseUrl: modelscopeBaseUrl, apiKey: _ms, model: 'Qwen/Not-A-Real-Model');
    final r = await AiRouter().chat([broken, ...eps], _system, 'The radome introduces a slight beam squint.',
        temperature: 0.2, timeout: const Duration(seconds: 30));
    _log('切换', r);
    expect(r.switched, isTrue);
    expect(r.skipped.first, contains('不存在的模型'));
    expect(r.endpoint.id, isNot('broken'));
    expect(r.text, contains('天线罩'));
  }, skip: _skip, timeout: const Timeout(Duration(minutes: 3)));

  test('AI 讲解走同一条线路', () async {
    const system = '你是一名耐心的英语老师，同时熟悉射频与通信工程。用简体中文回答，使用简洁的 Markdown。';
    final r = await AiRouter().chat(_chain(), system,
        '请讲解英文单词「radome」。词典释义：n. 天线罩。请包括核心含义、常见搭配、两个例句。',
        temperature: 0.5, timeout: const Duration(seconds: 60));
    _log('讲解', AiReply(r.text.length > 120 ? '${r.text.substring(0, 120)}…' : r.text, r.endpoint, skipped: r.skipped));
    expect(r.text.length, greaterThan(40));
  }, skip: _skip, timeout: const Timeout(Duration(minutes: 3)));
}
