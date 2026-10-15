import 'dart:io';

import 'package:flutter/material.dart';

import '../services/dict_service.dart';
import '../services/settings.dart';
import '../services/translate/engine.dart';
import '../services/translate/translate_service.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    final tr = TranslateService.instance;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text('设置', style: Theme.of(context).textTheme.titleLarge),
          ),
          _Section(title: '翻译引擎', subtitle: '可同时开启多个，结果并排显示', children: [
            _EngineTile(
              engine: tr.tencent,
              help: '每月 500 万字符免费。腾讯云控制台 → 访问管理 → API 密钥。建议在机器翻译控制台关闭“后付费”，避免超额扣费。',
              fields: [
                _Field(label: 'SecretId', value: s.tencentId, onChanged: (v) => s.tencentId = v),
                _Field(label: 'SecretKey', value: s.tencentKey, obscure: true, onChanged: (v) => s.tencentKey = v),
                _Field(label: '地域', value: s.tencentRegion, onChanged: (v) => s.tencentRegion = v),
              ],
            ),
            const Divider(height: 1),
            _EngineTile(
              engine: tr.deepl,
              help: '免费版每月 50 万字符，密钥以 :fx 结尾。',
              fields: [
                _Field(label: 'API 密钥', value: s.deeplKey, obscure: true, onChanged: (v) => s.deeplKey = v),
              ],
            ),
            const Divider(height: 1),
            _EngineTile(
              engine: tr.llm,
              help: '任何 OpenAI 兼容接口均可。用于“技术翻译”（强制使用术语表）和“AI 讲解”。',
              fields: [
                const _LlmPresets(),
                _Field(label: '接口地址', value: s.llmBaseUrl, onChanged: (v) => s.llmBaseUrl = v),
                _Field(label: 'API 密钥', value: s.llmKey, obscure: true, onChanged: (v) => s.llmKey = v),
                _Field(label: '模型', value: s.llmModel, onChanged: (v) => s.llmModel = v),
              ],
            ),
          ]),
          const _GlossarySection(),
          const _DictSection(),
          if (Platform.isWindows)
            _Section(title: 'Windows', children: [
              ListTile(
                title: const Text('划词翻译热键'),
                subtitle: const Text('在任何程序中选中文字后按下'),
                trailing: DropdownButton<int>(
                  value: s.hotkeyIndex,
                  underline: const SizedBox(),
                  items: [
                    for (var i = 0; i < hotkeyPresets.length; i++)
                      DropdownMenuItem(value: i, child: Text(hotkeyPresets[i].label)),
                  ],
                  onChanged: (v) => s.hotkeyIndex = v ?? 0,
                ),
              ),
              SwitchListTile(
                title: const Text('复制即翻译'),
                subtitle: const Text('监听剪贴板，复制英文后自动弹出翻译'),
                value: s.clipboardWatch,
                onChanged: (v) => s.clipboardWatch = v,
              ),
              SwitchListTile(
                title: const Text('关闭窗口时最小化到托盘'),
                value: s.closeToTray,
                onChanged: (v) => s.closeToTray = v,
              ),
            ]),
          _Section(title: '外观', children: [
            ListTile(
              title: const Text('主题'),
              trailing: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
                  ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                ],
                selected: {s.themeMode},
                onSelectionChanged: (v) => s.themeMode = v.first,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Center(
            child: Text('灵译 0.1.0 · 词库数据来自 ECDICT',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _Section extends StatelessWidget {
  const _Section({required this.title, this.subtitle, required this.children});
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(title, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
            if (subtitle != null) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
              ),
            ],
          ]),
        ),
        Card(clipBehavior: Clip.antiAlias, child: Column(children: children)),
      ]),
    );
  }
}

/// 绑定到设置项的输入框：输入即保存。
class _Field extends StatefulWidget {
  const _Field({required this.label, required this.value, required this.onChanged, this.obscure = false});
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final bool obscure;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  late final _ctrl = TextEditingController(text: widget.value);
  late bool _hidden = widget.obscure;

  @override
  void didUpdateWidget(covariant _Field old) {
    super.didUpdateWidget(old);
    // 外部修改（例如点了预设）时同步显示。
    if (widget.value != _ctrl.text && widget.value != old.value) _ctrl.text = widget.value;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: TextField(
        controller: _ctrl,
        obscureText: _hidden,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          labelText: widget.label,
          isDense: true,
          suffixIcon: widget.obscure
              ? IconButton(
                  icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                  onPressed: () => setState(() => _hidden = !_hidden),
                )
              : null,
        ),
      ),
    );
  }
}

class _EngineTile extends StatelessWidget {
  const _EngineTile({required this.engine, required this.help, required this.fields});
  final TranslateEngine engine;
  final String help;
  final List<Widget> fields;

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    final theme = Theme.of(context);
    final on = s.isEngineEnabled(engine.id);
    return ExpansionTile(
      shape: const Border(),
      leading: Switch(value: on, onChanged: (v) => s.setEngineEnabled(engine.id, v)),
      title: Text(engine.name),
      subtitle: Text(
        engine.configured ? '已配置' : '未配置',
        style: TextStyle(color: engine.configured ? Colors.green.shade700 : theme.colorScheme.outline),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(help, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        const SizedBox(height: 8),
        ...fields,
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('测试'),
            onPressed: () async {
              if (!engine.configured) {
                toast(context, engine.setupHint);
                return;
              }
              toast(context, '正在测试 ${engine.name}…');
              try {
                final r = await engine.translate(TranslateRequest('The antenna gain is 18 dBi.'));
                if (context.mounted) toast(context, '${engine.name} 正常：${r.text}');
              } catch (e) {
                if (context.mounted) toast(context, '$e');
              }
            },
          ),
        ),
      ],
    );
  }
}

class _LlmPresets extends StatelessWidget {
  const _LlmPresets();

  static const presets = [
    ('DeepSeek', 'https://api.deepseek.com/v1', 'deepseek-chat'),
    ('通义千问', 'https://dashscope.aliyuncs.com/compatible-mode/v1', 'qwen-plus'),
    ('Kimi', 'https://api.moonshot.cn/v1', 'kimi-latest'),
    ('Ollama 本地', 'http://localhost:11434/v1', 'qwen3:8b'),
  ];

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(spacing: 8, runSpacing: 6, children: [
        for (final p in presets)
          ActionChip(
            label: Text(p.$1),
            onPressed: () {
              s.llmBaseUrl = p.$2;
              s.llmModel = p.$3;
            },
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------

class _GlossarySection extends StatefulWidget {
  const _GlossarySection();

  @override
  State<_GlossarySection> createState() => _GlossarySectionState();
}

class _GlossarySectionState extends State<_GlossarySection> {
  late final _ctrl = TextEditingController(text: Settings.instance.glossary);
  bool _dirty = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: '术语表',
      subtitle: '翻译时提示术语；AI 翻译会强制使用',
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            TextField(
              controller: _ctrl,
              minLines: 6,
              maxLines: 14,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              onChanged: (_) => setState(() => _dirty = true),
              decoration: const InputDecoration(hintText: 'radiation pattern = 方向图'),
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                onPressed: () => setState(() {
                  _ctrl.text = defaultGlossary;
                  _dirty = true;
                }),
                child: const Text('恢复默认'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _dirty
                    ? () {
                        Settings.instance.glossary = _ctrl.text;
                        setState(() => _dirty = false);
                        toast(context, '术语表已保存');
                      }
                    : null,
                child: const Text('保存'),
              ),
            ]),
          ]),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _DictSection extends StatefulWidget {
  const _DictSection();

  @override
  State<_DictSection> createState() => _DictSectionState();
}

class _DictSectionState extends State<_DictSection> {
  late final _url = TextEditingController(text: Settings.instance.standardDictUrl);
  final _path = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f, String ok) async {
    try {
      await f();
      if (mounted) toast(context, ok);
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dict = DictService.instance;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: dict,
      builder: (context, _) => _Section(
        title: '离线词库',
        children: [
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: Text(dict.editionLabel),
            subtitle: Text('共 ${dict.wordCount} 词条'),
            trailing: dict.edition == DictEdition.core
                ? null
                : TextButton(
                    onPressed: () => _run(dict.removeExtra, '已恢复为内置词库'),
                    child: const Text('恢复内置'),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                '内置词库收录约 6 万常用词。下载标准词库（约 135 万词，压缩包 40 MB 左右）可覆盖大量专业术语，'
                '下载地址通常是你的 GitHub 仓库 Release 中的 standard.db.gz。',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _url,
                onChanged: (v) => Settings.instance.standardDictUrl = v,
                decoration: const InputDecoration(labelText: '标准词库下载地址', isDense: true),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<double?>(
                valueListenable: dict.downloadProgress,
                builder: (context, p, _) => p != null
                    ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        LinearProgressIndicator(value: p > 0 ? p : null),
                        const SizedBox(height: 4),
                        Text('下载中 ${(p * 100).toStringAsFixed(0)}%', style: theme.textTheme.bodySmall),
                      ])
                    : Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonalIcon(
                          icon: const Icon(Icons.download_rounded),
                          label: Text(dict.hasStandard ? '重新下载' : '下载标准词库'),
                          onPressed: () {
                            final u = _url.text.trim();
                            if (u.isEmpty) {
                              toast(context, '请先填写下载地址');
                              return;
                            }
                            _run(() => dict.downloadStandard(u), '标准词库已启用');
                          },
                        ),
                      ),
              ),
              if (Platform.isWindows) ...[
                const SizedBox(height: 12),
                Text('或导入本地词库文件（例如 ECDICT 官方的 stardict.db）：',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _path,
                      decoration: const InputDecoration(labelText: r'文件路径，如 D:\dict\stardict.db', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () {
                      final p = _path.text.trim().replaceAll('"', '');
                      if (p.isEmpty) return;
                      _run(() => dict.importCustom(p), '词库已导入');
                    },
                    child: const Text('导入'),
                  ),
                ]),
              ],
            ]),
          ),
        ],
      ),
    );
  }
}
