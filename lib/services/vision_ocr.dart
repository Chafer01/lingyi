import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'settings.dart';
import 'translate/ai_router.dart';

/// 截图“智能识别”：把图片交给视觉大模型，输出 Markdown（正文原样，公式为 LaTeX）。
///
/// 线路与选择依据见 tools/ocr_eval（5 张论文排版测试图）：Qwen3.5-27B / 397B 公式全部识别正确、
/// 行内符号 100%、正文错字率约 1.6%；27B 保留公式编号最完整，因此排在首位。
const visionRoutes = <AiRoute>[
  AiRoute('vl-ms-27b', 'modelscope', 'Qwen/Qwen3.5-27B', 'Qwen3.5-27B（魔搭）',
      extraBody: {'enable_thinking': false}, note: '实测公式 5/5、编号 5/5，约 3 秒'),
  AiRoute('vl-ms-397b', 'modelscope', 'Qwen/Qwen3.5-397B-A17B', 'Qwen3.5-397B（魔搭）',
      extraBody: {'enable_thinking': false}, note: '实测公式 5/5，约 4 秒'),
  // 智谱 GLM-4.1V-Thinking-Flash：两次实测公式 5/5、3/5，编号 5/5，行内符号偶尔写成普通字母，需要先思考（约 8 秒）。
  // AMD Token Factory（DeepSeek-V4-Flash-Vision-Exp、Qwen3.8-27B）：公式 5/5、编号 5/5，约 6–8 秒。
  AiRoute('vl-amd-dsv', 'amd', 'DeepSeek-V4-Flash-Vision-Exp', 'DeepSeek-V4-Flash-Vision（AMD）',
      note: '实测公式 5/5、行内符号 100%，约 8 秒'),
  AiRoute('vl-amd-q27', 'amd', 'Qwen3.8-27B', 'Qwen3.8-27B（AMD）',
      extraBody: {'chat_template_kwargs': {'enable_thinking': false}}, note: '实测公式 5/5，约 6 秒'),
  // 智谱 GLM-4V-Flash：公式 4/5、行内符号 93%、错字率 0.1%，约 3.5 秒；输出上限 1024 个 token，长截图可能截断。
  AiRoute('vl-zp-4v', 'zhipu', 'glm-4v-flash', 'GLM-4V-Flash（智谱）',
      extraBody: {'max_tokens': 1024}, note: '实测公式 4/5，约 3.5 秒'),
  AiRoute('vl-zp-41v', 'zhipu', 'glm-4.1v-thinking-flash', 'GLM-4.1V-Thinking-Flash（智谱）',
      note: '实测公式 5/5，约 8 秒'),
];

const defaultVisionChain = ['vl-ms-27b', 'vl-ms-397b', 'vl-amd-dsv', 'vl-amd-q27', 'vl-zp-4v', 'vl-zp-41v'];

/// 与 tools/ocr_eval/run_eval.py 的 PROMPT 保持一致（实测结果基于这段提示）。
const visionPrompt = '请识别图片中的全部文字和数学公式，按原文顺序输出。要求：\n'
    '1. 普通文字原样输出，不要翻译、改写或总结；\n'
    r'2. 行内公式和符号用 $...$ 包裹，独立成行的公式用 $$...$$ 包裹，公式内容使用标准 LaTeX；' '\n'
    r'3. 公式编号（如 (2-32)）写在对应公式里，用 \tag{2-32} 表示；' '\n'
    '4. 段落之间空一行；不要输出任何解释或额外内容。';

/// 识别结果里的一个独立公式。
class Formula {
  const Formula(this.latex, this.tag);

  /// 去掉 \tag{...} 后的 LaTeX。
  final String latex;

  /// 公式编号（没有时为 null）。
  final String? tag;
}

class VisionOcr {
  VisionOcr._();
  static final VisionOcr instance = VisionOcr._();

  final _router = AiRouter();

  List<AiEndpoint> get endpoints =>
      buildEndpoints(
          modelscopeKey: Settings.instance.modelscopeKey,
          zhipuKey: Settings.instance.zhipuKey,
          amdKey: Settings.instance.amdKey);

  bool get configured => endpoints.isNotEmpty;

  String get chainLabel => endpoints.map((e) => e.label).join(' → ');

  static List<AiEndpoint> buildEndpoints(
      {required String modelscopeKey,
      String zhipuKey = '',
      String amdKey = '',
      List<String> chain = defaultVisionChain}) {
    final out = <AiEndpoint>[];
    for (final id in chain) {
      AiRoute? r;
      for (final v in visionRoutes) {
        if (v.id == id) r = v;
      }
      if (r == null) continue;
      final (base, key) = switch (r.provider) {
        'modelscope' => (modelscopeBaseUrl, modelscopeKey),
        'zhipu' => (zhipuBaseUrl, zhipuKey),
        'amd' => (amdBaseUrl, amdKey),
        _ => ('', ''),
      };
      if (key.isEmpty) continue;
      out.add(AiEndpoint(id: r.id, label: r.label, baseUrl: base, apiKey: key, model: r.model, extraBody: r.extraBody));
    }
    return out;
  }

  /// 识别图片。返回的 [AiReply.text] 是 Markdown（含 $...$ / $$...$$ 公式）。
  Future<AiReply> recognize(Uint8List image, {String mime = 'image/png'}) async {
    final (bytes, type) = await _prepare(image, mime);
    final url = 'data:$type;base64,${base64Encode(bytes)}';
    final r = await _router.complete(
      endpoints,
      (_) => [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': url},
            },
            {'type': 'text', 'text': visionPrompt},
          ],
        },
      ],
      temperature: 0.1,
      timeout: const Duration(seconds: 90),
      maxTokens: 4096,
    );
    return AiReply(cleanReply(r.text), r.endpoint, skipped: r.skipped);
  }

  /// 过大的截图缩小（最长边 2048），过小的放大到至少 32 像素高（模型对极小图片识别差）。
  static Future<(Uint8List, String)> _prepare(Uint8List bytes, String mime) async {
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width, h = frame.image.height;
      frame.image.dispose();
      final longest = math.max(w, h), shortest = math.min(w, h);
      double scale = 1;
      if (longest > 2048) scale = 2048 / longest;
      if (shortest * scale < 32) scale = 32 / shortest;
      if (scale == 1 && bytes.length < 4 * 1024 * 1024) return (bytes, mime);
      final resized = await ui.instantiateImageCodec(bytes,
          targetWidth: math.max(1, (w * scale).round()), targetHeight: math.max(1, (h * scale).round()));
      final img = (await resized.getNextFrame()).image;
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      resized.dispose();
      if (data == null) return (bytes, mime);
      return (data.buffer.asUint8List(), 'image/png');
    } catch (_) {
      return (bytes, mime); // 无法解码时原样发送，让接口自己判断
    } finally {
      codec?.dispose();
    }
  }

  /// 去掉个别模型包在输出外面的代码块标记、思考过程等。
  static String cleanReply(String s) {
    var t = s.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    t = t.replaceAll('<|begin_of_box|>', '').replaceAll('<|end_of_box|>', '').trim();
    t = t.replaceFirst(RegExp(r'^```(?:markdown|md|latex)?[ \t]*\n'), '');
    t = t.replaceFirst(RegExp(r'\n?```\s*$'), '');
    return normalizeMath(t.trim());
  }

  /// 统一公式写法：\[...\] → $$...$$，\(...\) → $...$（GLM-4V 常用后者）；
  /// 单独成行的 $\tag{..}$ 归到它前面最近一个没有编号的独立公式里。
  static String normalizeMath(String s) {
    var t = s.replaceAllMapped(RegExp(r'\\\[([\s\S]+?)\\\]'), (m) => '\$\$${m[1]!.trim()}\$\$');
    t = t.replaceAllMapped(RegExp(r'\\\(([\s\S]+?)\\\)'), (m) => '\$${m[1]!.trim()}\$');
    final lone = RegExp(r'^[ \t]*\$\s*(\\tag\*?\{[^}]*\})\s*\$[ \t]*$', multiLine: true);
    final display = RegExp(r'\$\$([\s\S]+?)\$\$');
    while (true) {
      final m = lone.firstMatch(t);
      if (m == null) break;
      final before = t.substring(0, m.start);
      RegExpMatch? target;
      for (final d in display.allMatches(before)) {
        if (!d[1]!.contains(r'\tag')) target = d;
      }
      final rest = t.substring(m.end);
      if (target == null) {
        // 找不到可归属的公式：保留为独立的编号行
        t = '$before\$\$${m[1]}\$\$$rest';
        break;
      }
      final merged = '\$\$${target[1]!.trim()} ${m[1]}\$\$';
      final head = before.substring(0, target.start) + merged + before.substring(target.end);
      t = (head.trimRight() + (rest.trim().isEmpty ? '' : '\n\n${rest.trimLeft()}'));
    }
    return t.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// 找出 Markdown 里的独立公式（$$...$$ 或 \[...\]），按出现顺序。
  static List<Formula> displayFormulas(String md) {
    final re = RegExp(r'\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]');
    final tagRe = RegExp(r'\\tag\*?\{([^}]*)\}');
    final out = <Formula>[];
    for (final m in re.allMatches(md)) {
      final body = (m.group(1) ?? m.group(2) ?? '').trim();
      final tag = tagRe.firstMatch(body)?.group(1);
      out.add(Formula(body.replaceAll(tagRe, '').trim(), tag));
    }
    return out;
  }

  /// 根据文件扩展名得到 MIME 类型。
  static String mimeOf(String path) {
    final ext = path.toLowerCase().split('.').last;
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'bmp' => 'image/bmp',
      _ => 'image/png',
    };
  }
}
