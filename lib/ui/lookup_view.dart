import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/app_state.dart';
import '../services/dict_service.dart';
import '../services/settings.dart';
import '../services/translate/engine.dart';
import '../services/translate/translate_service.dart';
import '../services/tts.dart';
import '../services/user_db.dart';
import '../util/text_utils.dart';
import 'lookup_controller.dart';
import 'widgets.dart';
import 'word_card.dart';

/// 查词翻译页。[compact] 为 Windows 划词迷你窗口。
class LookupView extends StatelessWidget {
  const LookupView({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = LookupController.instance;
    final pad = compact ? 10.0 : 20.0;
    return Column(children: [
      Padding(
        padding: EdgeInsets.fromLTRB(pad, pad, pad, 8),
        child: _InputBox(compact: compact),
      ),
      Expanded(
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, ?current],
            ),
            child: KeyedSubtree(
              key: ValueKey('${c.mode}-${c.query}'),
              child: _body(context, c, pad),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _body(BuildContext context, LookupController c, double pad) {
    final children = <Widget>[];
    switch (c.mode) {
      case LookupMode.idle:
        return _Idle(compact: compact, pad: pad);
      case LookupMode.typing:
        return _Suggestions(c.suggestions, pad: pad);
      case LookupMode.word:
        children.add(WordCard(result: c.word!, compact: compact));
      case LookupMode.zhWord:
        children.add(_TranslationPanel(c));
        children.add(const SizedBox(height: 12));
        children.add(_ReverseList(c.reverse));
      case LookupMode.sentence:
        final miss = c.word;
        if (miss != null && !miss.found && miss.suggestions.isNotEmpty) {
          children.add(_NotFound(miss));
          children.add(const SizedBox(height: 12));
        }
        children.add(_TranslationPanel(c));
    }
    if (c.mode != LookupMode.idle && c.mode != LookupMode.typing) {
      children.add(const SizedBox(height: 12));
      children.add(_AiExplainCard(c));
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(pad, 4, pad, pad + 8),
      children: children,
    );
  }
}

// ---------------------------------------------------------------------------
// 输入框
// ---------------------------------------------------------------------------

class _InputBox extends StatelessWidget {
  const _InputBox({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = LookupController.instance;
    final scheme = Theme.of(context).colorScheme;
    final desktop = Platform.isWindows;
    final field = TextField(
      controller: c.input,
      focusNode: c.focusNode,
      autofocus: desktop,
      minLines: 1,
      maxLines: compact ? 4 : 6,
      keyboardType: desktop ? TextInputType.multiline : TextInputType.text,
      textInputAction: desktop ? TextInputAction.newline : TextInputAction.search,
      onChanged: c.onTyping,
      onSubmitted: (_) => c.submit(),
      style: TextStyle(fontSize: compact ? 15 : 17),
      decoration: InputDecoration(
        hintText: desktop ? '输入单词或句子，回车查询（Shift+回车换行）' : '输入单词或句子',
        prefixIcon: const Icon(Icons.search),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 10 : 14),
        suffixIcon: ListenableBuilder(
          listenable: c.input,
          builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
            if (c.input.text.isNotEmpty)
              IconButton(tooltip: '清空', icon: const Icon(Icons.close), onPressed: c.clear),
            if (!desktop)
              IconButton(
                tooltip: '粘贴',
                icon: const Icon(Icons.content_paste),
                onPressed: () async {
                  final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
                  if (t != null && t.trim().isNotEmpty) {
                    c.input.text = t.trim();
                    c.submit();
                  }
                },
              ),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: IconButton.filled(
                tooltip: '查询',
                style: IconButton.styleFrom(backgroundColor: scheme.primary),
                icon: const Icon(Icons.arrow_forward),
                onPressed: () => c.submit(),
              ),
            ),
          ]),
        ),
      ),
    );
    if (!desktop) return field;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): () => c.submit(),
        const SingleActivator(LogicalKeyboardKey.numpadEnter): () => c.submit(),
      },
      child: field,
    );
  }
}

// ---------------------------------------------------------------------------
// 空闲：最近查询 + 使用提示
// ---------------------------------------------------------------------------

class _Idle extends StatelessWidget {
  const _Idle({required this.compact, required this.pad});
  final bool compact;
  final double pad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = UserDb.instance.history(limit: compact ? 6 : 12);
    final dict = DictService.instance;
    final tip = Platform.isAndroid
        ? '在任何 App 中选中文字，点菜单里的「灵译查词」即可直接翻译；也可以把文字分享给灵译。'
        : Settings.instance.autoSelect
            ? '在浏览器、PDF、Office 中选中文字，旁边会出现「译」图标，点一下即可翻译；其他程序中按 ${Settings.instance.hotkey.label}。'
            : '在任何程序中选中文字，按 ${Settings.instance.hotkey.label} 即可在鼠标旁弹出翻译。';
    return ListView(padding: EdgeInsets.fromLTRB(pad, 4, pad, pad), children: [
      if (recent.isNotEmpty) ...[
        Text('最近查询', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.outline)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final h in recent)
            ActionChip(
              label: Text(h.text.length > 24 ? '${h.text.substring(0, 24)}…' : h.text),
              onPressed: () => AppState.instance.push(h.text),
            ),
        ]),
        const SizedBox(height: 20),
      ],
      if (!compact)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.lightbulb_outline, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tip, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 6),
                  Text(
                    '离线词库：${dict.editionLabel}（${dict.wordCount} 词）'
                    '${TranslateService.instance.anyReady ? '' : '  ·  翻译引擎尚未配置，请到「设置」填写密钥'}',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                ]),
              ),
            ]),
          ),
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// 联想词
// ---------------------------------------------------------------------------

class _Suggestions extends StatelessWidget {
  const _Suggestions(this.items, {required this.pad});
  final List<WordEntry> items;
  final double pad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 0, pad, pad),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
          itemBuilder: (context, i) {
            final e = items[i];
            return ListTile(
              dense: true,
              title: Text.rich(TextSpan(children: [
                TextSpan(text: e.word, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (e.phonetic.isNotEmpty)
                  TextSpan(
                    text: '  /${e.phonetic}/',
                    style: TextStyle(color: theme.colorScheme.outline, fontSize: 12),
                  ),
              ])),
              subtitle: Text(e.brief, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => LookupController.instance.submit(e.word),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 未收录 / 中文反查
// ---------------------------------------------------------------------------

class _NotFound extends StatelessWidget {
  const _NotFound(this.r);
  final LookupResult r;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('词库未收录「${r.query}」，您要找的是不是：',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in r.suggestions)
              ActionChip(label: Text(e.word), onPressed: () => LookupController.instance.submit(e.word)),
          ]),
        ]),
      ),
    );
  }
}

class _ReverseList extends StatelessWidget {
  const _ReverseList(this.items);
  final List<WordEntry> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text('相关英文单词', style: theme.textTheme.titleSmall),
        ),
        for (final e in items)
          ListTile(
            dense: true,
            title: Text(e.word, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(e.brief, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => LookupController.instance.submit(e.word),
          ),
        const SizedBox(height: 6),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// 多引擎译文
// ---------------------------------------------------------------------------

class _TranslationPanel extends StatelessWidget {
  const _TranslationPanel(this.c);
  final LookupController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (c.jobs.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('没有启用任何翻译引擎，请到「设置」中开启。', style: theme.textTheme.bodyMedium),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (c.glossary.isNotEmpty) ...[
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('术语', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
          for (final e in c.glossary.entries) Pill('${e.key} → ${e.value}', icon: Icons.bookmark_outline),
        ]),
        const SizedBox(height: 10),
      ],
      for (final j in c.jobs) ...[
        _EngineCard(j, source: c.query),
        const SizedBox(height: 10),
      ],
    ]);
  }
}

class _EngineCard extends StatelessWidget {
  const _EngineCard(this.job, {required this.source});
  final EngineJob job;
  final String source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final header = Row(children: [
      Container(
        width: 4,
        height: 14,
        decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(2)),
      ),
      const SizedBox(width: 8),
      Text(job.engine.name, style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
    ]);

    Widget body;
    if (job.future == null) {
      body = Row(children: [
        Expanded(
          child: Text(job.engine.setupHint,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.outline)),
        ),
        TextButton(onPressed: () => AppState.instance.page.value = AppPage.settings, child: const Text('去设置')),
      ]);
    } else {
      body = FutureBuilder<TranslateResult>(
        future: job.future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            );
          }
          if (snap.hasError) {
            final err = snap.error;
            final msg = err is TranslateException ? err.message : '网络错误：$err';
            return Text(msg, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error));
          }
          final text = snap.data!.text;
          final toEnglish = detectLang(source) == Lang.zh;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(text, style: theme.textTheme.bodyLarge?.copyWith(height: 1.55)),
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              IconButton(
                tooltip: '朗读',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.volume_up_outlined),
                onPressed: () => Tts.instance.speak(text, english: toEnglish),
              ),
              IconButton(
                tooltip: '复制',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy_outlined),
                onPressed: () => copyText(context, text),
              ),
            ]),
          ]);
        },
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          header,
          const SizedBox(height: 8),
          Padding(padding: const EdgeInsets.only(right: 8), child: body),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AI 讲解
// ---------------------------------------------------------------------------

class _AiExplainCard extends StatelessWidget {
  const _AiExplainCard(this.c);
  final LookupController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final llm = TranslateService.instance.llm;
    final isWord = c.mode == LookupMode.word;
    if (c.aiExplain == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: Text(isWord ? 'AI 讲解这个词' : 'AI 解析这句话'),
          onPressed: llm.configured
              ? c.requestAiExplain
              : () => toast(context, '请先在设置中配置大模型接口'),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.auto_awesome, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text('AI 讲解', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          ]),
          const SizedBox(height: 10),
          FutureBuilder<String>(
            future: c.aiExplain,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(minHeight: 2),
                );
              }
              if (snap.hasError) {
                return Text('${snap.error}', style: TextStyle(color: theme.colorScheme.error));
              }
              return MiniMarkdown(snap.data ?? '');
            },
          ),
        ]),
      ),
    );
  }
}
