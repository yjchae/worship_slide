import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'features/praise/presentation/praise_home_page.dart';

class WorshipSlidesApp extends StatelessWidget {
  const WorshipSlidesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: appThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Worship Slides',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        darkTheme: buildDarkAppTheme(),
        themeMode: mode,
        home: const PraiseHomePage(),
      ),
    );
  }
}
