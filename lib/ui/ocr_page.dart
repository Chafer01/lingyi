import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/app_state.dart';
import '../platform/screen_capture.dart';
import '../services/backend.dart';
import '../services/settings.dart';
import 'widgets.dart';

/// 截图 / 图片识别：文字（可直接送去翻译）或公式（LaTeX / MathML）。
class OcrPage extends StatefulWidget {
  const OcrPage({super.key});

  @override
  State<OcrPage> createState() => _OcrPageState();
}

class _OcrPageState extends State<OcrPage> {
  String _mode = 'text';
  bool _busy = false;
  String? _error;
  Uint8List? _image;
  String? _imageLabel;
  OcrResult? _result;
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
      if (inc.result != null) _show(inc.result!, label: '截图');
    });
  }

  void _show(OcrResult r, {String? label}) {
    _result = r;
    _mode = r.mode;
    if (r.image != null) {
      _image = r.image;
      _imageLabel = label;
    }
    _text.text = r.mode == 'formula' ? (r.latex ?? '') : r.text;
  }

  Future<void> _run(Future<OcrResult> Function() job, {String? label}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await job();
      if (!mounted) return;
      setState(() {
        _show(r, label: label);
        if (r.text.trim().isEmpty) _error = r.mode == 'formula' ? '没有识别到公式' : '没有识别到文字';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _snip() async {
    // 主窗口会挡住要截的内容，先最小化。
    await windowManager.minimize();
    final warmup = Backend.instance.ensureStarted().catchError((Object _) {});
    final ok = await ScreenCapture.snip();
    await windowManager.restore();
    await windowManager.focus();
    if (!ok) return;
    await warmup;
    await _run(() => Backend.instance.ocrClipboard(mode: _mode), label: '截图');
  }

  Future<void> _clipboard() => _run(() => Backend.instance.ocrClipboard(mode: _mode), label: '剪贴板');

  Future<void> _openFile() async {
    final f = await openFile(acceptedTypeGroups: const [_imageTypes]);
    if (f == null) return;
    await _run(() => Backend.instance.ocrFile(f.path, mode: _mode), label: f.name);
  }

  /// 换模式后用同一张图重新识别。
  Future<void> _rerun() async {
    final img = _image;
    if (img == null) return;
    await _run(() => Backend.instance.ocrBytes(img, mode: _mode), label: _imageLabel);
  }

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
        onPressed: _busy ? null : _clipboard,
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
          ButtonSegment(value: 'text', icon: Icon(Icons.notes), label: Text('文字')),
          ButtonSegment(value: 'formula', icon: Icon(Icons.functions), label: Text('公式')),
        ],
        selected: {_mode},
        onSelectionChanged: _busy
            ? null
            : (v) {
                setState(() => _mode = v.first);
                if (_image != null && _result?.mode != _mode) _rerun();
              },
      ),
      if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
    ]);

    final preview = Card(
      clipBehavior: Clip.antiAlias,
      child: _image == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '截图、复制图片后点“识别剪贴板图片”，或打开图片文件。\n'
                  '文字模式：识别后可直接翻译；公式模式：输出 LaTeX，可复制为 Word 公式。\n'
                  '首次识别需要加载模型，约需几秒。',
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

    final isFormula = _mode == 'formula';
    final result = Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text(isFormula ? 'LaTeX' : '识别结果', style: theme.textTheme.titleSmall),
            const SizedBox(width: 8),
            if (!isFormula) Text('可直接修改后再翻译', style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
          ]),
          const SizedBox(height: 8),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
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
          const SizedBox(height: 10),
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
                onPressed: _result?.mathml == null
                    ? null
                    : () async {
                        // Word 会把粘贴进来的 MathML 文本自动转换为可编辑公式。
                        await Clipboard.setData(ClipboardData(text: _result!.mathml!));
                        if (context.mounted) toast(context, '已复制 MathML，在 Word 中粘贴即为公式（选“只保留文本”）');
                      },
              ),
            ],
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
