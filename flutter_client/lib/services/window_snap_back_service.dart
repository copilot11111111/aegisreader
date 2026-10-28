import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';

final class _RECT extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final class _NSSize extends Struct {
  @Double()
  external double width;
  @Double()
  external double height;
}

class WindowSnapBackService with WidgetsBindingObserver {
  static final WindowSnapBackService instance = WindowSnapBackService._();
  WindowSnapBackService._();

  static const double minLogicalWidth = 830.0;
  static const double minLogicalHeight = 830.0;

  // macOS 전용 최소 크기 (상단 헤더, 카드, 테이블, 액션바 완벽 수용)
  static const double macMinLogicalWidth = 830.0;
  static const double macMinLogicalHeight = 680.0;

  static final Map<String, Pointer<Utf8>> _utf8Cache = {};
  static Pointer<Utf8> _nativeUtf8(String str) {
    return _utf8Cache.putIfAbsent(str, () => str.toNativeUtf8());
  }

  bool _initialized = false;
  int? _hwnd;
  Pointer? _macWindow;
  bool _macNativeInitialized = false;
  bool _isSnapping = false;
  Timer? _settleTimer;

  // macOS 전용 FFI 함수 캐시
  Pointer Function(Pointer<Utf8>)? _selRegister;
  Pointer Function(Pointer<Utf8>)? _objcGetClass;
  Pointer Function(Pointer, Pointer)? _objcMsgSend;
  void Function(Pointer, Pointer, _NSSize)? _setContentSizeFunc;
  void Function(Pointer, Pointer)? _objcMsgSendVoid;
  int Function(Pointer, Pointer)? _pressedButtonsFunc;
  int Function(Pointer, Pointer)? _arrayCountFunc;
  Pointer Function(Pointer, Pointer, int)? _objectAtIndexFunc;

  // Windows 전용 API
  DynamicLibrary? _user32;
  int Function(Pointer<Utf16>, Pointer<Utf16>)? _findWindowW;
  int Function()? _getForegroundWindow;
  int Function(int, Pointer<_RECT>)? _getWindowRect;
  int Function(int, int, int, int, int, int, int)? _setWindowPos;
  int Function(int)? _getAsyncKeyState;

  static void initialize({double? initialWidth, double? initialHeight}) {
    if (Platform.isWindows) {
      instance._initWindows(initialWidth: initialWidth ?? 830, initialHeight: initialHeight ?? 830);
    } else if (Platform.isMacOS) {
      instance._initMacOS();
    }
  }

  void _initWindows({double? initialWidth, double? initialHeight}) {
    if (_initialized) return;
    _initialized = true;

    try {
      _user32 = DynamicLibrary.open('user32.dll');
      _findWindowW = _user32!
          .lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
              int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
      _getForegroundWindow = _user32!
          .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
      _getWindowRect = _user32!
          .lookupFunction<Int32 Function(IntPtr, Pointer<_RECT>),
              int Function(int, Pointer<_RECT>)>('GetWindowRect');
      _setWindowPos = _user32!.lookupFunction<
          Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
          int Function(int, int, int, int, int, int, int)>('SetWindowPos');
      _getAsyncKeyState = _user32!
          .lookupFunction<Int16 Function(Int32), int Function(int)>('GetAsyncKeyState');

      WidgetsBinding.instance.addObserver(this);

      if (initialWidth != null && initialHeight != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Future.delayed(const Duration(milliseconds: 50), () {
            _setInitialWindowSize(initialWidth, initialHeight);
          });
        });
      }
    } catch (e) {
      debugPrint('WindowSnapBackService Windows 초기화 오류: $e');
    }
  }

  void _initMacOS() {
    if (_initialized) return;
    _initialized = true;

    _initMacOSNative();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyMacOSWindowSizeWithRetry();
    });
  }

  void _initMacOSNative() {
    if (_macNativeInitialized) return;
    try {
      final lib = DynamicLibrary.process();
      _selRegister = lib.lookupFunction<
          Pointer Function(Pointer<Utf8>),
          Pointer Function(Pointer<Utf8>)>('sel_registerName');
      _objcGetClass = lib.lookupFunction<
          Pointer Function(Pointer<Utf8>),
          Pointer Function(Pointer<Utf8>)>('objc_getClass');
      _objcMsgSend = lib.lookupFunction<
          Pointer Function(Pointer, Pointer),
          Pointer Function(Pointer, Pointer)>('objc_msgSend');
      _objcMsgSendVoid = lib.lookupFunction<
          Void Function(Pointer, Pointer),
          void Function(Pointer, Pointer)>('objc_msgSend');
      _setContentSizeFunc = lib.lookupFunction<
          Void Function(Pointer, Pointer, _NSSize),
          void Function(Pointer, Pointer, _NSSize)>('objc_msgSend');
      _pressedButtonsFunc = lib.lookupFunction<
          Uint64 Function(Pointer, Pointer),
          int Function(Pointer, Pointer)>('objc_msgSend');
      _arrayCountFunc = lib.lookupFunction<
          Uint64 Function(Pointer, Pointer),
          int Function(Pointer, Pointer)>('objc_msgSend');
      _objectAtIndexFunc = lib.lookupFunction<
          Pointer Function(Pointer, Pointer, Uint64),
          Pointer Function(Pointer, Pointer, int)>('objc_msgSend');
      _macNativeInitialized = true;
    } catch (e) {
      debugPrint('WindowSnapBackService macOS FFI 초기화 오류: $e');
    }
  }

  void _applyMacOSWindowSizeWithRetry([int attempt = 0]) {
    final window = _getMacOSWindow();
    if (window != nullptr) {
      _applyMacOSWindowSize(window);
      return;
    }
    if (attempt < 10) {
      Future.delayed(Duration(milliseconds: 50 * (attempt + 1)), () {
        _applyMacOSWindowSizeWithRetry(attempt + 1);
      });
    }
  }

  Pointer _getMacOSWindow() {
    if (_macWindow != null && _macWindow != nullptr) return _macWindow!;
    if (!_macNativeInitialized || _objcGetClass == null || _selRegister == null || _objcMsgSend == null) return nullptr;

    try {
      final nsAppClass = _objcGetClass!(_nativeUtf8('NSApplication'));
      final sharedAppSel = _selRegister!(_nativeUtf8('sharedApplication'));
      final nsApp = _objcMsgSend!(nsAppClass, sharedAppSel);
      if (nsApp == nullptr) return nullptr;

      // 1. mainWindow 우선 탐색
      final mainWindowSel = _selRegister!(_nativeUtf8('mainWindow'));
      var window = _objcMsgSend!(nsApp, mainWindowSel);
      if (window != nullptr) {
        _macWindow = window;
        return window;
      }

      // 2. keyWindow 탐색
      final keyWindowSel = _selRegister!(_nativeUtf8('keyWindow'));
      window = _objcMsgSend!(nsApp, keyWindowSel);
      if (window != nullptr) {
        _macWindow = window;
        return window;
      }

      // 3. windows 배열 순회
      final windowsSel = _selRegister!(_nativeUtf8('windows'));
      final windowsList = _objcMsgSend!(nsApp, windowsSel);
      if (windowsList != nullptr && _arrayCountFunc != null && _objectAtIndexFunc != null) {
        final countSel = _selRegister!(_nativeUtf8('count'));
        final count = _arrayCountFunc!(windowsList, countSel);
        final objectAtIndexSel = _selRegister!(_nativeUtf8('objectAtIndex:'));

        for (int i = 0; i < count; i++) {
          final w = _objectAtIndexFunc!(windowsList, objectAtIndexSel, i);
          if (w != nullptr) {
            _macWindow = w;
            return w;
          }
        }
      }
    } catch (_) {}
    return nullptr;
  }

  bool get _isMacOSLeftMouseDown {
    if (!_macNativeInitialized || _objcGetClass == null || _selRegister == null || _pressedButtonsFunc == null) {
      return false;
    }
    try {
      final nsEventClass = _objcGetClass!(_nativeUtf8('NSEvent'));
      final pressedSel = _selRegister!(_nativeUtf8('pressedMouseButtons'));
      final buttons = _pressedButtonsFunc!(nsEventClass, pressedSel);
      return (buttons & 1) != 0;
    } catch (_) {
      return false;
    }
  }

  void _applyMacOSWindowSize(Pointer window) {
    if (!_macNativeInitialized || _setContentSizeFunc == null || _selRegister == null) return;
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
      final scale = view?.devicePixelRatio ?? 2.0;

      // 1. DPI(Retina 배율)를 고려하여 초기 크기 산출
      double targetW = 1640.0 / scale;
      double targetH = 1420.0 / scale;

      final display = view?.display;
      if (display != null) {
        final screenW = display.size.width / scale;
        final screenH = display.size.height / scale;
        targetW = min(targetW, screenW * 0.95);
        targetH = min(targetH, screenH * 0.92);
      }

      // 레이아웃이 잘리지 않는 최소 크기 보장
      targetW = max(targetW, macMinLogicalWidth);
      targetH = max(targetH, macMinLogicalHeight);

      final setContentSizeSel = _selRegister!(_nativeUtf8('setContentSize:'));
      final setContentMinSizeSel = _selRegister!(_nativeUtf8('setContentMinSize:'));
      final centerSel = _selRegister!(_nativeUtf8('center'));

      final sizePtr = calloc<_NSSize>();
      final minSizePtr = calloc<_NSSize>();
      try {
        // macOS AppKit에 contentMinSize를 등록하여 OS WindowServer 차원에서 축소 드래그 원천 방어
        minSizePtr.ref.width = macMinLogicalWidth;
        minSizePtr.ref.height = macMinLogicalHeight;
        _setContentSizeFunc!(window, setContentMinSizeSel, minSizePtr.ref);

        // 초기 시작 크기 설정
        sizePtr.ref.width = targetW;
        sizePtr.ref.height = targetH;
        _setContentSizeFunc!(window, setContentSizeSel, sizePtr.ref);

        // 앱 기동 시 1회만 화면 중앙 정렬
        _objcMsgSendVoid?.call(window, centerSel);
      } finally {
        calloc.free(sizePtr);
        calloc.free(minSizePtr);
      }
    } catch (_) {}
  }

  void _setMacOSWindowContentSize(double targetW, double targetH) {
    if (!_macNativeInitialized || _setContentSizeFunc == null || _selRegister == null) return;
    try {
      final window = _getMacOSWindow();
      if (window == nullptr) return;

      final setContentSizeSel = _selRegister!(_nativeUtf8('setContentSize:'));
      final setContentMinSizeSel = _selRegister!(_nativeUtf8('setContentMinSize:'));

      final sizePtr = calloc<_NSSize>();
      try {
        sizePtr.ref.width = targetW;
        sizePtr.ref.height = targetH;
        _setContentSizeFunc!(window, setContentMinSizeSel, sizePtr.ref);
        _setContentSizeFunc!(window, setContentSizeSel, sizePtr.ref);
      } finally {
        calloc.free(sizePtr);
      }
    } catch (_) {}
  }

  void _checkAndSnapBackMacOS() {
    if (_isSnapping) return;
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null) return;
    final scale = view.devicePixelRatio;
    final currentLogicalW = view.physicalSize.width / scale;
    final currentLogicalH = view.physicalSize.height / scale;

    final deficitW = max(0.0, macMinLogicalWidth - currentLogicalW);
    final deficitH = max(0.0, macMinLogicalHeight - currentLogicalH);

    if (deficitW > 1.0 || deficitH > 1.0) {
      _isSnapping = true;
      final targetW = max(currentLogicalW, macMinLogicalWidth);
      final targetH = max(currentLogicalH, macMinLogicalHeight);

      _setMacOSWindowContentSize(targetW, targetH);

      Future.delayed(const Duration(milliseconds: 200), () {
        _isSnapping = false;
      });
    }
  }

  bool get _isLeftMouseDown {
    if (_getAsyncKeyState == null) return false;
    return (_getAsyncKeyState!(0x01) & 0x8000) != 0;
  }

  int? _getWindowHandle() {
    if (_hwnd != null && _hwnd != 0) return _hwnd;
    if (_findWindowW == null) return null;

    final classNamePtr = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    try {
      final h = _findWindowW!(classNamePtr, nullptr);
      if (h != 0) {
        _hwnd = h;
        return _hwnd;
      }
    } catch (_) {
    } finally {
      calloc.free(classNamePtr);
    }

    if (_getForegroundWindow != null) {
      try {
        final fg = _getForegroundWindow!();
        if (fg != 0) {
          _hwnd = fg;
          return _hwnd;
        }
      } catch (_) {}
    }
    return null;
  }

  void _setInitialWindowSize(double targetLogicalW, double targetLogicalH) {
    final hwnd = _getWindowHandle();
    if (hwnd == null || hwnd == 0 || _getWindowRect == null || _setWindowPos == null) return;

    final rectPtr = calloc<_RECT>();
    try {
      if (_getWindowRect!(hwnd, rectPtr) == 0) return;

      final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
      final scale = view?.devicePixelRatio ?? 1.0;

      final currentClientW = (view?.physicalSize.width ?? 0) / scale;
      final currentClientH = (view?.physicalSize.height ?? 0) / scale;

      final currentWinW = rectPtr.ref.right - rectPtr.ref.left;
      final currentWinH = rectPtr.ref.bottom - rectPtr.ref.top;

      final borderW = currentWinW - (currentClientW * scale).round();
      final borderH = currentWinH - (currentClientH * scale).round();

      final newWinW = (targetLogicalW * scale).round() + max<int>(0, borderW);
      final newWinH = (targetLogicalH * scale).round() + max<int>(0, borderH);

      _setWindowPos!(
        hwnd,
        0,
        rectPtr.ref.left,
        rectPtr.ref.top,
        newWinW,
        newWinH,
        0x0014, // SWP_NOZORDER | SWP_NOACTIVATE
      );
    } catch (_) {
    } finally {
      calloc.free(rectPtr);
    }
  }

  @override
  void didChangeMetrics() {
    if (Platform.isWindows) {
      if (_isSnapping) return;
      _settleTimer?.cancel();
      _settleTimer = Timer.periodic(const Duration(milliseconds: 25), (timer) {
        if (!_isLeftMouseDown || timer.tick >= 20) {
          timer.cancel();
          _settleTimer = null;
          _checkAndSnapBack();
        }
      });
    } else if (Platform.isMacOS) {
      if (_isSnapping) return;
      final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
      if (view == null) return;
      final scale = view.devicePixelRatio;
      final currentLogicalW = view.physicalSize.width / scale;
      final currentLogicalH = view.physicalSize.height / scale;

      if (currentLogicalW < macMinLogicalWidth - 1.0 || currentLogicalH < macMinLogicalHeight - 1.0) {
        _settleTimer?.cancel();
        _settleTimer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
          if (!_isMacOSLeftMouseDown || timer.tick >= 25) {
            timer.cancel();
            _settleTimer = null;
            _checkAndSnapBackMacOS();
          }
        });
      }
    }
  }

  void _checkAndSnapBack() {
    final hwnd = _getWindowHandle();
    if (hwnd == null || hwnd == 0 || _getWindowRect == null || _setWindowPos == null) return;

    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null) return;

    final scale = view.devicePixelRatio;
    final currentLogicalW = view.physicalSize.width / scale;
    final currentLogicalH = view.physicalSize.height / scale;

    final deficitW = max(0.0, minLogicalWidth - currentLogicalW);
    final deficitH = max(0.0, minLogicalHeight - currentLogicalH);

    if (deficitW > 1.0 || deficitH > 1.0) {
      final rectPtr = calloc<_RECT>();
      try {
        if (_getWindowRect!(hwnd, rectPtr) == 0) return;

        final currentWinW = rectPtr.ref.right - rectPtr.ref.left;
        final currentWinH = rectPtr.ref.bottom - rectPtr.ref.top;

        final targetWinW = (currentWinW + deficitW * scale).round();
        final targetWinH = (currentWinH + deficitH * scale).round();

        _isSnapping = true;
        _setWindowPos!(
          hwnd,
          0,
          rectPtr.ref.left,
          rectPtr.ref.top,
          targetWinW,
          targetWinH,
          0x0014, // SWP_NOZORDER | SWP_NOACTIVATE
        );

        Future.delayed(const Duration(milliseconds: 150), () {
          _isSnapping = false;
        });
      } catch (_) {
      } finally {
        calloc.free(rectPtr);
      }
    }
  }
}
