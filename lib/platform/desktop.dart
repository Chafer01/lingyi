import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../services/settings.dart';
import '../util/text_utils.dart';
import 'app_state.dart';
import 'win_input.dart';

/// Windows 桌面集成：托盘、全局热键划词、迷你弹窗、剪贴板监听、关闭到托盘。
class Desktop with WindowListener, TrayListener {
  Desktop._();
  static final Desktop instance = Desktop._();

  static bool get supported => Platform.isWindows;

  static const _mainSize = Size(980, 700);
  static const _miniSize = Size(440, 560);

  final _state = AppState.instance;
  final _settings = Settings.instance;

  Timer? _clipTimer;
  String? _lastClip;
  bool _capturing = false;
  DateTime _shownAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> init() async {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: _mainSize,
      minimumSize: Size(380, 420),
      center: true,
      title: '灵译',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    await trayManager.setIcon('assets/icons/tray.ico');
    await trayManager.setToolTip('灵译');
    trayManager.addListener(this);
    await _updateTrayMenu();

    await hotKeyManager.unregisterAll();
    await applyHotkey();
    _applyClipboardWatch();
    _settings.addListener(_onSettingsChanged);
  }

  int _lastHotkey = -1;
  bool _lastClipWatch = false;

  void _onSettingsChanged() {
    if (_settings.hotkeyIndex != _lastHotkey) {
      applyHotkey();
      _updateTrayMenu();
    }
    if (_settings.clipboardWatch != _lastClipWatch) _applyClipboardWatch();
  }

  // ---------------- 热键 ----------------

  HotKey? _hotKey;

  Future<void> applyHotkey() async {
    _lastHotkey = _settings.hotkeyIndex;
    if (_hotKey != null) {
      await hotKeyManager.unregister(_hotKey!);
      _hotKey = null;
    }
    final p = _settings.hotkey;
    final key = _letterKey(p.key);
    if (key == null) return;
    final hk = HotKey(
      key: key,
      modifiers: [
        if (p.ctrl) HotKeyModifier.control,
        if (p.alt) HotKeyModifier.alt,
        if (p.shift) HotKeyModifier.shift,
      ],
      scope: HotKeyScope.system,
    );
    try {
      await hotKeyManager.register(hk, keyDownHandler: (_) => captureSelection());
      _hotKey = hk;
    } catch (_) {
      // 热键被其他程序占用时注册会失败，用户可在设置中更换。
    }
  }

  static PhysicalKeyboardKey? _letterKey(String letter) => const {
        'D': PhysicalKeyboardKey.keyD,
        'Q': PhysicalKeyboardKey.keyQ,
        'X': PhysicalKeyboardKey.keyX,
        'T': PhysicalKeyboardKey.keyT,
      }[letter];

  /// 划词：模拟 Ctrl+C 读取选中文字，然后在鼠标旁弹出迷你窗口。
  Future<void> captureSelection() async {
    if (_capturing) return;
    _capturing = true;
    try {
      final old = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      const sentinel = '⁣lingyi⁣';
      await Clipboard.setData(const ClipboardData(text: sentinel));

      // 等用户松开热键的修饰键（最多 400ms），这样发送的就是干净的 Ctrl+C。
      for (var i = 0; i < 20 && WinInput.anyModifierDown; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      WinInput.sendCopy();

      String? selected;
      for (var i = 0; i < 25; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        if (t != null && t != sentinel) {
          selected = t;
          break;
        }
      }
      // 恢复用户原来的剪贴板内容。
      await Clipboard.setData(ClipboardData(text: old ?? ''));
      _lastClip = old;

      await showMini(selected?.trim() ?? '');
    } finally {
      _capturing = false;
    }
  }

  // ---------------- 剪贴板监听 ----------------

  void _applyClipboardWatch() {
    _lastClipWatch = _settings.clipboardWatch;
    _clipTimer?.cancel();
    _clipTimer = null;
    if (!_settings.clipboardWatch) return;
    Clipboard.getData(Clipboard.kTextPlain).then((d) => _lastClip = d?.text);
    _clipTimer = Timer.periodic(const Duration(milliseconds: 800), (_) async {
      if (_capturing) return;
      final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (t == null || t == _lastClip) return;
      _lastClip = t;
      final s = t.trim();
      // 只处理以英文为主、长度适中的文字，避免复制代码或大段内容时频繁弹窗。
      if (s.isEmpty || s.length > 1500 || detectLang(s) != Lang.en) return;
      if (await windowManager.isFocused()) return; // 在灵译里复制的不处理
      await showMini(s);
    });
  }

  // ---------------- 窗口模式 ----------------

  /// 在鼠标附近显示迷你窗口并查询 [text]（为空时只显示输入框）。
  Future<void> showMini(String text) async {
    final ratio = PlatformDispatcher.instance.views.first.devicePixelRatio;
    final (cx, cy) = WinInput.cursorPos();
    final (vx, vy, vw, vh) = WinInput.virtualScreen();
    // 转成逻辑像素，并保证窗口不超出屏幕。
    var x = cx / ratio + 16;
    var y = cy / ratio + 16;
    final right = (vx + vw) / ratio, bottom = (vy + vh) / ratio;
    if (x + _miniSize.width > right) x = cx / ratio - _miniSize.width - 16;
    if (y + _miniSize.height > bottom) y = bottom - _miniSize.height - 48;
    x = x.clamp(vx / ratio, right - _miniSize.width).toDouble();
    y = y.clamp(vy / ratio, bottom - _miniSize.height).toDouble();

    if (!_state.mini.value) {
      _state.mini.value = true;
      await windowManager.setMinimumSize(const Size(320, 300));
      await windowManager.setSkipTaskbar(true);
      await windowManager.setSize(_miniSize);
    }
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setPosition(Offset(x, y));
    _shownAt = DateTime.now();
    await windowManager.show();
    await windowManager.focus();
    _state.push(text);
  }

  /// 从迷你窗口恢复为普通主窗口。
  Future<void> showMain() async {
    if (_state.mini.value) {
      _state.mini.value = false;
      _state.pinned.value = false;
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setMinimumSize(const Size(380, 420));
      await windowManager.setSize(_mainSize);
      await windowManager.center();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hide() => windowManager.hide();

  Future<void> quit() async {
    _clipTimer?.cancel();
    await hotKeyManager.unregisterAll();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowBlur() {
    // 迷你窗口失去焦点时自动隐藏（钉住时除外）。刚弹出时的短暂失焦忽略掉。
    if (_state.mini.value &&
        !_state.pinned.value &&
        DateTime.now().difference(_shownAt) > const Duration(milliseconds: 600)) {
      windowManager.hide();
    }
  }

  @override
  void onWindowClose() async {
    if (_settings.closeToTray) {
      await windowManager.hide();
    } else {
      await quit();
    }
  }

  // ---------------- 托盘 ----------------

  Future<void> _updateTrayMenu() async {
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: '打开灵译'),
      MenuItem(key: 'lookup', label: '划词翻译（${_settings.hotkey.label}）'),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: '退出'),
    ]));
  }

  @override
  void onTrayIconMouseDown() => showMain();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showMain();
      case 'lookup':
        showMini('');
      case 'exit':
        quit();
    }
  }
}
