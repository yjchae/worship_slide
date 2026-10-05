import 'package:flutter/material.dart';

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
        home: const PraiseHomePage(),
      ),
    );
  }
}
