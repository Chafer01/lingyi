import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../platform/app_state.dart';
import '../services/backend.dart';
import '../services/settings.dart';
import '../services/translate/translate_service.dart';
import 'widgets.dart';

/// PDF 双语翻译（保留原排版）。使用设置里的 AI 翻译接口和术语表。
class PdfPage extends StatefulWidget {
  const PdfPage({super.key});

  @override
  State<PdfPage> createState() => _PdfPageState();
}

class _PdfPageState extends State<PdfPage> {
  String? _path;
  String? _outDir;
  bool _toEnglish = false;
  bool _submitting = false;
  final _pages = TextEditingController();
  final List<PdfJob> _jobs = [];
  Timer? _poll;

  static const _pdfType = XTypeGroup(label: 'PDF', extensions: ['pdf']);
  static const _outputs = {
    'dual': '双语：左右对照',
    'alternating': '双语：原文 / 译文交替页',
    'mono': '仅译文',
    'both': '双语对照 + 仅译文',
  };

  @override
  void dispose() {
    _poll?.cancel();
    _pages.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final f = await openFile(acceptedTypeGroups: const [_pdfType]);
    if (f != null) setState(() => _path = f.path);
  }

  Future<void> _pickOut() async {
    final d = await getDirectoryPath();
    if (d != null) setState(() => _outDir = d);
  }

  Future<void> _start() async {
    final path = _path;
    if (path == null) return;
    setState(() => _submitting = true);
    try {
      final job = await Backend.instance.pdfSubmit(
        path: path,
        outDir: _outDir,
        pages: _pages.text,
        output: Settings.instance.pdfOutput,
        toEnglish: _toEnglish,
      );
      setState(() => _jobs.insert(0, job));
      _ensurePolling();
    } catch (e) {
      if (mounted) toast(context, '$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _ensurePolling() {
    _poll ??= Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final pending = _jobs.where((j) => !j.finished).toList();
    if (pending.isEmpty) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    for (final j in pending) {
      try {
        final s = await Backend.instance.pdfStatus(j.id);
        final i = _jobs.indexWhere((x) => x.id == j.id);
        if (i >= 0 && mounted) setState(() => _jobs[i] = s);
      } catch (_) {
        // 后端重启后任务丢失：标记为出错，停止轮询。
        final i = _jobs.indexWhere((x) => x.id == j.id);
        if (i >= 0 && mounted) {
          setState(() => _jobs[i] = PdfJob({
                'id': j.id,
                'status': 'error',
                'error': '与后端的连接中断',
                'file': j.file,
              }));
        }
      }
    }
  }

  Future<void> _cancel(PdfJob j) async {
    try {
      final s = await Backend.instance.pdfCancel(j.id);
      final i = _jobs.indexWhere((x) => x.id == j.id);
      if (i >= 0 && mounted) setState(() => _jobs[i] = s);
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  static Future<void> _open(String path) => Process.run('explorer.exe', [path]);
  static Future<void> _reveal(String path) => Process.run('explorer.exe', ['/select,', path]);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = Settings.instance;
    final llm = TranslateService.instance.llm;

    final form = Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListenableBuilder(
          listenable: s,
          builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(
                  _path ?? '尚未选择文件',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _path == null ? scheme.outline : null),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(onPressed: _pick, icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('选择 PDF…')),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _pages,
                  decoration: const InputDecoration(labelText: '页码（留空为全部）', hintText: '如 1-5,8', isDense: true),
                ),
              ),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('英 → 中')),
                  ButtonSegment(value: true, label: Text('中 → 英')),
                ],
                selected: {_toEnglish},
                onSelectionChanged: (v) => setState(() => _toEnglish = v.first),
              ),
              DropdownButton<String>(
                value: _outputs.containsKey(s.pdfOutput) ? s.pdfOutput : 'dual',
                items: [
                  for (final e in _outputs.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => s.pdfOutput = v ?? 'dual',
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              const Icon(Icons.folder_outlined, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(_outDir ?? '输出到原文件所在文件夹', overflow: TextOverflow.ellipsis),
              ),
              TextButton(onPressed: _pickOut, child: const Text('更改…')),
              if (_outDir != null) TextButton(onPressed: () => setState(() => _outDir = null), child: const Text('恢复默认')),
            ]),
            const Divider(height: 24),
            Row(children: [
              Icon(llm.configured ? Icons.smart_toy_outlined : Icons.warning_amber_rounded,
                  size: 18, color: llm.configured ? scheme.primary : scheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  llm.configured
                      ? '使用 AI 翻译：${llm.chainLabel}（前一个限流或不可用时自动切换），并套用术语表'
                      : 'PDF 翻译需要 AI 翻译接口，请先在设置中填写魔搭或智谱的密钥',
                  style: TextStyle(color: llm.configured ? null : scheme.error),
                ),
              ),
              if (!llm.configured)
                TextButton(onPressed: () => AppState.instance.page.value = AppPage.settings, child: const Text('去设置')),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('每秒请求数'),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: [1, 2, 4, 8, 16].contains(s.pdfQps) ? s.pdfQps : 4,
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1（最慢）')),
                    DropdownMenuItem(value: 2, child: Text('2')),
                    DropdownMenuItem(value: 4, child: Text('4（推荐）')),
                    DropdownMenuItem(value: 8, child: Text('8（更快，更多用到备用模型）')),
                    DropdownMenuItem(value: 16, child: Text('16')),
                  ],
                  onChanged: (v) => s.pdfQps = v ?? 4,
                ),
              ]),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(value: s.pdfExtractTerms, onChanged: (v) => s.pdfExtractTerms = v),
                const Text('先自动提取全文术语（译法更统一，但总耗时约为 5 倍；已有术语表时一般不需要）'),
              ]),
            ]),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: (_path == null || _submitting || !llm.configured) ? null : _start,
                icon: _submitting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_arrow_rounded),
                label: const Text('开始翻译'),
              ),
            ),
          ]),
        ),
      ),
    );

    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('PDF 翻译', style: theme.textTheme.titleLarge),
      const SizedBox(height: 4),
      Text('保留原排版、公式和图表，输出双语对照 PDF。版面模型和字体已内置，无需联网下载。',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
      const SizedBox(height: 12),
      form,
      if (_jobs.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('任务', style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary)),
        const SizedBox(height: 8),
        for (final j in _jobs) _JobCard(job: j, onCancel: () => _cancel(j), onOpen: _open, onReveal: _reveal),
      ],
    ]);
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.job, required this.onCancel, required this.onOpen, required this.onReveal});
  final PdfJob job;
  final VoidCallback onCancel;
  final Future<void> Function(String) onOpen;
  final Future<void> Function(String) onReveal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (label, color) = switch (job.status) {
      'queued' => ('排队中', scheme.outline),
      'running' => ('进行中', scheme.primary),
      'done' => ('完成', Colors.green.shade700),
      'cancelled' => ('已取消', scheme.outline),
      _ => ('失败', scheme.error),
    };
    final mins = (job.elapsed / 60).floor();
    final secs = (job.elapsed % 60).round();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(job.file, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis)),
            Pill(label, color: color),
            const SizedBox(width: 8),
            Text('${mins > 0 ? '$mins 分 ' : ''}$secs 秒', style: theme.textTheme.bodySmall),
          ]),
          if (!job.finished) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: job.status == 'queued' ? null : job.progress / 100),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text('${job.stage.isEmpty ? '准备中' : job.stage}  ${job.progress.toStringAsFixed(0)}%',
                    style: theme.textTheme.bodySmall),
              ),
              TextButton(onPressed: onCancel, child: const Text('取消')),
            ]),
          ],
          if (job.models.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'AI 调用：${job.models.entries.map((e) => '${e.key} ${e.value} 次').join('，')}',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ],
          if (job.status == 'error') ...[
            const SizedBox(height: 6),
            SelectableText(job.error, style: TextStyle(color: scheme.error)),
          ],
          if (job.status == 'done') ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (job.outputs['dual'] != null)
                FilledButton.tonal(onPressed: () => onOpen(job.outputs['dual']!), child: const Text('打开双语 PDF')),
              if (job.outputs['mono'] != null)
                FilledButton.tonal(onPressed: () => onOpen(job.outputs['mono']!), child: const Text('打开译文 PDF')),
              if (job.outputs.isNotEmpty)
                OutlinedButton(onPressed: () => onReveal(job.outputs.values.first), child: const Text('打开所在文件夹')),
            ]),
          ],
        ]),
      ),
    );
  }
}
