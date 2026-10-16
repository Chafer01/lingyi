import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../services/backend.dart';
import '../services/settings.dart';
import '../services/translate/engine.dart';
import '../services/vision_ocr.dart';
import '../util/text_utils.dart';
import 'app_state.dart';
import 'screen_capture.dart';
import 'win_input.dart';

/// Windows 桌面集成：托盘、全局热键、自动划词（小图标/直接弹出）、迷你弹窗、剪贴板监听、关闭到托盘。
class Desktop with WindowListener, TrayListener {
  Desktop._();
  static final Desktop instance = Desktop._();

  static bool get supported => Platform.isWindows;

  static const _mainSize = Size(980, 700);
  static const _mainMin = Size(380, 420);
  static const _miniSize = Size(440, 560);
  static const _miniMin = Size(320, 260);
  static const _iconSize = Size(40, 40);

  /// 终端类窗口：Ctrl+C 在这里是“中断程序”，任何情况下都不自动取词。
  static const _terminalExe = {
    'cmd.exe', 'powershell.exe', 'pwsh.exe', 'windowsterminal.exe', 'conhost.exe',
    'openconsole.exe', 'wsl.exe', 'bash.exe', 'mintty.exe', 'putty.exe', 'kitty.exe',
    'wezterm-gui.exe', 'alacritty.exe', 'tabby.exe', 'mobaxterm.exe', 'xshell.exe',
  };
  static const _terminalClass = {
    'consolewindowclass', 'cascadia_hosting_window_class', 'pseudoconsolewindow',
    'mintty', 'puttyclass', 'virtualconsoleclass',
  };

  final _state = AppState.instance;
  final _settings = Settings.instance;

  bool _capturing = false;
  DateTime _shownAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> init() async {
    await windowManager.ensureInitialized();
    const options = WindowOptions(size: _mainSize, minimumSize: _mainMin, center: true, title: '灵译');
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
    await _applyHotkey();
    await _applyOcrHotkey();
    _applyClipboardWatch();
    _applyAutoSelect();
    _settings.addListener(_onSettingsChanged);
  }

  int _lastHotkey = -1;
  int _lastOcrHotkey = -1;
  bool _lastClipWatch = false;
  bool _lastAutoSelect = false;

  void _onSettingsChanged() {
    if (_settings.hotkeyIndex != _lastHotkey) {
      _applyHotkey();
      _updateTrayMenu();
    }
    if (_settings.ocrHotkeyIndex != _lastOcrHotkey) {
      _applyOcrHotkey();
      _updateTrayMenu();
    }
    if (_settings.clipboardWatch != _lastClipWatch) _applyClipboardWatch();
    if (_settings.autoSelect != _lastAutoSelect) {
      _applyAutoSelect();
      _updateTrayMenu();
    }
  }

  // ---------------------------------------------------------------------------
  // 取选中文字
  // ---------------------------------------------------------------------------

  /// 向前台程序发送 Ctrl+C 取得选中文字，之后把剪贴板恢复原样（包括图片、文件等非文字内容）。
  /// 通过剪贴板序号判断复制是否真的发生：没有选中内容时返回 null，且不改动剪贴板。
  Future<String?> _copySelection({required bool waitForModifiers}) async {
    if (_capturing) return null;
    _capturing = true;
    try {
      // 先完整备份剪贴板。以前剪贴板里是图片（例如刚截过图）时自动划词会直接跳过，
      // 表现为“必须先按一次热键才能划词”——热键把选中的文字复制进去后，剪贴板才变回文字。
      final snap = WinInput.saveClipboard();
      final oldText = snap == null ? (await Clipboard.getData(Clipboard.kTextPlain))?.text : null;
      final seq = WinInput.clipboardSequence;

      if (waitForModifiers) {
        // 等用户松开热键的修饰键（最多 400ms），这样发送的就是干净的 Ctrl+C。
        for (var i = 0; i < 20 && WinInput.anyModifierDown; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      WinInput.sendCopy();

      String? got;
      for (var i = 0; i < 25; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (WinInput.clipboardSequence != seq) {
          // 有的程序分几次写入剪贴板，稍等一下再读。
          await Future<void>.delayed(const Duration(milliseconds: 30));
          got = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
          break;
        }
      }
      if (WinInput.clipboardSequence != seq) {
        if (snap != null) {
          WinInput.restoreClipboard(snap);
        } else if (oldText != null) {
          await Clipboard.setData(ClipboardData(text: oldText)); // 备份失败（内容太大）时至少恢复文字
        }
      }
      _lastClip = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      return got;
    } finally {
      _capturing = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 热键
  // ---------------------------------------------------------------------------

  HotKey? _hotKey;

  Future<void> _applyHotkey() async {
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
      await hotKeyManager.register(hk, keyDownHandler: (_) => _onHotkey());
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
        'S': PhysicalKeyboardKey.keyS,
        'W': PhysicalKeyboardKey.keyW,
      }[letter];

  // ---- 截图识别热键 ----

  HotKey? _ocrHotKey;

  Future<void> _applyOcrHotkey() async {
    _lastOcrHotkey = _settings.ocrHotkeyIndex;
    if (_ocrHotKey != null) {
      await hotKeyManager.unregister(_ocrHotKey!);
      _ocrHotKey = null;
    }
    final p = _settings.ocrHotkey;
    final key = _letterKey(p.key);
    if (key == null) return; // “关闭”
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
      await hotKeyManager.register(hk, keyDownHandler: (_) => snipTranslate());
      _ocrHotKey = hk;
    } catch (_) {}
  }

  bool _snipping = false;

  /// 截图翻译：调出系统截图 → 后端识别文字 → 在鼠标旁的迷你窗口里翻译。
  /// 识别失败时打开主窗口的“识别”页显示原因。
  Future<void> snipTranslate() async {
    if (_snipping) {
      // 上一次截图还在等待（可能被 Esc 取消了）：重新打开截图界面，由上一次调用接收结果。
      await ScreenCapture.snip();
      return;
    }
    _snipping = true;
    try {
      // 提前启动后端，和用户框选并行。
      final warmup = Backend.instance.ensureStarted().catchError((Object _) {});
      if (!await ScreenCapture.snip()) return;
      await warmup;
      try {
        String? note;
        // 智能识别：视觉大模型识别文字和公式；不可用时改用本地文字识别。
        if (_settings.ocrMode == 'smart' && VisionOcr.instance.configured) {
          final img = await Backend.instance.ocrClipboard(mode: 'none');
          if (img.image != null) {
            try {
              final v = await VisionOcr.instance.recognize(img.image!);
              _state.ocrIncoming.value = OcrIncoming(result: img, reply: v);
              if (v.text.trim().isEmpty) {
                _state.ocrIncoming.value = OcrIncoming(result: img, error: '没有识别到内容');
                await _showPage(AppPage.ocr);
                return;
              }
              await showMini(v.text.trim());
              return;
            } on TranslateException catch (e) {
              note = '智能识别不可用，已改用本地文字识别（公式无法识别）。原因：${e.message}';
            }
          }
        }
        final r = await Backend.instance.ocrClipboard();
        _state.ocrIncoming.value = OcrIncoming(result: r, note: note);
        if (r.text.trim().isEmpty) {
          _state.ocrIncoming.value = OcrIncoming(error: '没有识别到文字');
          await _showPage(AppPage.ocr);
          return;
        }
        await showMini(r.text.trim());
      } catch (e) {
        _state.ocrIncoming.value = OcrIncoming(error: '$e');
        await _showPage(AppPage.ocr);
      }
    } finally {
      _snipping = false;
    }
  }

  Future<void> _showPage(AppPage page) async {
    await showMain();
    _state.page.value = page;
  }

  Future<void> _onHotkey() async {
    final fg = WinInput.foreground();
    // 在灵译自己的窗口里按热键只聚焦输入框；在终端里不发送 Ctrl+C（那是“中断程序”）。
    final skip = fg.pid == WinInput.currentPid || _isTerminal(fg);
    final text = skip ? null : await _copySelection(waitForModifiers: true);
    await showMini(text?.trim() ?? '');
  }

  // ---------------------------------------------------------------------------
  // 自动划词：轮询鼠标左键，识别“拖选”和“双击选词”
  // ---------------------------------------------------------------------------

  Timer? _mouseTimer;
  bool _wasDown = false;
  int _downX = 0, _downY = 0;
  int _lastUpX = -9999, _lastUpY = -9999;
  DateTime _lastUpAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastAutoText = '';
  DateTime _lastAutoAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _dblMs = 500;

  void _applyAutoSelect() {
    _lastAutoSelect = _settings.autoSelect;
    _mouseTimer?.cancel();
    _mouseTimer = null;
    if (!_settings.autoSelect) return;
    _dblMs = WinInput.doubleClickMs.clamp(200, 900);
    _wasDown = WinInput.leftButtonDown;
    _mouseTimer = Timer.periodic(const Duration(milliseconds: 30), (_) => _pollMouse());
  }

  void _pollMouse() {
    final down = WinInput.leftButtonDown;
    if (down == _wasDown) return;
    _wasDown = down;
    final (x, y) = WinInput.cursorPos();
    if (down) {
      _downX = x;
      _downY = y;
      // 图标显示时，在别处按下鼠标就收起图标。
      if (_state.view.value == WinView.icon && _iconVisible && !_inIcon(x, y)) hideIcon();
      return;
    }
    final now = DateTime.now();
    final drag = (x - _downX).abs() + (y - _downY).abs() >= 12;
    final dbl = now.difference(_lastUpAt).inMilliseconds <= _dblMs &&
        (x - _lastUpX).abs() < 6 &&
        (y - _lastUpY).abs() < 6;
    _lastUpAt = now;
    _lastUpX = x;
    _lastUpY = y;
    if ((drag || dbl) && !_inIcon(x, y)) _onSelectGesture(x, y);
  }

  Set<String> _exeList(String text) => text
      .split(RegExp(r'[\n,;]'))
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toSet();

  bool _isTerminal(ForegroundInfo fg) =>
      _terminalExe.contains(fg.exe.toLowerCase()) || _terminalClass.contains(fg.windowClass.toLowerCase());

  bool _appAllowed(ForegroundInfo fg) {
    final exe = fg.exe.toLowerCase();
    if (exe.isEmpty) return false; // 取不到进程名（例如管理员权限的程序）时不冒险
    if (_isTerminal(fg)) return false;
    if (_settings.autoSelectAllApps) return !_exeList(_settings.autoSelectExclude).contains(exe);
    return _exeList(_settings.autoSelectApps).contains(exe);
  }

  Future<void> _onSelectGesture(int x, int y) async {
    if (_capturing || !_settings.autoSelect) return;
    final fg = WinInput.foreground();
    // 在灵译自己的窗口里选中文字时不触发（前台进程就是灵译）。
    // 注意：不能用“主窗口可见”来判断——灵译启动后主窗口默认开着，常被浏览器等挡在后面，
    // 那样会导致自动划词一直不生效，直到按一次热键把窗口变成迷你弹窗为止。
    void log(String msg) {
      final t = DateTime.now();
      final hms = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
          '${t.second.toString().padLeft(2, '0')}';
      _state.autoSelectLog.value = '$hms  ${fg.exe.isEmpty ? '未知程序' : fg.exe}：$msg';
    }

    if (fg.pid == 0) return log('取不到前台窗口');
    if (fg.pid == WinInput.currentPid) return; // 灵译自己的窗口，不记录
    if (!_appAllowed(fg)) {
      return log(fg.exe.isEmpty
          ? '取不到程序名（可能是以管理员身份运行的程序），跳过'
          : _isTerminal(fg)
              ? '终端程序，跳过'
              : '不在“生效范围”的程序列表里，跳过（可把 ${fg.exe} 加进列表，或改成“所有程序”）');
    }
    // 剪贴板里的图片、文件等会在取词后原样恢复（见 _copySelection），这里不再跳过。

    // 给目标程序一点时间更新选区；期间若用户又按下鼠标，就放弃这次。
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (WinInput.leftButtonDown) return;

    final text = (await _copySelection(waitForModifiers: false))?.trim();
    if (text == null || text.isEmpty) return log('没有取到选中的文字（该程序可能不支持 Ctrl+C 复制，或没有选中内容）');
    if (text.length > 3000) return log('选中的文字超过 3000 字，跳过');
    final now = DateTime.now();
    if (text == _lastAutoText && now.difference(_lastAutoAt) < const Duration(seconds: 3)) return;
    log('取到 ${text.length} 个字符，已${_settings.autoSelectMode == AutoSelectMode.icon ? '显示小图标' : '弹出翻译'}');
    _lastAutoText = text;
    _lastAutoAt = now;

    // 迷你窗口钉住时，直接在窗口里显示新的结果，方便连续划词。
    if (_state.view.value == WinView.mini && _state.pinned.value && await windowManager.isVisible()) {
      _state.push(text);
      return;
    }
    if (_settings.autoSelectMode == AutoSelectMode.icon) {
      await showIcon(text, x, y);
    } else {
      await showMini(text);
    }
  }

  // ---------------------------------------------------------------------------
  // 剪贴板监听（复制即翻译）
  // ---------------------------------------------------------------------------

  Timer? _clipTimer;
  String? _lastClip;

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

  // ---------------------------------------------------------------------------
  // 窗口形态切换
  // ---------------------------------------------------------------------------

  Future<void> _enter(WinView v) async {
    final from = _state.view.value;
    if (from == v) return;
    _state.view.value = v;
    if (v == WinView.main) {
      _state.pinned.value = false;
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setMinimumSize(_mainMin);
      await windowManager.setSize(_mainSize);
      await windowManager.center();
      return;
    }
    if (from == WinView.main) {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
      await windowManager.setSkipTaskbar(true);
    }
    await windowManager.setAlwaysOnTop(true);
    final size = v == WinView.icon ? _iconSize : _miniSize;
    await windowManager.setMinimumSize(v == WinView.icon ? _iconSize : _miniMin);
    await windowManager.setSize(size);
  }

  /// 计算靠近鼠标、且不超出屏幕的窗口位置（逻辑像素）。
  Offset _nearCursor(int cx, int cy, Size size, {double gap = 16}) {
    final ratio = PlatformDispatcher.instance.views.first.devicePixelRatio;
    final (vx, vy, vw, vh) = WinInput.virtualScreen();
    final left = vx / ratio, top = vy / ratio;
    final right = (vx + vw) / ratio, bottom = (vy + vh) / ratio;
    var x = cx / ratio + gap;
    var y = cy / ratio + gap;
    if (x + size.width > right) x = cx / ratio - size.width - gap;
    if (y + size.height > bottom) y = bottom - size.height - 48;
    return Offset(
      x.clamp(left, right - size.width).toDouble(),
      y.clamp(top, bottom - size.height).toDouble(),
    );
  }

  /// 在鼠标附近显示迷你窗口并查询 [text]（为空时只显示输入框）。
  Future<void> showMini(String text) async {
    _iconTimer?.cancel();
    _iconVisible = false;
    final (cx, cy) = WinInput.cursorPos();
    await _enter(WinView.mini);
    await windowManager.setPosition(_nearCursor(cx, cy, _miniSize));
    _shownAt = DateTime.now();
    await windowManager.show();
    await windowManager.focus();
    _state.push(text);
  }

  // ---- 小图标 ----

  Timer? _iconTimer;
  bool _iconVisible = false;
  String _iconText = '';

  /// 图标的位置（物理像素），用于判断鼠标是否点在图标上。
  Rect _iconRect = Rect.zero;

  bool _inIcon(int x, int y) => _iconVisible && _iconRect.inflate(4).contains(Offset(x.toDouble(), y.toDouble()));

  Future<void> showIcon(String text, int cx, int cy) async {
    _iconText = text;
    await _enter(WinView.icon);
    final pos = _nearCursor(cx, cy, _iconSize, gap: 10);
    await windowManager.setPosition(pos);
    final ratio = PlatformDispatcher.instance.views.first.devicePixelRatio;
    _iconRect = Rect.fromLTWH(pos.dx * ratio, pos.dy * ratio, _iconSize.width * ratio, _iconSize.height * ratio);
    // 不抢焦点，用户可以继续在原程序里操作。
    await windowManager.show(inactive: true);
    _iconVisible = true;
    _iconTimer?.cancel();
    _iconTimer = Timer(const Duration(seconds: 4), hideIcon);
  }

  /// 鼠标悬停在图标上时暂停自动收起。
  void holdIcon(bool hovering) {
    _iconTimer?.cancel();
    if (!hovering && _iconVisible) _iconTimer = Timer(const Duration(seconds: 2), hideIcon);
  }

  Future<void> hideIcon() async {
    _iconTimer?.cancel();
    if (!_iconVisible) return;
    _iconVisible = false;
    if (_state.view.value == WinView.icon) await windowManager.hide();
  }

  /// 点击图标：展开为迷你窗口并翻译。
  Future<void> expandIcon() => showMini(_iconText);

  /// 恢复为普通主窗口。
  Future<void> showMain() async {
    _iconTimer?.cancel();
    _iconVisible = false;
    await _enter(WinView.main);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hide() async {
    _iconVisible = false;
    await windowManager.hide();
  }

  Future<void> quit() async {
    await Backend.instance.stop();
    _clipTimer?.cancel();
    _mouseTimer?.cancel();
    _iconTimer?.cancel();
    await hotKeyManager.unregisterAll();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowBlur() {
    // 迷你窗口失去焦点时自动隐藏（钉住时除外）。刚弹出时的短暂失焦忽略掉。
    if (_state.view.value == WinView.mini &&
        !_state.pinned.value &&
        DateTime.now().difference(_shownAt) > const Duration(milliseconds: 600)) {
      windowManager.hide();
    }
  }

  @override
  void onWindowClose() async {
    if (_state.view.value != WinView.main || _settings.closeToTray) {
      await hide();
    } else {
      await quit();
    }
  }

  // ---------------------------------------------------------------------------
  // 托盘
  // ---------------------------------------------------------------------------

  Future<void> _updateTrayMenu() async {
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: '打开灵译'),
      MenuItem(key: 'lookup', label: '划词翻译（${_settings.hotkey.label}）'),
      MenuItem(
        key: 'snip',
        label: _settings.ocrHotkey.key.isEmpty ? '截图翻译' : '截图翻译（${_settings.ocrHotkey.label}）',
      ),
      MenuItem.checkbox(key: 'auto', label: '选中文字自动翻译', checked: _settings.autoSelect),
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
      case 'snip':
        snipTranslate();
      case 'auto':
        _settings.autoSelect = !_settings.autoSelect;
      case 'exit':
        quit();
    }
  }
}
