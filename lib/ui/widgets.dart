import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 小标签。
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color, this.icon});
  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12, color: c), const SizedBox(width: 3)],
        Text(text, style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

/// 复制到剪贴板并提示。
Future<void> copyText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)));
  }
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// 极简 Markdown 渲染：标题、列表、粗体、行内代码。用于显示 AI 讲解。
class MiniMarkdown extends StatelessWidget {
  const MiniMarkdown(this.text, {super.key});
  final String text;

  List<InlineSpan> _inline(String s, TextStyle base, BuildContext context) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    var last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) spans.add(TextSpan(text: s.substring(last, m.start)));
      if (m.group(1) != null) {
        spans.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700)));
      } else {
        spans.add(TextSpan(
          text: m.group(2),
          style: TextStyle(
            fontFamily: 'monospace',
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        ));
      }
      last = m.end;
    }
    if (last < s.length) spans.add(TextSpan(text: s.substring(last)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium!.copyWith(height: 1.6);
    final children = <Widget>[];
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        children.add(const SizedBox(height: 6));
        continue;
      }
      final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
      final bullet = RegExp(r'^(\s*)[-*•]\s+(.*)$').firstMatch(line);
      final ordered = RegExp(r'^(\s*)(\d+[.)、])\s+(.*)$').firstMatch(line);
      if (h != null) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(h.group(2)!.replaceAll('**', ''),
              style: base.copyWith(fontWeight: FontWeight.w700, fontSize: (base.fontSize ?? 14) + 1)),
        ));
      } else if (bullet != null || ordered != null) {
        final indent = ((bullet ?? ordered)!.group(1)!.length ~/ 2).clamp(0, 3).toDouble() * 14.0;
        final marker = bullet != null ? '•' : ordered!.group(2)!;
        final content = bullet != null ? bullet.group(2)! : ordered!.group(3)!;
        children.add(Padding(
          padding: EdgeInsets.only(left: indent, top: 1, bottom: 1),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 22, child: Text(marker, style: base.copyWith(color: theme.colorScheme.primary))),
            Expanded(child: Text.rich(TextSpan(style: base, children: _inline(content, base, context)))),
          ]),
        ));
      } else {
        children.add(Text.rich(TextSpan(style: base, children: _inline(line, base, context))));
      }
    }
    return SelectionArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}
