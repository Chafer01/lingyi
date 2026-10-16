import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lingyi/services/settings.dart';
import 'package:lingyi/services/updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _manifest({String backendId = 'b2'}) => {
      'version': '0.6.0',
      'notes': '修复若干问题',
      'page': 'https://github.com/Chafer01/lingyi/releases/tag/v0.6.0',
      'backend_id': backendId,
      'windows_app': {'url': 'https://x/app.zip', 'size': 30000000, 'sha256': 'aa'},
      'windows_backend': {'url': 'https://x/backend.zip', 'size': 700000000, 'sha256': 'bb'},
      'windows_full': {'url': 'https://x/full.zip', 'size': 730000000, 'sha256': 'cc'},
      'android': {'url': 'https://x/a.apk', 'size': 60000000, 'sha256': 'dd'},
    };

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Settings.instance.load();
  });

  test('版本号比较', () {
    expect(compareVersions('0.5.10', '0.5.9'), greaterThan(0));
    expect(compareVersions('v0.6.0', '0.5.3'), greaterThan(0));
    expect(compareVersions('0.5.3', '0.5.3'), 0);
    expect(compareVersions('0.5.3+11', '0.5.3'), 0);
    expect(compareVersions('0.5', '0.5.1'), lessThan(0));
  });

  test('后端没变时只下载程序本体', () {
    final info = UpdateInfo.fromJson(_manifest());
    expect(Updater.windowsDownloads(info, localBackend: 'b2').map((d) => d.$2.url), ['https://x/app.zip']);
    expect(Updater.windowsDownloads(info, localBackend: 'b1').map((d) => d.$2.url),
        ['https://x/app.zip', 'https://x/backend.zip']);
    expect(Updater.windowsDownloads(info, localBackend: '').length, 2); // 旧版没有 BUILD_ID
    expect(info.android!.url, 'https://x/a.apk');
  });

  test('读取发布页的 update.json', () async {
    final client = MockClient((req) async {
      expect(req.url.toString(), Updater.manifestUrl);
      return http.Response.bytes(utf8.encode(jsonEncode(_manifest())), 200);
    });
    final info = await Updater.instance.fetchLatest(client: client);
    expect(info.version, '0.6.0');
    expect(info.notes, '修复若干问题');
    final bad = MockClient((_) async => http.Response('Not Found', 404));
    expect(Updater.instance.fetchLatest(client: bad), throwsA(isA<UpdateException>()));
  });

  test('下载时校验大小和 SHA-256', () async {
    final data = utf8.encode('lingyi update payload');
    final good = UpdateAsset('https://x/a.zip', data.length, sha256.convert(data).toString());
    final client = MockClient.streaming((req, _) async => http.StreamedResponse(Stream.value(data), 200));
    final dir = Directory.systemTemp.createTempSync('lingyi_upd');
    final out = File('${dir.path}/a.zip');
    var seen = 0;
    await Updater.instance.downloadAsset(client, good, out, (n) => seen = n);
    expect(out.readAsBytesSync(), data);
    expect(seen, data.length);

    final wrongHash = UpdateAsset(good.url, data.length, 'deadbeef');
    expect(Updater.instance.downloadAsset(client, wrongHash, out, (_) {}), throwsA(isA<UpdateException>()));
    final wrongSize = UpdateAsset(good.url, data.length + 1, '');
    expect(Updater.instance.downloadAsset(client, wrongSize, out, (_) {}), throwsA(isA<UpdateException>()));
  });

  test('更新脚本：等待退出、复制、失败也重新打开', () {
    final s = Updater.buildScript(
        pid: 1234, install: r'C:\灵译', exeName: 'lingyi.exe', appSrc: r'C:\t\app', backendSrc: r'C:\t\backend');
    expect(s, contains('PID eq 1234'));
    expect(s, contains(r'robocopy "C:\t\app" "C:\灵译" /E'));
    expect(s, contains(r'robocopy "C:\t\backend" "C:\灵译\backend" /MIR'));
    expect(s, contains('taskkill /F /IM lingyi_backend.exe'));
    expect('start "" "C:\\灵译\\lingyi.exe"'.allMatches(s).length, 2);
    expect(s, contains('\r\n'));
    final noBackend = Updater.buildScript(pid: 1, install: r'C:\a', exeName: 'lingyi.exe', appSrc: r'C:\b');
    expect(noBackend, isNot(contains('/MIR')));
  });
}
