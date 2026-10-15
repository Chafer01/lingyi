import 'dart:io';

import 'package:flutter/material.dart';

import '../services/settings.dart';
import 'shell.dart';

/// 品牌色，与图标一致。
const brandBlue = Color(0xFF1E5EFF);
const brandAmber = Color(0xFFFFC400);

class LingyiApp extends StatelessWidget {
  const LingyiApp({super.key});

  ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: brandBlue, brightness: b);
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      // Windows 上默认字体对中文渲染偏细，指定雅黑更清晰。
      fontFamily: Platform.isWindows ? 'Microsoft YaHei UI' : null,
      visualDensity: Platform.isWindows ? VisualDensity.compact : VisualDensity.standard,
    );
    return base.copyWith(
      scaffoldBackgroundColor: b == Brightness.light ? const Color(0xFFF5F7FB) : scheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: b == Brightness.light ? Colors.white : scheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: b == Brightness.light ? Colors.white : scheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Settings.instance,
      builder: (context, _) => MaterialApp(
        title: '灵译',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: Settings.instance.themeMode,
        home: const Shell(),
      ),
    );
  }
}
