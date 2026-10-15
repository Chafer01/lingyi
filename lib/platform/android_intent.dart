import 'dart:io';

import 'package:flutter/services.dart';

import 'app_state.dart';

/// 安卓：接收“选中文字 → 灵译查词”（ACTION_PROCESS_TEXT）和“分享 → 灵译”（ACTION_SEND）。
class AndroidIntents {
  AndroidIntents._();

  static const _channel = MethodChannel('lingyi/intent');

  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'newText' && call.arguments is String) {
        AppState.instance.push(call.arguments as String);
      }
      return null;
    });
    try {
      final text = await _channel.invokeMethod<String>('getInitialText');
      if (text != null && text.trim().isNotEmpty) AppState.instance.push(text);
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }
}
