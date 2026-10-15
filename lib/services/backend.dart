import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../util/text_utils.dart';
import 'settings.dart';

/// 后端调用失败时抛出，message 直接展示给用户。
class BackendException implements Exception {
  BackendException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// OCR 结果（文字或公式）。
class OcrResult {
  OcrResult(Map<String, dynamic> j)
      : mode = j['mode'] as String? ?? 'text',
        text = j['text'] as String? ?? '',
        latex = j['latex'] as String?,
        mathml = j['mathml'] as String?,
        image = j['image'] is String ? base64Decode(j['image'] as String) : null;

  final String mode;
  final String text;
  final String? latex;
  final String? mathml;

  /// 后端读到的原图（剪贴板 / 文件识别时返回，用于预览）。
  final Uint8List? image;
}

/// PDF 翻译任务状态。
class PdfJob {
  PdfJob(Map<String, dynamic> j)
      : id = j['id'] as String,
        status = j['status'] as String,
        stage = j['stage'] as String? ?? '',
        progress = (j['progress'] as num?)?.toDouble() ?? 0,
        error = j['error'] as String? ?? '',
        file = j['file'] as String? ?? '',
        elapsed = (j['elapsed'] as num?)?.toDouble() ?? 0,
        outputs = Map<String, String>.from((j['outputs'] as Map?) ?? const {});

  final String id;
  final String status; // queued / running / done / error / cancelled
  final String stage;
  final double progress;
  final String error;
  final String file;
  final double elapsed;
  final Map<String, String> outputs;

  bool get finished => status == 'done' || status == 'error' || status == 'cancelled';
}

/// 本地 Python 后端（截图 OCR、公式识别、PDF 翻译）。仅 Windows。
///
/// 灵译按需启动后端进程：后端监听 127.0.0.1 的随机端口，并要求请求携带启动时生成的令牌；
/// 通过标准输入管道感知灵译退出，随之自动退出。
class Backend {
  Backend._();
  static final Backend instance = Backend._();

  static bool get supported => Platform.isWindows;

  /// 运行状态，供界面显示。
  final ValueNotifier<String> status = ValueNotifier('未启动');

  Process? _proc;
  int? _port;
  String _token = '';
  Future<void>? _starting;

  bool get running => _proc != null && _port != null;

  /// 默认后端位置：与 lingyi.exe 同目录的 backend\lingyi_backend.exe（CI 打包时放在这里）。
  static String get bundledExe {
    final dir = File(Platform.resolvedExecutable).parent.path;
    return '$dir${Platform.pathSeparator}backend${Platform.pathSeparator}lingyi_backend.exe';
  }

  /// 解析启动命令：设置里填写的命令优先，否则用随包附带的 exe。
  (String, List<String>, String?) _command() {
    final custom = Settings.instance.backendCmd.trim();
    if (custom.isNotEmpty) {
      final parts = splitCommandLine(custom);
      final cwd = Settings.instance.backendDir.trim();
      return (parts.first, parts.sublist(1), cwd.isEmpty ? null : cwd);
    }
    return (bundledExe, const [], null);
  }

  Future<void> ensureStarted() {
    if (running) return Future.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    final (exe, baseArgs, cwd) = _command();
    if (Settings.instance.backendCmd.trim().isEmpty && !File(exe).existsSync()) {
      status.value = '未找到后端';
      throw BackendException('没有找到后端程序：$exe\n如果是从源码运行，请在 设置 → 截图识别与 PDF 中填写后端启动命令。');
    }
    final rnd = Random.secure();
    _token = List.generate(24, (_) => rnd.nextInt(16).toRadixString(16)).join();
    status.value = '正在启动…';
    final Process p;
    try {
      p = await Process.start(
        exe,
        [...baseArgs, '--port', '0', '--token', _token, '--watch-stdin'],
        workingDirectory: cwd,
        environment: {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'},
      );
    } on ProcessException catch (e) {
      status.value = '启动失败';
      throw BackendException('无法启动后端：${e.message}');
    }
    _proc = p;
    final ready = Completer<int>();
    final errLines = <String>[];
    const decoder = Utf8Decoder(allowMalformed: true);
    p.stdout.transform(decoder).transform(const LineSplitter()).listen((line) {
      final m = RegExp(r'LINGYI_BACKEND_READY (\d+)').firstMatch(line);
      if (m != null && !ready.isCompleted) ready.complete(int.parse(m.group(1)!));
    });
    p.stderr.transform(decoder).transform(const LineSplitter()).listen((line) {
      errLines.add(line);
      if (errLines.length > 40) errLines.removeAt(0);
    });
    // 打包成窗口程序后标准输出可能不可用：同时轮询后端写下的端口文件（内容为“端口 进程号”）。
    final portFile = File('${Platform.environment['LOCALAPPDATA'] ?? ''}\\lingyi\\backend.port');
    Timer.periodic(const Duration(milliseconds: 300), (t) {
      if (ready.isCompleted) {
        t.cancel();
        return;
      }
      try {
        final parts = portFile.readAsStringSync().trim().split(RegExp(r'\s+'));
        if (parts.length >= 2 && int.tryParse(parts[1]) == p.pid) {
          final port = int.tryParse(parts[0]);
          if (port != null) ready.complete(port);
        }
      } catch (_) {}
    });
    unawaited(p.exitCode.then((code) {
      if (!ready.isCompleted) ready.completeError(BackendException('后端已退出（代码 $code）\n${errLines.join('\n')}'));
      if (identical(_proc, p)) {
        _proc = null;
        _port = null;
        status.value = '已停止';
      }
    }));
    try {
      _port = await ready.future.timeout(const Duration(seconds: 90));
      status.value = '运行中（端口 $_port）';
    } on TimeoutException {
      p.kill();
      status.value = '启动超时';
      throw BackendException('后端启动超时。\n${errLines.join('\n')}');
    }
  }

  Future<void> stop() async {
    final p = _proc;
    if (p == null) return;
    try {
      await _post('/shutdown', const {}, timeout: const Duration(seconds: 3));
    } catch (_) {
      p.kill();
    }
    _proc = null;
    _port = null;
    status.value = '已停止';
  }

  Future<void> restart() async {
    await stop();
    await ensureStarted();
  }

  // ---------------------------------------------------------------------------
  // HTTP
  // ---------------------------------------------------------------------------

  Uri _uri(String path) => Uri.parse('http://127.0.0.1:$_port$path');
  Map<String, String> get _headers => {'Content-Type': 'application/json', 'X-Lingyi-Token': _token};

  Future<dynamic> _decode(http.Response r) async {
    final body = utf8.decode(r.bodyBytes);
    if (r.statusCode >= 200 && r.statusCode < 300) return jsonDecode(body);
    var msg = 'HTTP ${r.statusCode}';
    try {
      final d = (jsonDecode(body) as Map)['detail'];
      if (d != null) msg = '$d';
    } catch (_) {}
    throw BackendException(msg);
  }

  Future<dynamic> _post(String path, Object body, {Duration timeout = const Duration(seconds: 120)}) async {
    await ensureStarted();
    try {
      final r = await http.post(_uri(path), headers: _headers, body: utf8.encode(jsonEncode(body))).timeout(timeout);
      return await _decode(r);
    } on SocketException catch (e) {
      throw BackendException('无法连接后端：${e.message}');
    } on TimeoutException {
      throw BackendException('后端响应超时（首次识别需要加载模型，请稍后重试）');
    }
  }

  Future<dynamic> _get(String path) async {
    await ensureStarted();
    try {
      return await _decode(await http.get(_uri(path), headers: _headers).timeout(const Duration(seconds: 20)));
    } on SocketException catch (e) {
      throw BackendException('无法连接后端：${e.message}');
    }
  }

  Future<Map<String, dynamic>> health() async => Map<String, dynamic>.from(await _get('/health') as Map);

  /// 识别图片字节。[mode] 为 text 或 formula。
  Future<OcrResult> ocrBytes(Uint8List png, {String mode = 'text'}) async =>
      OcrResult(Map<String, dynamic>.from(await _post('/ocr', {'mode': mode, 'image': base64Encode(png)}) as Map));

  /// 识别本地图片文件。
  Future<OcrResult> ocrFile(String path, {String mode = 'text'}) async =>
      OcrResult(Map<String, dynamic>.from(await _post('/ocr', {'mode': mode, 'path': path}) as Map));

  /// 识别剪贴板中的图片（截图工具会把截图放进剪贴板）。
  Future<OcrResult> ocrClipboard({String mode = 'text'}) async =>
      OcrResult(Map<String, dynamic>.from(await _post('/ocr/clipboard', {'mode': mode}) as Map));

  /// 提交 PDF 翻译。使用设置中的 AI 接口和术语表。
  Future<PdfJob> pdfSubmit({
    required String path,
    String? outDir,
    String? pages,
    String output = 'dual',
    bool toEnglish = false,
  }) async {
    final s = Settings.instance;
    final glossary = parseGlossary(s.glossary).entries.map((e) => [e.key, e.value]).toList();
    final j = await _post('/pdf/jobs', {
      'path': path,
      'out_dir': (outDir == null || outDir.isEmpty) ? null : outDir,
      'pages': (pages == null || pages.trim().isEmpty) ? null : pages.trim(),
      'lang_in': toEnglish ? 'zh' : 'en',
      'lang_out': toEnglish ? 'en' : 'zh',
      'output': output,
      'base_url': s.llmBaseUrl,
      'api_key': s.llmKey,
      'model': s.llmModel,
      'qps': s.pdfQps,
      // 术语表是“英文 = 中文”，译成英文时反过来用。
      'glossary': toEnglish ? glossary.map((e) => [e[1], e[0]]).toList() : glossary,
      'extract_terms': s.pdfExtractTerms,
    });
    return PdfJob(Map<String, dynamic>.from(j as Map));
  }

  Future<PdfJob> pdfStatus(String id) async => PdfJob(Map<String, dynamic>.from(await _get('/pdf/jobs/$id') as Map));

  Future<PdfJob> pdfCancel(String id) async =>
      PdfJob(Map<String, dynamic>.from(await _post('/pdf/jobs/$id/cancel', const {}) as Map));
}

/// 按空白拆分命令行，支持用双引号包住含空格的路径。
List<String> splitCommandLine(String s) {
  final out = <String>[];
  final buf = StringBuffer();
  var quoted = false;
  for (final ch in s.split('')) {
    if (ch == '"') {
      quoted = !quoted;
    } else if (!quoted && (ch == ' ' || ch == '\t')) {
      if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
    } else {
      buf.write(ch);
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}
