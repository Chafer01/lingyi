import 'package:flutter/material.dart';

import '../platform/app_state.dart';
import '../services/user_db.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  static String _when(DateTime t) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    if (t.year == now.year && t.month == now.month && t.day == now.day) return hm;
    return '${t.month}-${t.day} $hm';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: UserDb.instance,
      builder: (context, _) {
        final items = UserDb.instance.history();
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(children: [
              Text('历史', style: theme.textTheme.titleLarge),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('清空'),
                onPressed: items.isEmpty
                    ? null
                    : () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('清空历史记录？'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空')),
                            ],
                          ),
                        );
                        if (ok == true) UserDb.instance.clearHistory();
                      },
              ),
            ]),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text('还没有查询记录',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final h = items[i];
                      return Dismissible(
                        key: ValueKey(h.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                        ),
                        onDismissed: (_) => UserDb.instance.deleteHistory(h.id),
                        child: ListTile(
                          title: Text(h.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(h.result, maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: Text(_when(h.time), style: theme.textTheme.bodySmall),
                          onTap: () => AppState.instance.push(h.text),
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
