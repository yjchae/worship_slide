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

/// 밝은·어두운 외 테마. 바탕(canvas)에 색을 옅게 깔고, 선택 표시(container)·탭 밑줄(point)에
/// 그 색을 진하게 쓴다. primary 는 아이콘·글자에도 쓰이므로 흰 바탕에서 읽히게 늘 진하게 둔다.
ColorScheme _tinted({
  required Brightness brightness,
  required Color canvas,
  required Color surface,
  required Color line,
  required Color outline,
  required Color point,
  required Color ink,
  required Color muted,
  required Color primary,
  required Color container,
}) {
  final dark = brightness == Brightness.dark;
  final onPrimary = dark ? canvas : Colors.white;
  Color mix(double t) => Color.lerp(surface, ink, t)!;
  return ColorScheme(
    brightness: brightness,
    primary: primary,
    onPrimary: onPrimary,
    primaryContainer: container,
    onPrimaryContainer: ink,
    secondary: point,
    onSecondary: onPrimary,
    secondaryContainer: container,
    onSecondaryContainer: ink,
    tertiary: dark ? ink : point,
    onTertiary: onPrimary,
    tertiaryContainer: container,
    onTertiaryContainer: ink,
    error: dark ? AppColors.live : const Color(0xFFD13438),
    onError: Colors.white,
    errorContainer: dark ? const Color(0xFF4A1F22) : const Color(0xFFFDECEC),
    onErrorContainer: dark ? const Color(0xFFFFD9DA) : const Color(0xFF8C1D20),
    surface: surface,
    onSurface: ink,
    onSurfaceVariant: muted,
    outline: outline,
    outlineVariant: line,
    surfaceContainerLowest: dark ? canvas : Colors.white,
    surfaceContainerLow: mix(0.02),
    surfaceContainer: canvas,
    surfaceContainerHigh: Color.lerp(canvas, line, 0.35)!,
    surfaceContainerHighest: Color.lerp(canvas, line, 0.6)!,
    inverseSurface: ink,
    onInverseSurface: surface,
    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );
}

/// 앱 화면 테마 7종. 이름 = ui_theme.txt 에 남는 값 (예전 'light'/'dark' 그대로 읽힌다).
enum AppThemeKind {
  light('밝은', Color(0xFFF4F5F8), Color(0xFF4D5E82)),
  dark('어두운', Color(0xFF141417), Color(0xFF93A5CC)),
  lemon('레몬', Color(0xFFFBF8DC), Color(0xFFE0C200)),
  ivory('아이보리', Color(0xFFF6F1E4), Color(0xFFA9823F)),
  sky('스카이', Color(0xFFEDF3FA), Color(0xFF3A78C2)),
  lavender('라벤더', Color(0xFFF2F0F8), Color(0xFF6E5FB0)),
  midnight('미드나잇', Color(0xFF0E1420), Color(0xFF7FA8E6));

  const AppThemeKind(this.label, this.swatch, this.accent);
  final String label;
  // 메뉴 견본: 바탕 + 강조색 점.
  final Color swatch;
  final Color accent;

  ThemeData get theme => switch (this) {
    light => _theme(_lightScheme, AppColors.canvas),
    dark => _theme(_darkScheme, AppColors.stage),
    // 상큼한 레몬: 흰 카드 + 레몬 크림 바탕, 선택은 형광펜 같은 레몬, 글자는 올리브 먹색.
    lemon => _theme(
      _tinted(
        brightness: Brightness.light,
        canvas: swatch,
        surface: Colors.white,
        line: const Color(0xFFEAE3B2),
        outline: const Color(0xFFCFC37A),
        point: const Color(0xFFC9A700),
        ink: const Color(0xFF26240F),
        muted: const Color(0xFF6F6A45),
        primary: const Color(0xFF3B3714),
        container: const Color(0xFFFFF09A),
      ),
      swatch,
    ),
    // 따뜻한 아이보리: 종이 같은 크림 카드, 놋쇠(brass) 강조, 갈색 먹.
    ivory => _theme(
      _tinted(
        brightness: Brightness.light,
        canvas: swatch,
        surface: const Color(0xFFFFFDF7),
        line: const Color(0xFFE5DCC6),
        outline: const Color(0xFFCBBE9F),
        point: accent,
        ink: const Color(0xFF2E281F),
        muted: const Color(0xFF7A6F5C),
        primary: const Color(0xFF4A3D28),
        container: const Color(0xFFF1E5C6),
      ),
      swatch,
    ),
    // 맑은 하늘색: 차가운 바탕 + 선명한 블루 강조.
    sky => _theme(
      _tinted(
        brightness: Brightness.light,
        canvas: swatch,
        surface: Colors.white,
        line: const Color(0xFFD2DFEE),
        outline: const Color(0xFFA9BED8),
        point: accent,
        ink: const Color(0xFF14202E),
        muted: const Color(0xFF5E6E82),
        primary: const Color(0xFF1F4E86),
        container: const Color(0xFFDCEAFA),
      ),
      swatch,
    ),
    // 부드러운 라벤더: 회보라 바탕 + 차분한 보라 강조.
    lavender => _theme(
      _tinted(
        brightness: Brightness.light,
        canvas: swatch,
        surface: Colors.white,
        line: const Color(0xFFDDD8EC),
        outline: const Color(0xFFBDB4D8),
        point: accent,
        ink: const Color(0xFF1F1A2E),
        muted: const Color(0xFF6C6680),
        primary: const Color(0xFF43377A),
        container: const Color(0xFFE8E2F7),
      ),
      swatch,
    ),
    // 깊은 남색 어두운 테마: 발표 중 눈부심이 적고 순흑보다 덜 딱딱하다.
    midnight => _theme(
      _tinted(
        brightness: Brightness.dark,
        canvas: swatch,
        surface: const Color(0xFF18202F),
        line: const Color(0xFF2A3650),
        outline: const Color(0xFF43527A),
        point: accent,
        ink: const Color(0xFFE6ECF7),
        muted: const Color(0xFF93A0B8),
        primary: const Color(0xFFC9D8F2),
        container: const Color(0xFF263552),
      ),
      swatch,
    ),
  };
}

/// 테마 선택. 앱 바 팔레트 메뉴로 바꾸고 Application Support/ui_theme.txt 에 남긴다.
final appThemeKind = ValueNotifier(AppThemeKind.light);

Future<File> _themeFile() async =>
    File(p.join((await getApplicationSupportDirectory()).path, 'ui_theme.txt'));

Future<void> loadThemeMode() async {
  try {
    final file = await _themeFile();
    if (!await file.exists()) return;
    final name = (await file.readAsString()).trim();
    appThemeKind.value = AppThemeKind.values.firstWhere(
      (k) => k.name == name,
      orElse: () => AppThemeKind.light,
    );
  } catch (_) {}
}

void setThemeKind(AppThemeKind kind) {
  appThemeKind.value = kind;
  _themeFile()
      .then((f) => f.writeAsString(kind.name))
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
