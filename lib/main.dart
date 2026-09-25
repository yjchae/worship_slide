import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'src/app.dart';
import 'src/features/praise/data/font_library.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  // 추가 폰트가 망가져도 앱은 떠야 한다. 없으면 기본 3종만 보인다.
  try {
    await FontLibrary.load();
  } catch (_) {}
  runApp(const WorshipSlidesApp());
}
