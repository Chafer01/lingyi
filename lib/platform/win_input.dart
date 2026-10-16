// Windows 输入相关的少量 user32/kernel32 调用（通过 dart:ffi，不引入额外依赖）。
// 只在 Windows 上调用；在其他平台上不会加载这些 DLL。
import 'dart:ffi';
import 'dart:typed_data';

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
typedef _I32I32C = Int32 Function(Int32 v);
typedef _IntIntD = int Function(int v);
typedef _AsyncKeyC = Int16 Function(Int32 v);
typedef _U32VoidC = Uint32 Function();
typedef _I32VoidC = Int32 Function();
typedef _IntVoidD = int Function();
typedef _I32U32C = Int32 Function(Uint32 v);
typedef _PtrVoidC = IntPtr Function();
typedef _GetPidC = Uint32 Function(IntPtr hwnd, Pointer<Uint32> pid);
typedef _GetPidD = int Function(int hwnd, Pointer<Uint32> pid);
typedef _ClassNameC = Int32 Function(IntPtr hwnd, Pointer<Utf16> buf, Int32 max);
typedef _ClassNameD = int Function(int hwnd, Pointer<Utf16> buf, int max);
typedef _OpenProcessC = IntPtr Function(Uint32 access, Int32 inherit, Uint32 pid);
typedef _OpenProcessD = int Function(int access, int inherit, int pid);
typedef _QueryImageC = Int32 Function(IntPtr h, Uint32 flags, Pointer<Utf16> buf, Pointer<Uint32> size);
typedef _QueryImageD = int Function(int h, int flags, Pointer<Utf16> buf, Pointer<Uint32> size);
typedef _CloseHandleC = Int32 Function(IntPtr h);
typedef _OpenClipC = Int32 Function(IntPtr hwnd);
typedef _I32VoidD = int Function(int v);
typedef _U32U32C = Uint32 Function(Uint32 v);
typedef _HandleU32C = IntPtr Function(Uint32 v);
typedef _SizePtrC = UintPtr Function(IntPtr h);
typedef _LockC = Pointer<Uint8> Function(IntPtr h);
typedef _LockD = Pointer<Uint8> Function(int h);
typedef _I32PtrC = Int32 Function(IntPtr h);
typedef _GlobalAllocC = IntPtr Function(Uint32 flags, UintPtr size);
typedef _GlobalAllocD = int Function(int flags, int size);
typedef _SetClipC = IntPtr Function(Uint32 fmt, IntPtr h);
typedef _SetClipD = int Function(int fmt, int h);
typedef _FindWindowExC = IntPtr Function(IntPtr parent, IntPtr after, Pointer<Utf16> cls, Pointer<Utf16> title);
typedef _FindWindowExD = int Function(int parent, int after, Pointer<Utf16> cls, Pointer<Utf16> title);
typedef _PtrPtrC = IntPtr Function(IntPtr h);
typedef _SleepC = Void Function(Uint32 ms);
typedef _SleepD = void Function(int ms);

/// 剪贴板的一份完整备份（每种格式的原始数据）。
class ClipboardSnapshot {
  ClipboardSnapshot(this.items);
  final List<(int, Uint8List)> items;
  bool get isEmpty => items.isEmpty;
}

/// 前台窗口信息。
class ForegroundInfo {
  const ForegroundInfo(this.pid, this.exe, this.windowClass);
  final int pid;

  /// 可执行文件名（不含路径），取不到时为空字符串。
  final String exe;
  final String windowClass;
}

class WinInput {
  WinInput._();

  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final _keybdEvent = _user32.lookupFunction<_KeybdEventC, _KeybdEventD>('keybd_event');
  static final _getCursorPos = _user32.lookupFunction<_GetCursorPosC, _GetCursorPosD>('GetCursorPos');
  static final _getSystemMetrics = _user32.lookupFunction<_I32I32C, _IntIntD>('GetSystemMetrics');
  static final _getAsyncKeyState = _user32.lookupFunction<_AsyncKeyC, _IntIntD>('GetAsyncKeyState');
  static final _clipboardSeq = _user32.lookupFunction<_U32VoidC, _IntVoidD>('GetClipboardSequenceNumber');
  static final _countClipFormats = _user32.lookupFunction<_I32VoidC, _IntVoidD>('CountClipboardFormats');
  static final _isClipFormat = _user32.lookupFunction<_I32U32C, _IntIntD>('IsClipboardFormatAvailable');
  static final _doubleClickTime = _user32.lookupFunction<_U32VoidC, _IntVoidD>('GetDoubleClickTime');
  static final _foregroundWindow = _user32.lookupFunction<_PtrVoidC, _IntVoidD>('GetForegroundWindow');
  static final _windowPid = _user32.lookupFunction<_GetPidC, _GetPidD>('GetWindowThreadProcessId');
  static final _className = _user32.lookupFunction<_ClassNameC, _ClassNameD>('GetClassNameW');
  static final _openProcess = _kernel32.lookupFunction<_OpenProcessC, _OpenProcessD>('OpenProcess');
  static final _queryImage =
      _kernel32.lookupFunction<_QueryImageC, _QueryImageD>('QueryFullProcessImageNameW');
  static final _closeHandle = _kernel32.lookupFunction<_CloseHandleC, _IntIntD>('CloseHandle');
  static final _currentPid = _kernel32.lookupFunction<_U32VoidC, _IntVoidD>('GetCurrentProcessId');
  static final _openClipboard = _user32.lookupFunction<_OpenClipC, _I32VoidD>('OpenClipboard');
  static final _closeClipboard = _user32.lookupFunction<_I32VoidC, _IntVoidD>('CloseClipboard');
  static final _emptyClipboard = _user32.lookupFunction<_I32VoidC, _IntVoidD>('EmptyClipboard');
  static final _enumClipFormats = _user32.lookupFunction<_U32U32C, _IntIntD>('EnumClipboardFormats');
  static final _getClipData = _user32.lookupFunction<_HandleU32C, _IntIntD>('GetClipboardData');
  static final _setClipData = _user32.lookupFunction<_SetClipC, _SetClipD>('SetClipboardData');
  static final _findWindowEx = _user32.lookupFunction<_FindWindowExC, _FindWindowExD>('FindWindowExW');
  static final _globalSize = _kernel32.lookupFunction<_SizePtrC, _IntIntD>('GlobalSize');
  static final _globalLock = _kernel32.lookupFunction<_LockC, _LockD>('GlobalLock');
  static final _globalUnlock = _kernel32.lookupFunction<_I32PtrC, _IntIntD>('GlobalUnlock');
  static final _globalAlloc = _kernel32.lookupFunction<_GlobalAllocC, _GlobalAllocD>('GlobalAlloc');
  static final _globalFree = _kernel32.lookupFunction<_PtrPtrC, _IntIntD>('GlobalFree');
  static final _sleep = _kernel32.lookupFunction<_SleepC, _SleepD>('Sleep');

  static const _keyUp = 0x0002;
  static const _vkLButton = 0x01;
  static const _vkShift = 0x10;
  static const _vkControl = 0x11;
  static const _vkMenu = 0x12; // Alt
  static const _vkLWin = 0x5B;
  static const _vkRWin = 0x5C;
  static const _vkC = 0x43;
  static const _cfUnicodeText = 13;

  static const _modifiers = [_vkShift, _vkControl, _vkMenu, _vkLWin, _vkRWin];

  static bool _isDown(int vk) => (_getAsyncKeyState(vk) & 0x8000) != 0;

  static bool get anyModifierDown => _modifiers.any(_isDown);

  /// 鼠标左键当前是否按下。
  static bool get leftButtonDown => _isDown(_vkLButton);

  /// 系统设置的双击间隔（毫秒）。
  static int get doubleClickMs => _doubleClickTime();

  /// 剪贴板序号：每次剪贴板内容变化都会增加，用来判断复制是否真的发生了。
  static int get clipboardSequence => _clipboardSeq();

  /// 剪贴板里有内容但不是文字（例如图片、文件）。
  static bool get clipboardHasNonText => _countClipFormats() > 0 && _isClipFormat(_cfUnicodeText) == 0;

  // 这些格式的数据是 GDI 句柄而不是内存块，无法按字节备份；
  // 系统会从 CF_DIB / CF_DIBV5 自动合成 CF_BITMAP，所以图片不受影响。
  static const _gdiFormats = {2, 3, 9, 14, 0x80, 0x82, 0x83, 0x8E};

  static bool _open(int hwnd) {
    for (var i = 0; i < 10; i++) {
      if (_openClipboard(hwnd) != 0) return true;
      _sleep(10); // 别的程序正占用剪贴板
    }
    return false;
  }

  /// 灵译自己的窗口：恢复剪贴板时必须用一个属于本进程的窗口打开剪贴板，
  /// 否则 EmptyClipboard 之后 SetClipboardData 会失败。
  static int _ownWindow() {
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      var h = 0;
      while (true) {
        h = _findWindowEx(0, h, cls, nullptr);
        if (h == 0) return 0;
        _windowPid(h, pid);
        if (pid.value == currentPid) return h;
      }
    } finally {
      calloc.free(cls);
      calloc.free(pid);
    }
  }

  /// 备份剪贴板里的全部内容（文字、图片、文件列表、HTML 等）。
  /// 总大小超过 [maxBytes] 或打不开剪贴板时返回 null。
  static ClipboardSnapshot? saveClipboard({int maxBytes = 64 << 20}) {
    if (!_open(0)) return null;
    final items = <(int, Uint8List)>[];
    var total = 0;
    try {
      var fmt = 0;
      while ((fmt = _enumClipFormats(fmt)) != 0) {
        if (_gdiFormats.contains(fmt)) continue;
        final h = _getClipData(fmt);
        if (h == 0) continue;
        final size = _globalSize(h);
        if (size <= 0) continue;
        total += size;
        if (total > maxBytes) return null;
        final p = _globalLock(h);
        if (p == nullptr) continue;
        try {
          items.add((fmt, Uint8List.fromList(p.asTypedList(size))));
        } finally {
          _globalUnlock(h);
        }
      }
      return ClipboardSnapshot(items);
    } finally {
      _closeClipboard();
    }
  }

  /// 把剪贴板恢复成 [snap] 备份时的内容。
  static bool restoreClipboard(ClipboardSnapshot snap) {
    if (!_open(_ownWindow())) return false;
    try {
      _emptyClipboard();
      for (final (fmt, data) in snap.items) {
        const gmemMoveable = 0x0002;
        final h = _globalAlloc(gmemMoveable, data.length);
        if (h == 0) continue;
        final p = _globalLock(h);
        if (p == nullptr) {
          _globalFree(h);
          continue;
        }
        p.asTypedList(data.length).setAll(0, data);
        _globalUnlock(h);
        if (_setClipData(fmt, h) == 0) _globalFree(h); // 成功后句柄归系统所有
      }
      return true;
    } finally {
      _closeClipboard();
    }
  }

  static int get currentPid => _currentPid();

  /// 向前台窗口发送 Ctrl+C，用于取得选中的文字。
  ///
  /// 若用户仍按着热键里的修饰键，这里会先插入 Ctrl 按下，再虚拟释放 Alt/Shift/Win，
  /// 避免目标程序收到 Ctrl+Alt+C 或激活菜单栏。
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

  /// 前台窗口所属进程及窗口类名。
  static ForegroundInfo foreground() {
    final hwnd = _foregroundWindow();
    if (hwnd == 0) return const ForegroundInfo(0, '', '');
    final pidPtr = calloc<Uint32>();
    final buf = calloc<Uint16>(1024);
    final size = calloc<Uint32>();
    try {
      _windowPid(hwnd, pidPtr);
      final pid = pidPtr.value;

      final n = _className(hwnd, buf.cast<Utf16>(), 256);
      final cls = n > 0 ? buf.cast<Utf16>().toDartString(length: n) : '';

      var exe = '';
      const processQueryLimitedInformation = 0x1000;
      final h = _openProcess(processQueryLimitedInformation, 0, pid);
      if (h != 0) {
        size.value = 1024;
        if (_queryImage(h, 0, buf.cast<Utf16>(), size) != 0) {
          final path = buf.cast<Utf16>().toDartString(length: size.value);
          exe = path.split(RegExp(r'[\\/]')).last;
        }
        _closeHandle(h);
      }
      return ForegroundInfo(pid, exe, cls);
    } finally {
      calloc.free(pidPtr);
      calloc.free(buf);
      calloc.free(size);
    }
  }
}
