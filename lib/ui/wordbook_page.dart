import 'package:flutter/material.dart';

import '../platform/app_state.dart';
import '../services/tts.dart';
import '../services/user_db.dart';
import 'widgets.dart';

class WordbookPage extends StatefulWidget {
  const WordbookPage({super.key});

  @override
  State<WordbookPage> createState() => _WordbookPageState();
}

class _WordbookPageState extends State<WordbookPage> {
  String _order = 'added';
  bool _showMeaning = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: UserDb.instance,
      builder: (context, _) {
        final items = UserDb.instance.wordbook(orderBy: _order);
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(children: [
              Text('生词本', style: theme.textTheme.titleLarge),
              const SizedBox(width: 8),
              Text('${items.length} 个', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)),
              const Spacer(),
              IconButton(
                tooltip: _showMeaning ? '隐藏释义（自测）' : '显示释义',
                icon: Icon(_showMeaning ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _showMeaning = !_showMeaning),
              ),
              PopupMenuButton<String>(
                tooltip: '排序',
                icon: const Icon(Icons.sort),
                initialValue: _order,
                onSelected: (v) => setState(() => _order = v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'added', child: Text('按加入时间')),
                  PopupMenuItem(value: 'lookups', child: Text('按查询次数')),
                ],
              ),
              IconButton(
                tooltip: '导出（Anki 可直接导入）',
                icon: const Icon(Icons.ios_share),
                onPressed: items.isEmpty
                    ? null
                    : () async {
                        final f = await UserDb.instance.exportWordbook();
                        if (context.mounted) toast(context, '已导出到 ${f.path}');
                      },
              ),
            ]),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text('查词时点击 ☆ 即可加入生词本',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, i) {
                      final w = items[i];
                      return Card(
                        child: ListTile(
                          title: Text.rich(TextSpan(children: [
                            TextSpan(text: w.word, style: const TextStyle(fontWeight: FontWeight.w700)),
                            if (w.phonetic.isNotEmpty)
                              TextSpan(
                                text: '  /${w.phonetic}/',
                                style: TextStyle(color: theme.colorScheme.outline, fontSize: 12),
                              ),
                          ])),
                          subtitle: _showMeaning
                              ? Text(w.translation, maxLines: 2, overflow: TextOverflow.ellipsis)
                              : Text('查过 ${w.lookups} 次', style: TextStyle(color: theme.colorScheme.outline)),
                          onTap: () => AppState.instance.push(w.word),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              tooltip: '朗读',
                              icon: const Icon(Icons.volume_up_outlined, size: 20),
                              onPressed: () => Tts.instance.speak(w.word),
                            ),
                            IconButton(
                              tooltip: '移出生词本',
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => UserDb.instance.removeWord(w.word),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ]);
      },
    );
  }
}
