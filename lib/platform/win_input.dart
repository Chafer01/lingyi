// Windows 输入相关的少量 user32 调用（通过 dart:ffi，不引入额外依赖）。
// 只在 Windows 上调用；在其他平台上不会加载 user32.dll。
import 'dart:ffi';

import 'package:ffi/ffi.dart';

final class _Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

typedef _KeybdEventC = Void Function(Uint8 vk, Uint8 scan, Uint32 flags, UintPtr extra);
typedef _KeybdEventD = void Function(int vk, int scan, int flags, int extra);
typedef _GetCursorPosC = Int32 Function(Pointer<_Point> p);
typedef _GetCursorPosD = int Function(Pointer<_Point> p);
typedef _IntIntC = Int32 Function(Int32 v);
typedef _IntIntD = int Function(int v);
typedef _AsyncKeyC = Int16 Function(Int32 v);

class WinInput {
  WinInput._();

  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final _keybdEvent = _user32.lookupFunction<_KeybdEventC, _KeybdEventD>('keybd_event');
  static final _getCursorPos = _user32.lookupFunction<_GetCursorPosC, _GetCursorPosD>('GetCursorPos');
  static final _getSystemMetrics = _user32.lookupFunction<_IntIntC, _IntIntD>('GetSystemMetrics');
  static final _getAsyncKeyState = _user32.lookupFunction<_AsyncKeyC, _IntIntD>('GetAsyncKeyState');

  static const _keyUp = 0x0002;
  static const _vkShift = 0x10;
  static const _vkControl = 0x11;
  static const _vkMenu = 0x12; // Alt
  static const _vkLWin = 0x5B;
  static const _vkRWin = 0x5C;
  static const _vkC = 0x43;

  static const _modifiers = [_vkShift, _vkControl, _vkMenu, _vkLWin, _vkRWin];

  static bool _isDown(int vk) => (_getAsyncKeyState(vk) & 0x8000) != 0;

  static bool get anyModifierDown => _modifiers.any(_isDown);

  /// 向前台窗口发送 Ctrl+C，用于“划词”取得选中的文字。
  ///
  /// 调用前应先等待用户松开热键里的修饰键；若仍按着，这里会先插入 Ctrl 按下，
  /// 再虚拟释放 Alt/Shift/Win，避免目标程序收到 Ctrl+Alt+C 或激活菜单栏。
  static void sendCopy() {
    _keybdEvent(_vkControl, 0, 0, 0);
    for (final vk in [_vkMenu, _vkShift, _vkLWin, _vkRWin]) {
      if (_isDown(vk)) _keybdEvent(vk, 0, _keyUp, 0);
    }
    _keybdEvent(_vkC, 0, 0, 0);
    _keybdEvent(_vkC, 0, _keyUp, 0);
    _keybdEvent(_vkControl, 0, _keyUp, 0);
  }

  /// 鼠标位置（物理像素）。
  static (int, int) cursorPos() {
    final p = calloc<_Point>();
    try {
      _getCursorPos(p);
      return (p.ref.x, p.ref.y);
    } finally {
      calloc.free(p);
    }
  }

  /// 虚拟桌面（所有显示器合起来）的范围：left, top, width, height（物理像素）。
  static (int, int, int, int) virtualScreen() => (
        _getSystemMetrics(76), // SM_XVIRTUALSCREEN
        _getSystemMetrics(77), // SM_YVIRTUALSCREEN
        _getSystemMetrics(78), // SM_CXVIRTUALSCREEN
        _getSystemMetrics(79), // SM_CYVIRTUALSCREEN
      );
}
