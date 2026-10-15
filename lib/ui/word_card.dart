import 'package:flutter/material.dart';

import '../services/dict_service.dart';
import '../services/tts.dart';
import '../services/user_db.dart';
import '../util/text_utils.dart';
import 'app.dart';
import 'lookup_controller.dart';
import 'widgets.dart';

/// 单词词条卡片：词头、音标、朗读、星级/考试标签、分词性释义、词形变化、英文释义。
class WordCard extends StatelessWidget {
  const WordCard({super.key, required this.result, this.compact = false});
  final LookupResult result;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final e = result.entry!;
    final lemma = result.lemma;
    final forms = parseExchange(e.exchange).where((x) => x.key != '0').toList();
    final tags = parseTags(e.tag);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        child: Padding(
          padding: EdgeInsets.all(compact ? 14 : 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 词头
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: SelectableText(
                  e.word,
                  style: (compact ? theme.textTheme.headlineSmall : theme.textTheme.headlineMedium)
                      ?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface),
                ),
              ),
              _StarButton(entry: e, source: LookupController.instance.query),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (e.phonetic.isNotEmpty)
                Text('/${e.phonetic}/', style: theme.textTheme.bodyLarge?.copyWith(color: scheme.outline)),
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => Tts.instance.speak(e.word),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.volume_up_rounded, size: 22, color: scheme.primary),
                ),
              ),
              if (e.collins > 0) Pill('★' * e.collins, color: const Color(0xFFE0A100)),
              if (e.oxford) const Pill('牛津3000', color: Colors.teal),
              for (final t in tags) Pill(t),
            ]),
            if (result.guessedFrom != null || lemma != null) ...[
              const SizedBox(height: 12),
              _LemmaBanner(result: result),
            ],
            const SizedBox(height: 14),
            // 中文释义（按词性分行）
            for (final line in e.translation.split('\n'))
              if (line.trim().isNotEmpty) _MeaningLine(line),
            if (forms.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final f in forms)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text('${exchangeNames[f.key] ?? f.key} ${f.value}', style: const TextStyle(fontSize: 12)),
                    onPressed: () => LookupController.instance.submit(f.value),
                  ),
              ]),
            ],
            if (e.frq > 0 || e.bnc > 0) ...[
              const SizedBox(height: 10),
              Text(
                [
                  if (e.frq > 0) '当代语料库词频 #${e.frq}',
                  if (e.bnc > 0) 'BNC 词频 #${e.bnc}',
                ].join('   ·   '),
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
            ],
          ]),
        ),
      ),
      if (e.definition.trim().isNotEmpty) ...[
        const SizedBox(height: 10),
        Card(
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            initiallyExpanded: !compact,
            shape: const Border(),
            title: Text('英文释义', style: theme.textTheme.titleSmall),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in e.definition.split('\n'))
                if (line.trim().isNotEmpty) _MeaningLine(line, english: true),
            ],
          ),
        ),
      ],
    ]);
  }
}

class _MeaningLine extends StatelessWidget {
  const _MeaningLine(this.line, {this.english = false});
  final String line;
  final bool english;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = splitPos(line);
    final isDomain = p.key.startsWith('[');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (p.key.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(right: 8, top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: (isDomain ? scheme.tertiary : scheme.primary).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              p.key.replaceAll(RegExp(r'[\[\]]'), ''),
              style: TextStyle(
                fontSize: 12,
                fontStyle: isDomain ? FontStyle.normal : FontStyle.italic,
                color: isDomain ? scheme.tertiary : scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Expanded(
          child: SelectableText(
            p.value,
            style: (english ? theme.textTheme.bodyMedium : theme.textTheme.bodyLarge)?.copyWith(height: 1.5),
          ),
        ),
      ]),
    );
  }
}

class _LemmaBanner extends StatelessWidget {
  const _LemmaBanner({required this.result});
  final LookupResult result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final e = result.entry!;
    final lemma = result.lemma;
    final String text;
    String? target;
    if (lemma != null) {
      final kinds = parseExchange(lemma.exchange)
          .where((x) => x.value.toLowerCase() == e.word.toLowerCase())
          .map((x) => exchangeNames[x.key] ?? '')
          .where((s) => s.isNotEmpty)
          .toSet()
          .join('、');
      text = '${e.word} 是 ${lemma.word} 的${kinds.isEmpty ? '变形' : kinds}：${lemma.brief}';
      target = lemma.word;
    } else {
      text = '未找到「${result.guessedFrom}」，显示可能的原形 ${e.word}';
    }
    return Material(
      color: scheme.secondaryContainer.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: target == null ? null : () => LookupController.instance.submit(target!),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Icon(Icons.call_split, size: 16, color: scheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text, style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 13)),
            ),
            if (target != null) Icon(Icons.chevron_right, size: 18, color: scheme.onSecondaryContainer),
          ]),
        ),
      ),
    );
  }
}

class _StarButton extends StatefulWidget {
  const _StarButton({required this.entry, required this.source});
  final WordEntry entry;

  /// 查词时的原始输入（若是从句子里划词，可作为例句保存）。
  final String source;

  @override
  State<_StarButton> createState() => _StarButtonState();
}

class _StarButtonState extends State<_StarButton> {
  final _db = UserDb.instance;

  @override
  Widget build(BuildContext context) {
    final on = _db.inWordbook(widget.entry.word);
    return IconButton(
      tooltip: on ? '移出生词本' : '加入生词本',
      isSelected: on,
      icon: const Icon(Icons.star_border_rounded),
      selectedIcon: const Icon(Icons.star_rounded, color: brandAmber),
      onPressed: () {
        final e = widget.entry;
        if (on) {
          _db.removeWord(e.word);
        } else {
          final ctx = widget.source.toLowerCase() == e.word.toLowerCase() ? '' : widget.source;
          _db.addWord(e.word, e.phonetic, e.translation.replaceAll('\n', '；'), context: ctx);
          toast(context, '已加入生词本');
        }
        setState(() {});
      },
    );
  }
}
