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

class WindowSnapBackService with WidgetsBindingObserver {
  static final WindowSnapBackService instance = WindowSnapBackService._();
  WindowSnapBackService._();

  static const double minLogicalWidth = 830.0;
  static const double minLogicalHeight = 830.0;

  bool _initialized = false;
  int? _hwnd;
  bool _isSnapping = false;
  Timer? _settleTimer;

  DynamicLibrary? _user32;
  int Function(Pointer<Utf16>, Pointer<Utf16>)? _findWindowW;
  int Function()? _getForegroundWindow;
  int Function(int, Pointer<_RECT>)? _getWindowRect;
  int Function(int, int, int, int, int, int, int)? _setWindowPos;
  int Function(int)? _getAsyncKeyState;

  static void initialize({double? initialWidth, double? initialHeight}) {
    if (!Platform.isWindows) return;
    instance._init(initialWidth: initialWidth, initialHeight: initialHeight);
  }

  void _init({double? initialWidth, double? initialHeight}) {
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
      debugPrint('WindowSnapBackService 초기화 오류: $e');
    }
  }

  bool get _isLeftMouseDown {
    if (_getAsyncKeyState == null) return false;
    // VK_LBUTTON = 0x01. If high bit is 1, button is currently held down.
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
    if (!Platform.isWindows || _isSnapping) return;

    _settleTimer?.cancel();
    _settleTimer = Timer.periodic(const Duration(milliseconds: 25), (timer) {
      if (!_isLeftMouseDown || timer.tick >= 20) {
        timer.cancel();
        _settleTimer = null;
        _checkAndSnapBack();
      }
    });
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
