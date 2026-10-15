import 'dart:io';

import 'package:flutter/material.dart';

import 'platform/android_intent.dart';
import 'platform/desktop.dart';
import 'services/dict_service.dart';
import 'services/settings.dart';
import 'services/user_db.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.instance.load();
  await UserDb.instance.init();
  await DictService.instance.init();

  if (Desktop.supported) await Desktop.instance.init();

  runApp(const LingyiApp());

  if (Platform.isAndroid) await AndroidIntents.init();
}
