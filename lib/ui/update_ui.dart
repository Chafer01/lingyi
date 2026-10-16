import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/desktop.dart';
import '../services/settings.dart';
import '../services/updater.dart';
import '../version.dart';

Future<void> openLink(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(bytes < 10 * 1048576 ? 1 : 0)} MB';

/// 主窗口顶部的更新提示条：发现新版本，或报告上次更新的结果。
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final u = Updater.instance;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([u.available, u.notice]),
      builder: (context, _) {
        final info = u.available.value;
        final notice = u.notice.value;
        if (info == null && notice == null) return const SizedBox.shrink();
        final text = info != null ? '发现新版本 ${info.version}（当前 $appVersion）' : notice!;
        return Material(
          color: info != null ? scheme.primaryContainer : scheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(children: [
              Icon(info != null ? Icons.system_update_alt : Icons.info_outline, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text(text)),
              if (info != null) ...[
                TextButton(
                  onPressed: () {
                    Settings.instance.ignoredUpdate = info.version;
                    u.available.value = null;
                  },
                  child: const Text('忽略此版本'),
                ),
                const SizedBox(width: 4),
                FilledButton.tonal(onPressed: () => showUpdateDialog(context, info), child: const Text('查看并更新')),
              ],
              IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => info != null ? u.available.value = null : u.notice.value = null,
              ),
            ]),
          ),
        );
      },
    );
  }
}

Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) =>
    showDialog(context: context, barrierDismissible: false, builder: (_) => _UpdateDialog(info));

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog(this.info);
  final UpdateInfo info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  String? _stage; // 下载中的说明
  int _done = 0, _total = 0;
  String? _error;
  Directory? _staged;
  DateTime _lastPaint = DateTime.fromMillisecondsSinceEpoch(0);

  UpdateInfo get info => widget.info;
  bool get _busy => _stage != null && _staged == null && _error == null;

  Future<void> _startWindows() async {
    setState(() {
      _error = null;
      _stage = '正在连接…';
      _done = 0;
    });
    try {
      final dir = await Updater.instance.prepareWindows(info, (stage, done, total) {
        final now = DateTime.now();
        if (stage != _stage || now.difference(_lastPaint).inMilliseconds > 200) {
          _lastPaint = now;
          if (mounted) {
            setState(() {
              _stage = stage;
              _done = done;
              _total = total;
            });
          }
        }
      });
      if (mounted) setState(() => _staged = dir);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _restart() async {
    try {
      await Updater.instance.launchInstaller(info, _staged!);
    } catch (e) {
      setState(() => _error = '无法启动更新：$e');
      return;
    }
    await Desktop.instance.quit();
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloads = Platform.isWindows ? Updater.windowsDownloads(info) : const <(String, UpdateAsset)>[];
    final size = downloads.fold<int>(0, (a, d) => a + d.$2.size);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);

    final content = <Widget>[
      Text('当前 $appVersion → 新版 ${info.version}', style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      if (info.notes.isNotEmpty)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: SingleChildScrollView(child: SelectableText(info.notes)),
        ),
      const SizedBox(height: 12),
      if (Platform.isWindows && downloads.isNotEmpty && _stage == null)
        Text(
          downloads.length == 1
              ? '只需下载程序本体（${_mb(size)}），截图识别与 PDF 后端没有变化，不用重新下载。'
              : '需要下载程序和截图识别与 PDF 后端，共 ${_mb(size)}。',
          style: hint,
        ),
      if (_busy) ...[
        Text(_stage!),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: _total > 0 ? _done / _total : null),
        const SizedBox(height: 4),
        if (_total > 0) Text('${_mb(_done)} / ${_mb(_total)}', style: hint),
      ],
      if (_staged != null) const Text('新版已准备好。点“立即重启”后灵译会退出，替换文件后自动重新打开（约 10 秒）。'),
      if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
    ];

    final actions = <Widget>[
      if (!_busy)
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_staged != null ? '稍后' : '以后再说')),
      if (_error != null || (!Platform.isWindows && !Platform.isAndroid))
        TextButton(onPressed: () => openLink(info.page), child: const Text('打开下载页')),
      if (Platform.isAndroid)
        FilledButton(
          onPressed: () => openLink(info.android?.url ?? info.page),
          child: const Text('下载安装包'),
        ),
      if (Platform.isWindows && downloads.isNotEmpty && _staged == null && !_busy)
        FilledButton(onPressed: _startWindows, child: Text(_error != null ? '重试' : '立即更新')),
      if (Platform.isWindows && downloads.isEmpty)
        FilledButton(onPressed: () => openLink(info.page), child: const Text('打开下载页')),
      if (_staged != null) FilledButton(onPressed: _restart, child: const Text('立即重启')),
    ];

    return AlertDialog(
      title: const Text('更新灵译'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: content),
      ),
      actions: actions,
    );
  }
}

/// 设置页里的“关于与更新”。
class AboutUpdateTile extends StatefulWidget {
  const AboutUpdateTile({super.key});

  @override
  State<AboutUpdateTile> createState() => _AboutUpdateTileState();
}

class _AboutUpdateTileState extends State<AboutUpdateTile> {
  bool _checking = false;
  String? _result;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _result = null;
    });
    try {
      final info = await Updater.instance.check();
      if (!mounted) return;
      if (info == null) {
        setState(() => _result = '已是最新版本');
      } else {
        setState(() => _result = null);
        await showUpdateDialog(context, info);
      }
    } catch (e) {
      if (mounted) setState(() => _result = '检查失败：$e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    return Column(children: [
      ListTile(
        title: Text('灵译 $appVersion'),
        subtitle: Text(_result ?? '安装包发布在 GitHub：Chafer01/lingyi'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          TextButton(onPressed: () => openLink(Updater.releasesPage), child: const Text('发布页')),
          const SizedBox(width: 4),
          FilledButton.tonal(
            onPressed: _checking ? null : _check,
            child: _checking
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('检查更新'),
          ),
        ]),
      ),
      SwitchListTile(
        title: const Text('启动时自动检查更新'),
        subtitle: const Text('有新版时在窗口顶部提示；Windows 上可一键下载安装，后端没变时只下载几十 MB 的程序本体'),
        value: s.autoCheckUpdate,
        onChanged: (v) => setState(() => s.autoCheckUpdate = v),
      ),
    ]);
  }
}
