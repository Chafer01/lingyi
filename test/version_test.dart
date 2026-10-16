import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingyi/version.dart';

void main() {
  test('appVersion 与 pubspec.yaml 一致', () {
    final m = RegExp(r'^version:\s*([^+\s]+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync());
    expect(appVersion, m!.group(1));
  });
}
