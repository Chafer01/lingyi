import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/app_state.dart';
import '../platform/screen_capture.dart';
import '../services/backend.dart';
import '../services/settings.dart';
import '../services/translate/ai_router.dart';
import '../services/translate/engine.dart';
import '../services/vision_ocr.dart';
import 'lookup_view.dart' show ViaLabel;
import 'widgets.dart';

/// 截图 / 图片识别。
/// - 智能：视觉大模型识别文字和公式（Markdown + LaTeX），失败时自动改用本地文字识别；
/// - 文字 / 公式：本地离线识别（RapidOCR / LaTeX-OCR）。
class OcrPage extends StatefulWidget {
  const OcrPage({super.key});

  @override
  State<OcrPage> createState() => _OcrPageState();
}

class _OcrPageState extends State<OcrPage> {
  late String _mode = Settings.instance.ocrMode;
  bool _busy = false;
  String? _error;

  /// 智能识别失败、改用本地识别时的说明。
  String? _note;
  Uint8List? _image;
  String _imageMime = 'image/png';
  AiReply? _reply;
  final _text = TextEditingController();

  static const _imageTypes = XTypeGroup(
    label: '图片',
    extensions: ['png', 'jpg', 'jpeg', 'bmp', 'gif', 'tif', 'tiff', 'webp'],
  );

  @override
  void initState() {
    super.initState();
    AppState.instance.ocrIncoming.addListener(_onIncoming);
  }

  @override
  void dispose() {
    AppState.instance.ocrIncoming.removeListener(_onIncoming);
    _text.dispose();
    super.dispose();
  }

  void _onIncoming() {
    final inc = AppState.instance.ocrIncoming.value;
    if (inc == null || !mounted) return;
    setState(() {
      _error = inc.error;
      _note = inc.note;
      if (inc.reply != null) {
        _showSmart(inc.reply!, inc.result?.image);
      } else if (inc.result != null) {
        _showLocal(inc.result!);
      }
    });
  }

  void _showLocal(OcrResult r) {
    _reply = null;
    _mode = r.mode == 'formula' ? 'formula' : (_mode == 'smart' ? 'smart' : 'text');
    if (r.image != null) {
      _image = r.image;
      _imageMime = 'image/png';
    }
    _text.text = r.mode == 'formula' ? (r.latex ?? '') : r.text;
  }

  void _showSmart(AiReply r, Uint8List? image) {
    _reply = r;
    if (image != null) _image = image;
    _text.text = r.text;
  }

  // ------------------------------------------------------------------ 识别流程

  Future<void> _guard(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      await body();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 本地识别（后端）。
  Future<void> _local(Future<OcrResult> Function() job) async {
    final r = await job();
    if (!mounted) return;
    setState(() {
      _showLocal(r);
      if (r.text.trim().isEmpty) _error = r.mode == 'formula' ? '没有识别到公式' : '没有识别到文字';
    });
  }

  /// 智能识别：视觉大模型；不可用时改用本地文字识别（仅 Windows，有本地后端）。
  Future<void> _smart(Uint8List image, String mime) async {
    setState(() {
      _image = image;
      _imageMime = mime;
    });
    final vision = VisionOcr.instance;
    String reason;
    if (vision.configured) {
      try {
        final r = await vision.recognize(image, mime: mime);
        if (!mounted) return;
        setState(() {
          _showSmart(r, image);
          if (r.text.trim().isEmpty) _error = '没有识别到内容';
        });
        return;
      } on TranslateException catch (e) {
        reason = e.message;
      }
    } else {
      reason = '没有填写魔搭（ModelScope）访问令牌（设置 → 翻译引擎 → AI 翻译）';
    }
    if (!Platform.isWindows) throw TranslateException('智能识别不可用：$reason');
    await _local(() => Backend.instance.ocrBytes(image, mode: 'text'));
    if (mounted) setState(() => _note = '智能识别不可用，已改用本地文字识别（公式无法识别）。原因：$reason');
  }

  Future<void> _fromClipboard() => _guard(() async {
        if (_mode == 'smart') {
          final r = await Backend.instance.ocrClipboard(mode: 'none');
          if (r.image == null) throw BackendException('剪贴板里没有图片');
          await _smart(r.image!, 'image/png');
        } else {
          await _local(() => Backend.instance.ocrClipboard(mode: _mode));
        }
      });

  Future<void> _snip() async {
    // 主窗口会挡住要截的内容，先最小化。
    await windowManager.minimize();
    final warmup = Backend.instance.ensureStarted().catchError((Object _) {});
    final ok = await ScreenCapture.snip();
    await windowManager.restore();
    await windowManager.focus();
    if (!ok) return;
    await warmup;
    await _fromClipboard();
  }

  Future<void> _openFile() async {
    final f = await openFile(acceptedTypeGroups: const [_imageTypes]);
    if (f == null) return;
    await _guard(() async {
      if (_mode == 'smart') {
        await _smart(await f.readAsBytes(), VisionOcr.mimeOf(f.path));
      } else {
        await _local(() => Backend.instance.ocrFile(f.path, mode: _mode));
      }
    });
  }

  /// 换模式后用同一张图重新识别。
  Future<void> _rerun() async {
    final img = _image;
    if (img == null) return;
    await _guard(() async {
      if (_mode == 'smart') {
        await _smart(img, _imageMime);
      } else {
        await _local(() => Backend.instance.ocrBytes(img, mode: _mode));
      }
    });
  }

  // ------------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hk = Settings.instance.ocrHotkey;
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final toolbar = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      FilledButton.icon(
        onPressed: _busy ? null : _snip,
        icon: const Icon(Icons.crop),
        label: Text(hk.key.isEmpty ? '截图识别' : '截图识别（${hk.label}）'),
      ),
      OutlinedButton.icon(
        onPressed: _busy ? null : _fromClipboard,
        icon: const Icon(Icons.content_paste),
        label: const Text('识别剪贴板图片'),
      ),
      OutlinedButton.icon(
        onPressed: _busy ? null : _openFile,
        icon: const Icon(Icons.image_outlined),
        label: const Text('打开图片…'),
      ),
      const SizedBox(width: 8),
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
              value: 'smart',
              icon: Icon(Icons.auto_awesome, size: 18),
              label: Text('智能'),
              tooltip: '视觉大模型识别文字和公式（截图会上传到魔搭）'),
          ButtonSegment(value: 'text', icon: Icon(Icons.notes), label: Text('文字'), tooltip: '本地离线识别文字'),
          ButtonSegment(
              value: 'formula', icon: Icon(Icons.functions), label: Text('公式'), tooltip: '本地离线识别单个公式'),
        ],
        selected: {_mode},
        onSelectionChanged: _busy
            ? null
            : (v) {
                setState(() => _mode = v.first);
                Settings.instance.ocrMode = v.first;
                if (_image != null) _rerun();
              },
      ),
      if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
    ]);

    final vision = VisionOcr.instance;
    final hint = switch (_mode) {
      'smart' => vision.configured
          ? '智能识别：${vision.chainLabel}（前一个不可用时自动切换）。\n'
              '文字和公式一起识别，公式输出为 LaTeX，可复制为 Word 公式；翻译时公式保持原样。\n'
              '截图会上传到魔搭识别；涉密资料请改用“文字”或“公式”本地模式。'
          : '智能识别需要魔搭（ModelScope）令牌或智谱密钥：设置 → 翻译引擎 → AI 翻译。\n都未填写时自动改用本地文字识别。',
      'formula' => '公式模式（本地离线）：截图里只框选一个公式，输出 LaTeX，可复制为 Word 公式。',
      _ => '文字模式（本地离线）：识别后可直接翻译；图中的公式无法识别。',
    };

    final preview = Card(
      clipBehavior: Clip.antiAlias,
      child: _image == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '截图、复制图片后点“识别剪贴板图片”，或打开图片文件。\n\n$hint',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.outline, height: 1.6),
                ),
              ),
            )
          : Container(
              color: Colors.white,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(8),
              child: InteractiveViewer(
                maxScale: 6,
                child: Image.memory(_image!, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
              ),
            ),
    );

    final isFormula = _mode == 'formula' && _reply == null;
    final result = Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text(isFormula ? 'LaTeX' : '识别结果', style: theme.textTheme.titleSmall),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _reply != null ? r'公式为 LaTeX（$…$ 行内，$$…$$ 独立），可直接修改后再翻译' : (isFormula ? '' : '可直接修改后再翻译'),
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SelectableText(_error!, style: TextStyle(color: scheme.error)),
            ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SelectableText(_note!, style: TextStyle(color: scheme.tertiary, fontSize: 13)),
            ),
          Expanded(
            child: TextField(
              controller: _text,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(
                fontFamily: isFormula ? 'Consolas' : null,
                fontSize: isFormula ? 15 : 14,
                height: 1.5,
              ),
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
            ),
          ),
          if (_reply != null) _FormulaList(controller: _text),
          const SizedBox(height: 10),
          Row(children: [
            if (_reply != null) Expanded(child: ViaLabel(_reply!.endpoint.label, skipped: _reply!.skipped)),
            if (_reply == null) const Spacer(),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: [
              if (!isFormula) ...[
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制'),
                  onPressed: () => copyText(context, _text.text),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.translate, size: 18),
                  label: const Text('翻译'),
                  onPressed: () {
                    final t = _text.text.trim();
                    if (t.isNotEmpty) AppState.instance.push(t);
                  },
                ),
              ] else ...[
                OutlinedButton(
                  onPressed: () => copyText(context, _text.text),
                  child: const Text('复制 LaTeX'),
                ),
                OutlinedButton(
                  onPressed: () => copyText(context, '\$${_text.text}\$'),
                  child: const Text(r'复制 $…$'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: const Text('复制为 Word 公式'),
                  onPressed: () => copyAsWordFormula(context, _text.text),
                ),
              ],
            ]),
          ]),
        ]),
      ),
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('截图识别', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        toolbar,
        const SizedBox(height: 12),
        Expanded(
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: preview),
                  const SizedBox(width: 12),
                  Expanded(child: result),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: preview),
                  const SizedBox(height: 12),
                  Expanded(child: result),
                ]),
        ),
      ]),
    );
  }
}

/// 把 LaTeX 转成 MathML 放进剪贴板：在 Word 中粘贴（选“只保留文本”）即为可编辑公式。
Future<void> copyAsWordFormula(BuildContext context, String latex) async {
  try {
    final mathml = await Backend.instance.latexToMathml(latex);
    await Clipboard.setData(ClipboardData(text: mathml));
    if (context.mounted) toast(context, '已复制为 Word 公式：在 Word 中粘贴时选“只保留文本”即为可编辑公式');
  } catch (e) {
    if (context.mounted) toast(context, '$e');
  }
}

/// 智能识别结果中的独立公式：逐个复制为 LaTeX 或 Word 公式。随文本修改实时更新。
class _FormulaList extends StatelessWidget {
  const _FormulaList({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final formulas = VisionOcr.displayFormulas(controller.text);
        if (formulas.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: ListView(shrinkWrap: true, children: [
              for (var i = 0; i < formulas.length; i++)
                Row(children: [
                  SizedBox(
                    width: 84,
                    child: Text('公式 ${formulas[i].tag != null ? '(${formulas[i].tag})' : i + 1}',
                        style: theme.textTheme.labelMedium),
                  ),
                  Expanded(
                    child: Text(formulas[i].latex,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'Consolas', fontSize: 13)),
                  ),
                  TextButton(
                    onPressed: () => copyText(context, formulas[i].latex),
                    child: const Text('LaTeX'),
                  ),
                  if (Platform.isWindows)
                    TextButton(
                      onPressed: () => copyAsWordFormula(context, formulas[i].latex),
                      child: const Text('Word 公式'),
                    ),
                ]),
            ]),
          ),
        );
      },
    );
  }
}
