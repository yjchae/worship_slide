import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;

import 'app_theme.dart';
import 'features/praise/presentation/praise_home_page.dart';

class WorshipSlidesApp extends StatelessWidget {
  const WorshipSlidesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: appThemeKind,
      builder: (context, kind, _) => MaterialApp(
        title: 'Worship Slides',
        debugShowCheckedModeBanner: false,
        theme: kind.theme,
        // Quill 의 색·크기 팝업은 showDialog(앱 루트)로 열려 창 안 Localizations.override 밖이다.
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: const PraiseHomePage(),
      ),
    );
  }
}
