import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_colors.dart';

const _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: AppColors.graphite,
  onPrimary: Colors.white,
  primaryContainer: AppColors.subtle,
  onPrimaryContainer: AppColors.ink,
  // 탭 밑줄·리본 탭·포커스 테두리 같은 '지금 여기' 표시.
  secondary: AppColors.point,
  onSecondary: Colors.white,
  secondaryContainer: AppColors.subtle,
  onSecondaryContainer: AppColors.ink,
  tertiary: Color(0xFF4A4D57),
  onTertiary: Colors.white,
  tertiaryContainer: AppColors.subtle,
  onTertiaryContainer: AppColors.ink,
  error: Color(0xFFD13438),
  onError: Colors.white,
  errorContainer: Color(0xFFFDECEC),
  onErrorContainer: Color(0xFF8C1D20),
  surface: AppColors.surface,
  onSurface: AppColors.ink,
  onSurfaceVariant: AppColors.muted,
  outline: AppColors.outline,
  outlineVariant: AppColors.line,
  surfaceContainerLowest: Colors.white,
  surfaceContainerLow: Color(0xFFFAFAFB),
  surfaceContainer: AppColors.canvas,
  surfaceContainerHigh: Color(0xFFEFEFF2),
  surfaceContainerHighest: Color(0xFFE9E9ED),
  inverseSurface: AppColors.ink,
  onInverseSurface: Colors.white,
  shadow: Colors.black,
  scrim: Colors.black,
  surfaceTint: Colors.transparent,
);

const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: AppColors.stageText,
  onPrimary: AppColors.stage,
  primaryContainer: Color(0xFF34343C),
  onPrimaryContainer: AppColors.stageText,
  secondary: AppColors.stagePoint,
  onSecondary: AppColors.stage,
  secondaryContainer: Color(0xFF34343C),
  onSecondaryContainer: AppColors.stageText,
  // 현재 슬라이드 테두리. 어두운 바탕에서 흰 테두리가 가장 또렷하고 튀지 않는다.
  tertiary: AppColors.stageText,
  onTertiary: AppColors.stage,
  tertiaryContainer: Color(0xFF34343C),
  onTertiaryContainer: AppColors.stageText,
  error: AppColors.live,
  onError: Colors.white,
  errorContainer: Color(0xFF4A1F22),
  onErrorContainer: Color(0xFFFFD9DA),
  surface: AppColors.stagePanel,
  onSurface: AppColors.stageText,
  onSurfaceVariant: AppColors.stageMuted,
  outline: AppColors.stageOutline,
  outlineVariant: AppColors.stageLine,
  surfaceContainerLowest: AppColors.stage,
  surfaceContainerLow: Color(0xFF1A1A1E),
  surfaceContainer: AppColors.stagePanel,
  surfaceContainerHigh: Color(0xFF26262C),
  surfaceContainerHighest: Color(0xFF2C2C33),
  inverseSurface: AppColors.stageText,
  onInverseSurface: AppColors.stage,
  shadow: Colors.black,
  scrim: Colors.black,
  surfaceTint: Colors.transparent,
);

ThemeData buildAppTheme() => _theme(_lightScheme, AppColors.canvas);

ThemeData buildDarkAppTheme() => _theme(_darkScheme, AppColors.stage);

/// 밝은/어두운 테마 선택. 앱 바 버튼으로 바꾸고 Application Support/ui_theme.txt 에 남긴다.
final appThemeMode = ValueNotifier(ThemeMode.light);

Future<File> _themeFile() async =>
    File(p.join((await getApplicationSupportDirectory()).path, 'ui_theme.txt'));

Future<void> loadThemeMode() async {
  try {
    final file = await _themeFile();
    if (await file.exists() && (await file.readAsString()).trim() == 'dark') {
      appThemeMode.value = ThemeMode.dark;
    }
  } catch (_) {}
}

void toggleThemeMode() {
  final dark = appThemeMode.value != ThemeMode.dark;
  appThemeMode.value = dark ? ThemeMode.dark : ThemeMode.light;
  _themeFile()
      .then((f) => f.writeAsString(dark ? 'dark' : 'light'))
      .catchError((Object _) => File(''));
}

ThemeData _theme(ColorScheme cs, Color canvas) {
  const controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppRadius.control)),
  );
  final base = ThemeData(
    colorScheme: cs,
    useMaterial3: true,
    fontFamily: 'Pretendard',
    scaffoldBackgroundColor: canvas,
    visualDensity: VisualDensity.compact,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: cs.onSurface,
      displayColor: cs.onSurface,
    ),
    dividerTheme: DividerThemeData(color: cs.outlineVariant, space: 1),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.panel)),
        side: BorderSide(color: cs.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: cs.surface,
      elevation: 8,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.dialog)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: controlShape,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: controlShape,
        foregroundColor: cs.onSurface,
        side: BorderSide(color: cs.outline),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: controlShape,
        foregroundColor: cs.onSurface,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: controlShape,
        side: BorderSide(color: cs.outline),
        selectedBackgroundColor: cs.secondaryContainer,
        selectedForegroundColor: cs.onSurface,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: controlShape,
      side: BorderSide(color: cs.outlineVariant),
      selectedColor: cs.secondaryContainer,
      labelStyle: TextStyle(fontSize: 12, color: cs.onSurface),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide(color: cs.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide(color: cs.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide(color: cs.secondary, width: 1.5),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: cs.onSurface,
      unselectedLabelColor: cs.onSurfaceVariant,
      indicatorColor: cs.secondary,
      dividerColor: cs.outlineVariant,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: cs.inverseSurface,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      textStyle: TextStyle(fontSize: 12, color: cs.onInverseSurface),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: cs.surface,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.panel),
        side: BorderSide(color: cs.outlineVariant),
      ),
      textStyle: TextStyle(fontSize: 13, color: cs.onSurface),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: cs.inverseSurface,
      contentTextStyle: TextStyle(fontSize: 13, color: cs.onInverseSurface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.panel),
      ),
    ),
  );
}
