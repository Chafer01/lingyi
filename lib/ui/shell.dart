import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/app_state.dart';
import '../platform/desktop.dart';
import 'history_page.dart';
import 'lookup_view.dart';
import 'settings_page.dart';
import 'wordbook_page.dart';

/// 主框架：宽屏用侧边导航，窄屏（手机）用底部导航；Windows 迷你弹窗只显示查词。
class Shell extends StatelessWidget {
  const Shell({super.key});

  static const _destinations = [
    (Icons.translate_outlined, Icons.translate, '查词翻译'),
    (Icons.star_outline, Icons.star, '生词本'),
    (Icons.history_outlined, Icons.history, '历史'),
    (Icons.settings_outlined, Icons.settings, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: state.mini,
      builder: (context, mini, _) {
        if (mini) return const _MiniShell();
        return ValueListenableBuilder<int>(
          valueListenable: state.tab,
          builder: (context, tab, _) {
            final pages = const [LookupView(), WordbookPage(), HistoryPage(), SettingsPage()];
            final body = IndexedStack(index: tab, children: pages);
            final wide = MediaQuery.sizeOf(context).width >= 720;
            if (wide) {
              return Scaffold(
                body: Row(children: [
                  NavigationRail(
                    selectedIndex: tab,
                    onDestinationSelected: (i) => state.tab.value = i,
                    labelType: NavigationRailLabelType.all,
                    leading: Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset('assets/icons/app_icon.png', width: 40, height: 40),
                      ),
                    ),
                    destinations: [
                      for (final d in _destinations)
                        NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(d.$3)),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: body),
                ]),
              );
            }
            return Scaffold(
              body: SafeArea(bottom: false, child: body),
              bottomNavigationBar: NavigationBar(
                selectedIndex: tab,
                onDestinationSelected: (i) => state.tab.value = i,
                height: 64,
                destinations: [
                  for (final d in _destinations)
                    NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Windows 划词弹出的迷你窗口。
class _MiniShell extends StatelessWidget {
  const _MiniShell();

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final scheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Desktop.instance.hide()},
      child: Scaffold(
        body: Column(children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            child: Row(children: [
              const SizedBox(width: 8),
              Text('灵译', style: TextStyle(fontWeight: FontWeight.w600, color: scheme.primary)),
              const Spacer(),
              ValueListenableBuilder<bool>(
                valueListenable: state.pinned,
                builder: (context, pinned, _) => IconButton(
                  tooltip: pinned ? '取消钉住' : '钉住（失去焦点时不隐藏）',
                  iconSize: 18,
                  isSelected: pinned,
                  icon: const Icon(Icons.push_pin_outlined),
                  selectedIcon: const Icon(Icons.push_pin),
                  onPressed: () => state.pinned.value = !pinned,
                ),
              ),
              IconButton(
                tooltip: '打开主窗口',
                iconSize: 18,
                icon: const Icon(Icons.open_in_full),
                onPressed: () => Desktop.instance.showMain(),
              ),
              IconButton(
                tooltip: '隐藏（Esc）',
                iconSize: 18,
                icon: const Icon(Icons.close),
                onPressed: () => Desktop.instance.hide(),
              ),
            ]),
          ),
          const Expanded(child: LookupView(compact: true)),
        ]),
      ),
    );
  }
}
