// 只在 Windows 上运行：实际执行更新脚本，验证等待进程退出、覆盖程序文件、同步后端目录、写日志。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingyi/services/updater.dart';

void main() {
  final skip = Platform.isWindows ? null : '只在 Windows 上运行';

  test('用系统 tar 解压 zip', () async {
    final root = Directory.systemTemp.createTempSync('lingyi_zip');
    final src = Directory('${root.path}\\src')..createSync();
    File('${src.path}\\a.txt').writeAsStringSync('你好');
    Directory('${src.path}\\data').createSync();
    File('${src.path}\\data\\b.bin').writeAsBytesSync([1, 2, 3]);
    final zip = File('${root.path}\\p.zip');
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "Compress-Archive -Path '${src.path}\\*' -DestinationPath '${zip.path}'",
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final out = Directory('${root.path}\\out')..createSync();
    await Updater.extractZip(zip, out);
    expect(File('${out.path}\\a.txt').readAsStringSync(), '你好');
    expect(File('${out.path}\\data\\b.bin').readAsBytesSync(), [1, 2, 3]);
  }, skip: skip);

  test('更新脚本替换文件后重新打开程序', () async {
    final root = Directory.systemTemp.createTempSync('lingyi_upd');
    final install = Directory('${root.path}\\灵译 安装')..createSync();
    File('${install.path}\\a.txt').writeAsStringSync('old');
    File('${install.path}\\keep.txt').writeAsStringSync('keep');
    Directory('${install.path}\\backend').createSync();
    File('${install.path}\\backend\\old.bin').writeAsStringSync('old');

    final app = Directory('${root.path}\\stage\\app')..createSync(recursive: true);
    File('${app.path}\\a.txt').writeAsStringSync('new');
    // “程序”用系统自带的 whoami.exe 代替：被脚本重新打开后立即退出
    File(r'C:\Windows\System32\whoami.exe').copySync('${app.path}\\lingyi.exe');
    final backend = Directory('${root.path}\\stage\\backend')..createSync();
    File('${backend.path}\\new.bin').writeAsStringSync('new');
    File('${backend.path}\\BUILD_ID').writeAsStringSync('b2');

    // 模拟“灵译还在运行”：一个 3 秒后退出的进程
    final waiter = await Process.start('ping', ['-n', '4', '127.0.0.1']);
    final script = File('${root.path}\\stage\\update.cmd');
    script.writeAsStringSync(Updater.buildScript(
      pid: waiter.pid,
      install: install.path,
      exeName: 'lingyi.exe',
      appSrc: app.path,
      backendSrc: backend.path,
    ));
    final sw = Stopwatch()..start();
    final r = await Process.run('cmd', ['/c', script.path]);
    sw.stop();
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    expect(sw.elapsed.inMilliseconds, greaterThan(1500), reason: '应等待进程退出后再复制');
    expect(File('${install.path}\\a.txt').readAsStringSync(), 'new');
    expect(File('${install.path}\\keep.txt').existsSync(), isTrue);
    expect(File('${install.path}\\lingyi.exe').existsSync(), isTrue);
    expect(File('${install.path}\\backend\\new.bin').existsSync(), isTrue);
    expect(File('${install.path}\\backend\\old.bin').existsSync(), isFalse);
    expect(File('${install.path}\\backend\\BUILD_ID').readAsStringSync(), 'b2');
    final log = File('${root.path}\\stage\\update.log').readAsStringSync();
    expect(log, contains('OK'));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
