// 只在 Windows 上运行（编译工作流的 Windows 任务里执行）：验证划词取词时剪贴板能完整备份和恢复，
// 尤其是图片（以前剪贴板里是截图时自动划词会直接跳过）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingyi/platform/win_input.dart';

const _cfUnicodeText = 13;
const _cfDib = 8;

/// 2×2 的 32 位 DIB（BITMAPINFOHEADER + 像素）。
Uint8List _dib() {
  final b = ByteData(40 + 16);
  b.setUint32(0, 40, Endian.little); // biSize
  b.setInt32(4, 2, Endian.little); // biWidth
  b.setInt32(8, 2, Endian.little); // biHeight
  b.setUint16(12, 1, Endian.little); // biPlanes
  b.setUint16(14, 32, Endian.little); // biBitCount
  b.setUint32(20, 16, Endian.little); // biSizeImage
  for (var i = 0; i < 16; i++) {
    b.setUint8(40 + i, (i * 37) & 0xFF);
  }
  return b.buffer.asUint8List();
}

Uint8List _utf16z(String s) {
  final out = ByteData((s.length + 1) * 2);
  for (var i = 0; i < s.length; i++) {
    out.setUint16(i * 2, s.codeUnitAt(i), Endian.little);
  }
  return out.buffer.asUint8List();
}

Uint8List? _get(ClipboardSnapshot s, int fmt) {
  for (final (f, d) in s.items) {
    if (f == fmt) return d;
  }
  return null;
}

void main() {
  final skip = Platform.isWindows ? null : '只在 Windows 上运行';

  test('图片放进剪贴板 → 备份 → 被文字覆盖 → 恢复后图片原样回来', () {
    final dib = _dib();
    expect(WinInput.restoreClipboard(ClipboardSnapshot([(_cfDib, dib)])), isTrue);
    expect(WinInput.clipboardHasNonText, isTrue);

    final snap = WinInput.saveClipboard();
    expect(snap, isNotNull);
    expect(_get(snap!, _cfDib)!.sublist(0, dib.length), dib);

    // 模拟取词时 Ctrl+C 把选中的文字写进剪贴板
    final seq = WinInput.clipboardSequence;
    expect(WinInput.restoreClipboard(ClipboardSnapshot([(_cfUnicodeText, _utf16z('beam squint'))])), isTrue);
    expect(WinInput.clipboardSequence, isNot(seq));
    expect(WinInput.clipboardHasNonText, isFalse);

    // 恢复
    expect(WinInput.restoreClipboard(snap), isTrue);
    final after = WinInput.saveClipboard()!;
    expect(_get(after, _cfDib)!.sublist(0, dib.length), dib);
    expect(_get(after, _cfUnicodeText), isNull);
    expect(WinInput.clipboardHasNonText, isTrue);
  }, skip: skip);

  test('文字和多种格式一起恢复', () {
    final text = _utf16z('radome 天线罩');
    expect(WinInput.restoreClipboard(ClipboardSnapshot([(_cfUnicodeText, text), (_cfDib, _dib())])), isTrue);
    final snap = WinInput.saveClipboard()!;
    expect(WinInput.restoreClipboard(ClipboardSnapshot([(_cfUnicodeText, _utf16z('x'))])), isTrue);
    expect(WinInput.restoreClipboard(snap), isTrue);
    final after = WinInput.saveClipboard()!;
    expect(_get(after, _cfUnicodeText)!.sublist(0, text.length), text);
    expect(_get(after, _cfDib), isNotNull);
  }, skip: skip);

  test('超过大小上限时不备份', () {
    expect(WinInput.restoreClipboard(ClipboardSnapshot([(_cfDib, _dib())])), isTrue);
    expect(WinInput.saveClipboard(maxBytes: 8), isNull);
  }, skip: skip);
}
