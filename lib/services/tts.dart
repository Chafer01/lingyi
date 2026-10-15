import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 朗读（使用系统 TTS：Windows SAPI / 安卓系统语音引擎）。
class Tts {
  Tts._();
  static final Tts instance = Tts._();

  final _tts = FlutterTts();
  bool _ready = false;

  Future<void> _init() async {
    if (_ready) return;
    _ready = true;
    try {
      // 安卓上 0.5 为正常语速，稍慢一点更利于听清单词。Windows 保持默认。
      if (Platform.isAndroid) await _tts.setSpeechRate(0.42);
    } catch (e) {
      debugPrint('TTS 初始化失败: $e');
    }
  }

  Future<void> speak(String text, {bool english = true}) async {
    await _init();
    try {
      await _tts.stop();
      await _tts.setLanguage(english ? 'en-US' : 'zh-CN');
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TTS 朗读失败: $e');
    }
  }
}
