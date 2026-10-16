import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../version.dart';
import 'settings.dart';

/// 发布页上的一个安装包。
class UpdateAsset {
  const UpdateAsset(this.url, this.size, this.sha256);
  final String url;
  final int size;
  final String sha256;

  static UpdateAsset? fromJson(Object? j) {
    if (j is! Map || j['url'] is! String) return null;
    return UpdateAsset(j['url'] as String, (j['size'] as num?)?.toInt() ?? 0, (j['sha256'] as String?) ?? '');
  }
}

/// 最新版本的信息（来自发布页的 update.json，由编译工作流生成）。
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.page,
    this.backendId = '',
    this.windowsApp,
    this.windowsBackend,
    this.windowsFull,
    this.android,
  });

  final String version;
  final String notes;
  final String page;

  /// 后端（截图识别 / PDF 翻译）的构建编号；与本机相同时只需下载程序本体。
  final String backendId;
  final UpdateAsset? windowsApp;
  final UpdateAsset? windowsBackend;
  final UpdateAsset? windowsFull;
  final UpdateAsset? android;

  factory UpdateInfo.fromJson(Map<String, dynamic> j) => UpdateInfo(
        version: (j['version'] as String? ?? '').trim(),
        notes: (j['notes'] as String? ?? '').trim(),
        page: j['page'] as String? ?? Updater.releasesPage,
        backendId: j['backend_id'] as String? ?? '',
        windowsApp: UpdateAsset.fromJson(j['windows_app']),
        windowsBackend: UpdateAsset.fromJson(j['windows_backend']),
        windowsFull: UpdateAsset.fromJson(j['windows_full']),
        android: UpdateAsset.fromJson(j['android']),
      );
}

/// 版本号比较：a > b 返回正数。只比较数字部分（0.5.10 > 0.5.9）。
int compareVersions(String a, String b) {
  List<int> parts(String v) =>
      v.replaceFirst(RegExp(r'^v'), '').split(RegExp(r'[.+-]')).map((e) => int.tryParse(e) ?? 0).toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 检查更新、下载并安装（Windows：替换程序文件后自动重启；安卓：交给浏览器下载安装包）。
class Updater {
  Updater._();
  static final Updater instance = Updater._();

  static const releasesPage = 'https://github.com/Chafer01/lingyi/releases/latest';
  static const manifestUrl = 'https://github.com/Chafer01/lingyi/releases/latest/download/update.json';

  /// 发现的新版本（没有时为 null）。界面顶部的更新提示监听它。
  final ValueNotifier<UpdateInfo?> available = ValueNotifier(null);

  /// 上一次更新的结果（“已更新到 …”或失败原因），显示一次。
  final ValueNotifier<String?> notice = ValueNotifier(null);

  final _s = Settings.instance;

  /// 读取发布页的 update.json。网络不通时抛出 [UpdateException]。
  Future<UpdateInfo> fetchLatest({http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final r = await c.get(Uri.parse(manifestUrl)).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw UpdateException('读取版本信息失败（HTTP ${r.statusCode}）');
      return UpdateInfo.fromJson(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>);
    } on TimeoutException {
      throw UpdateException('连接 GitHub 超时');
    } on SocketException catch (e) {
      throw UpdateException('无法连接 GitHub：${e.message}');
    } on FormatException {
      throw UpdateException('版本信息格式不正确');
    } finally {
      if (client == null) c.close();
    }
  }

  /// 手动检查：返回新版本信息；已是最新时返回 null。
  Future<UpdateInfo?> check() async {
    final info = await fetchLatest();
    _s.lastUpdateCheck = DateTime.now().millisecondsSinceEpoch;
    final newer = compareVersions(info.version, appVersion) > 0;
    available.value = newer ? info : null;
    return newer ? info : null;
  }

  /// 启动时调用：报告上次更新的结果；按设置在后台检查新版本（失败不打扰用户）。
  Future<void> onStartup() async {
    final pending = _s.pendingUpdate;
    if (pending.isNotEmpty) {
      _s.pendingUpdate = '';
      notice.value = compareVersions(appVersion, pending) >= 0
          ? '已更新到 $appVersion'
          : '更新到 $pending 没有完成，仍是 $appVersion。可以在 设置 → 关于与更新 里重试，或到发布页手动下载。'
              '${_logHint()}';
    }
    if (!_s.autoCheckUpdate) return;
    final since = DateTime.now().millisecondsSinceEpoch - _s.lastUpdateCheck;
    if (since < const Duration(hours: 6).inMilliseconds) return;
    await Future<void>.delayed(const Duration(seconds: 8));
    try {
      final info = await check();
      if (info != null && info.version == _s.ignoredUpdate) available.value = null;
    } catch (_) {
      // 自动检查失败（公司网络、离线等）时不提示
    }
  }

  String _logHint() {
    if (!Platform.isWindows) return '';
    final log = File('${_stagingRoot.path}\\update.log');
    return log.existsSync() ? '\n安装日志：${log.path}' : '';
  }

  // ---------------------------------------------------------------------------
  // Windows：下载 → 校验 → 解压 → 退出后由脚本替换文件并重启
  // ---------------------------------------------------------------------------

  static Directory get _stagingRoot =>
      Directory('${Platform.environment['TEMP'] ?? Directory.systemTemp.path}\\lingyi_update');

  static Directory get installDir => File(Platform.resolvedExecutable).parent;

  /// 本机后端的构建编号（安装包里的 backend\BUILD_ID）。
  static String get localBackendId {
    try {
      return File('${installDir.path}\\backend\\BUILD_ID').readAsStringSync().trim();
    } catch (_) {
      return '';
    }
  }

  /// 这次更新需要下载的包。
  static List<(String, UpdateAsset)> windowsDownloads(UpdateInfo info, {String? localBackend}) {
    final app = info.windowsApp;
    if (app == null) return const [];
    final lb = localBackend ?? localBackendId;
    final needBackend = info.backendId.isEmpty || lb != info.backendId;
    return [
      ('程序', app),
      if (needBackend && info.windowsBackend != null) ('截图识别与 PDF 后端', info.windowsBackend!),
    ];
  }

  /// 检查安装目录是否可写（装在 Program Files 等目录时不可写，只能手动更新）。
  static bool installDirWritable() {
    final f = File('${installDir.path}\\.lingyi_write_test');
    try {
      f.writeAsStringSync('x');
      f.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 下载并解压，返回准备好的更新目录。[onProgress] 收到 (说明, 已下载字节, 总字节)。
  Future<Directory> prepareWindows(UpdateInfo info, void Function(String, int, int) onProgress,
      {http.Client? client}) async {
    if (!installDirWritable()) {
      throw UpdateException('灵译所在的文件夹没有写入权限（${installDir.path}），无法自动更新。请手动下载新版。');
    }
    final downloads = windowsDownloads(info);
    if (downloads.isEmpty) throw UpdateException('发布页没有提供 Windows 更新包');
    final root = Directory('${_stagingRoot.path}\\${info.version}');
    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync(recursive: true);
    final total = downloads.fold<int>(0, (a, d) => a + d.$2.size);
    var done = 0;
    final c = client ?? http.Client();
    try {
      for (final (name, asset) in downloads) {
        final isApp = identical(asset, info.windowsApp);
        final zip = File('${root.path}\\${isApp ? 'app' : 'backend'}.zip');
        final before = done;
        await downloadAsset(c, asset, zip, (n) => onProgress('正在下载$name', before + n, total));
        done += asset.size;
        onProgress('正在解压$name', done, total);
        final dir = Directory('${root.path}\\${isApp ? 'app' : 'backend'}')..createSync();
        await extractZip(zip, dir);
        zip.deleteSync();
      }
    } finally {
      if (client == null) c.close();
    }
    if (!File('${root.path}\\app\\${_exeName()}').existsSync()) {
      throw UpdateException('更新包内容不完整（缺少 ${_exeName()}）');
    }
    return root;
  }

  static String _exeName() => Platform.resolvedExecutable.split(RegExp(r'[\\/]')).last;

  /// 下载一个安装包到 [out]，校验大小和 SHA-256。
  Future<void> downloadAsset(http.Client c, UpdateAsset a, File out, void Function(int) onBytes) async {
    final http.StreamedResponse resp;
    try {
      resp = await c.send(http.Request('GET', Uri.parse(a.url))).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw UpdateException('连接下载服务器超时');
    } on SocketException catch (e) {
      throw UpdateException('无法连接下载服务器：${e.message}');
    }
    if (resp.statusCode != 200) throw UpdateException('下载失败（HTTP ${resp.statusCode}）');
    final sink = out.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    var n = 0;
    try {
      await for (final chunk in resp.stream.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        hasher.add(chunk);
        n += chunk.length;
        onBytes(n);
      }
    } on TimeoutException {
      throw UpdateException('下载中断（60 秒没有收到数据）');
    } finally {
      await sink.close();
    }
    hasher.close();
    if (a.size > 0 && n != a.size) throw UpdateException('下载不完整（$n / ${a.size} 字节）');
    if (a.sha256.isNotEmpty && digest.value.toString() != a.sha256.toLowerCase()) {
      throw UpdateException('下载的文件校验失败，请重试');
    }
  }

  /// 用 Windows 自带的 tar（Windows 10 1803 起）解压 zip；不可用时退回 PowerShell。
  static Future<void> extractZip(File zip, Directory dir) async {
    var r = await Process.run('tar', ['-xf', zip.path, '-C', dir.path]);
    if (r.exitCode == 0) return;
    r = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "Expand-Archive -LiteralPath '${zip.path}' -DestinationPath '${dir.path}' -Force",
    ]);
    if (r.exitCode != 0) throw UpdateException('解压失败：${r.stderr}'.trim());
  }

  /// 生成更新脚本：等灵译退出 → 结束后端 → 复制新文件 → 重新打开灵译。
  static String buildScript({
    required int pid,
    required String install,
    required String exeName,
    required String appSrc,
    String? backendSrc,
  }) {
    final b = StringBuffer()
      ..writeln('@echo off')
      ..writeln('chcp 65001 >nul')
      ..writeln('set "LOG=%~dp0update.log"')
      ..writeln('echo 等待灵译退出 > "%LOG%"')
      ..writeln(':wait')
      ..writeln('tasklist /FI "PID eq $pid" 2>nul | find "$pid" >nul')
      // 没有控制台输入时 timeout 命令不可用，用 ping 等 1 秒
      ..writeln('if not errorlevel 1 ( ping -n 2 127.0.0.1 >nul & goto wait )')
      ..writeln('taskkill /F /IM lingyi_backend.exe >nul 2>&1')
      ..writeln('ping -n 2 127.0.0.1 >nul')
      ..writeln('robocopy "$appSrc" "$install" /E /R:5 /W:1 /NFL /NDL /NP >> "%LOG%"')
      ..writeln('if errorlevel 8 goto fail');
    if (backendSrc != null) {
      b
        ..writeln('robocopy "$backendSrc" "$install\\backend" /MIR /R:5 /W:1 /NFL /NDL /NP >> "%LOG%"')
        ..writeln('if errorlevel 8 goto fail');
    }
    b
      ..writeln('echo OK >> "%LOG%"')
      ..writeln('start "" "$install\\$exeName"')
      ..writeln('exit /b 0')
      ..writeln(':fail')
      ..writeln('echo FAIL >> "%LOG%"')
      ..writeln('start "" "$install\\$exeName"')
      ..writeln('exit /b 1');
    return b.toString().replaceAll('\n', '\r\n');
  }

  /// 写好更新脚本并在后台启动；调用方随后退出灵译。
  Future<void> launchInstaller(UpdateInfo info, Directory staged) async {
    final backend = Directory('${staged.path}\\backend');
    final script = File('${_stagingRoot.path}\\update.cmd');
    script.writeAsStringSync(buildScript(
      pid: pid,
      install: installDir.path,
      exeName: _exeName(),
      appSrc: '${staged.path}\\app',
      backendSrc: backend.existsSync() ? backend.path : null,
    ));
    _s.pendingUpdate = info.version;
    // 分离进程：不弹出命令行窗口，灵译退出后脚本继续运行
    await Process.start('cmd', ['/c', script.path], mode: ProcessStartMode.detached);
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
