import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/app_state.dart';
import '../platform/desktop.dart';
import '../services/backend.dart';
import 'app.dart';
import 'history_page.dart';
import 'lookup_view.dart';
import 'ocr_page.dart';
import 'pdf_page.dart';
import 'settings_page.dart';
import 'wordbook_page.dart';

/// 主框架：宽屏用侧边导航，窄屏（手机）用底部导航；Windows 迷你弹窗只显示查词。
class Shell extends StatelessWidget {
  const Shell({super.key});

  static const _all = [
    (AppPage.lookup, Icons.translate_outlined, Icons.translate, '查词翻译'),
    (AppPage.ocr, Icons.document_scanner_outlined, Icons.document_scanner, '截图识别'),
    (AppPage.pdf, Icons.picture_as_pdf_outlined, Icons.picture_as_pdf, 'PDF 翻译'),
    (AppPage.wordbook, Icons.star_outline, Icons.star, '生词本'),
    (AppPage.history, Icons.history_outlined, Icons.history, '历史'),
    (AppPage.settings, Icons.settings_outlined, Icons.settings, '设置'),
  ];

  /// 截图识别和 PDF 翻译依赖本地后端，只在 Windows 上提供。
  static List<(AppPage, IconData, IconData, String)> get _destinations => [
        for (final d in _all)
          if (Backend.supported || (d.$1 != AppPage.ocr && d.$1 != AppPage.pdf)) d,
      ];

  static Widget _pageFor(AppPage p) => switch (p) {
        AppPage.lookup => const LookupView(),
        AppPage.ocr => const OcrPage(),
        AppPage.pdf => const PdfPage(),
        AppPage.wordbook => const WordbookPage(),
        AppPage.history => const HistoryPage(),
        AppPage.settings => const SettingsPage(),
      };

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final dests = _destinations;
    final pages = [for (final d in dests) _pageFor(d.$1)];
    return ValueListenableBuilder<WinView>(
      valueListenable: state.view,
      builder: (context, view, _) {
        if (view == WinView.icon) return const _SelectionIcon();
        if (view == WinView.mini) return const _MiniShell();
        return ValueListenableBuilder<AppPage>(
          valueListenable: state.page,
          builder: (context, page, _) {
            final tab = dests.indexWhere((d) => d.$1 == page).clamp(0, dests.length - 1);
            void select(int i) => state.page.value = dests[i].$1;
            final body = IndexedStack(index: tab, children: pages);
            final wide = MediaQuery.sizeOf(context).width >= 720;
            if (wide) {
              return Scaffold(
                body: Row(children: [
                  NavigationRail(
                    selectedIndex: tab,
                    onDestinationSelected: select,
                    labelType: NavigationRailLabelType.all,
                    leading: Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset('assets/icons/app_icon.png', width: 40, height: 40),
                      ),
                    ),
                    destinations: [
                      for (final d in dests)
                        NavigationRailDestination(icon: Icon(d.$2), selectedIcon: Icon(d.$3), label: Text(d.$4)),
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
                onDestinationSelected: select,
                height: 64,
                destinations: [
                  for (final d in dests)
                    NavigationDestination(icon: Icon(d.$2), selectedIcon: Icon(d.$3), label: d.$4),
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
              // 没有系统标题栏，按住这里拖动窗口。
              Expanded(
                child: DragToMoveArea(
                  child: SizedBox.expand(
                    child: Row(children: [
                      const SizedBox(width: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.asset('assets/icons/app_icon.png', width: 18, height: 18),
                      ),
                      const SizedBox(width: 6),
                      Text('灵译', style: TextStyle(fontWeight: FontWeight.w600, color: scheme.primary)),
                    ]),
                  ),
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: state.pinned,
                builder: (context, pinned, _) => IconButton(
                  tooltip: pinned ? '取消钉住' : '钉住：失去焦点不隐藏，可连续划词',
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

/// 选中文字后出现在鼠标旁的小图标：点击或悬停片刻即展开翻译。
class _SelectionIcon extends StatefulWidget {
  const _SelectionIcon();

  @override
  State<_SelectionIcon> createState() => _SelectionIconState();
}

class _SelectionIconState extends State<_SelectionIcon> {
  bool _hover = false;
  Timer? _hoverTimer;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          setState(() => _hover = true);
          Desktop.instance.holdIcon(true);
          // 悬停 0.5 秒也会展开，和有道的习惯一致。
          _hoverTimer = Timer(const Duration(milliseconds: 500), Desktop.instance.expandIcon);
        },
        onExit: (_) {
          setState(() => _hover = false);
          _hoverTimer?.cancel();
          Desktop.instance.holdIcon(false);
        },
        child: GestureDetector(
          onTap: () {
            _hoverTimer?.cancel();
            Desktop.instance.expandIcon();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            // 铺满整个窗口（Windows 11 会自动给窗口加圆角）。
            color: _hover ? const Color(0xFF1548D6) : brandBlue,
            alignment: Alignment.center,
            child: const Text(
              '译',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, height: 1),
            ),
          ),
        ),
      ),
    );
  }
}
