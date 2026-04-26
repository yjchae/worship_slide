import 'package:flutter/material.dart';

import 'features/praise/presentation/praise_home_page.dart';

class PraiseLyricsApp extends StatelessWidget {
  const PraiseLyricsApp({super.key});

  @override
  Widget build(BuildContext context) {
    const baseColor = Color(0xFF1B6B5C);

    return MaterialApp(
      title: '찬양 가사 관리자',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: baseColor,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F1EA),
        useMaterial3: true,
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      home: const PraiseHomePage(),
    );
  }
}
