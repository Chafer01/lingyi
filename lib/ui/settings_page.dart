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
          _Section(title: '翻译引擎', subtitle: '可同时开启多个，结果并排显示。免费额度可能随厂商政策变化，建议至少配两个', children: [
            _EngineTile(
              engine: tr.volc,
              help: '每月 200 万字符免费。火山引擎控制台 → 机器翻译 开通服务；右上角头像 → API 访问密钥 创建 Access Key。',
              fields: [
                _Field(label: 'Access Key ID', value: s.volcAk, onChanged: (v) => s.volcAk = v),
                _Field(label: 'Secret Access Key', value: s.volcSk, obscure: true, onChanged: (v) => s.volcSk = v),
              ],
            ),
            const Divider(height: 1),
            _EngineTile(
              engine: tr.baidu,
              help: '百度翻译开放平台 → 通用文本翻译。完成个人认证并切换到高级版后，每月 100 万字符免费。',
              fields: [
                _Field(label: 'APP ID', value: s.baiduAppId, onChanged: (v) => s.baiduAppId = v),
                _Field(label: '密钥', value: s.baiduKey, obscure: true, onChanged: (v) => s.baiduKey = v),
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
              help: '任何 OpenAI 兼容接口均可，用于技术翻译（强制使用术语表）和 AI 讲解。推荐智谱 GLM-4.7-Flash：官方免费，在 open.bigmodel.cn 注册后创建 API Key 即可；免费版只允许 1 个并发。',
              fields: [
                const _LlmPresets(),
                _Field(label: '接口地址', value: s.llmBaseUrl, onChanged: (v) => s.llmBaseUrl = v),
                _Field(label: 'API 密钥', value: s.llmKey, obscure: true, onChanged: (v) => s.llmKey = v),
                _Field(label: '模型', value: s.llmModel, onChanged: (v) => s.llmModel = v),
              ],
            ),
            const Divider(height: 1),
            _EngineTile(
              engine: tr.tencent,
              help: '⚠ 腾讯云已于 2026-10-01 停发免费额度，接口调用频率逐月缩减，2027-10-01 起完全停止服务。仅建议已有付费资源包的用户使用。',
              fields: [
                _Field(label: 'SecretId', value: s.tencentId, onChanged: (v) => s.tencentId = v),
                _Field(label: 'SecretKey', value: s.tencentKey, obscure: true, onChanged: (v) => s.tencentKey = v),
                _Field(label: '地域', value: s.tencentRegion, onChanged: (v) => s.tencentRegion = v),
              ],
            ),
          ]),
          const _GlossarySection(),
          const _DictSection(),
          if (Platform.isWindows) const _AutoSelectSection(),
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
            child: Text('灵译 0.2.1 · 词库数据来自 ECDICT',
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
    ('智谱 GLM-4.7-Flash（免费）', 'https://open.bigmodel.cn/api/paas/v4', 'glm-4.7-flash'),
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

// ---------------------------------------------------------------------------

class _AutoSelectSection extends StatefulWidget {
  const _AutoSelectSection();

  @override
  State<_AutoSelectSection> createState() => _AutoSelectSectionState();
}

class _AutoSelectSectionState extends State<_AutoSelectSection> {
  final _apps = TextEditingController();
  bool _dirty = false;

  String get _current =>
      Settings.instance.autoSelectAllApps ? Settings.instance.autoSelectExclude : Settings.instance.autoSelectApps;

  @override
  void initState() {
    super.initState();
    _apps.text = _current;
  }

  @override
  void dispose() {
    _apps.dispose();
    super.dispose();
  }

  void _save() {
    final s = Settings.instance;
    if (s.autoSelectAllApps) {
      s.autoSelectExclude = _apps.text;
    } else {
      s.autoSelectApps = _apps.text;
    }
    setState(() => _dirty = false);
    toast(context, '已保存');
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: Settings.instance, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final s = Settings.instance;
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    return _Section(
      title: '划词翻译',
      subtitle: '选中文字后自动翻译，热键 ${s.hotkey.label} 始终可用',
      children: [
        SwitchListTile(
          title: const Text('选中文字自动翻译'),
          subtitle: const Text('拖选或双击选中文字后触发。主窗口打开时不打扰。'),
          value: s.autoSelect,
          onChanged: (v) => s.autoSelect = v,
        ),
        if (s.autoSelect) ...[
          ListTile(
            title: const Text('选中后'),
            trailing: SegmentedButton<AutoSelectMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: AutoSelectMode.icon, label: Text('显示小图标')),
                ButtonSegment(value: AutoSelectMode.popup, label: Text('直接弹出')),
              ],
              selected: {s.autoSelectMode},
              onSelectionChanged: (v) => s.autoSelectMode = v.first,
            ),
          ),
          ListTile(
            title: const Text('生效范围'),
            trailing: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('列表中的程序')),
                ButtonSegment(value: true, label: Text('所有程序')),
              ],
              selected: {s.autoSelectAllApps},
              onSelectionChanged: (v) {
                if (_dirty) _save();
                s.autoSelectAllApps = v.first;
                setState(() => _apps.text = _current);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                s.autoSelectAllApps
                    ? '排除这些程序（每行一个 exe 文件名）。终端（CMD、PowerShell、Windows Terminal 等）始终排除。'
                    : '只在这些程序中自动划词（每行一个 exe 文件名）。默认包含常用浏览器、PDF 阅读器和 Office。',
                style: hint,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _apps,
                minLines: 4,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                onChanged: (_) => setState(() => _dirty = true),
              ),
              const SizedBox(height: 8),
              Text(
                '原理：选中后向该程序发送 Ctrl+C 读取文字，再恢复原来的剪贴板内容。'
                '剪贴板里是图片或文件时会自动跳过；开启了 Windows 剪贴板历史（Win+V）的话，划过的文字会出现在历史里。',
                style: hint,
              ),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  onPressed: () => setState(() {
                    _apps.text = s.autoSelectAllApps ? 'Code.exe\n' : defaultAutoSelectApps;
                    _dirty = true;
                  }),
                  child: const Text('恢复默认'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _dirty ? _save : null, child: const Text('保存')),
              ]),
            ]),
          ),
        ],
      ],
    );
  }
}
