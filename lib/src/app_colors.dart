import 'package:flutter/material.dart';

/// 앱 화면 색. 무채색 바탕 + 차콜 강조 + 선·선택 표시에만 옅은 슬레이트 블루(point).
/// 기능색은 발표 중(live)만.
/// 슬라이드·발표 창·PPTX 색과는 무관하다.
class AppColors {
  static const canvas = Color(0xFFF4F5F8);
  static const surface = Color(0xFFFFFFFF);
  // 구분선·테두리에 슬레이트 블루를 살짝 섞는다. 순회색이면 흰 바탕에서 너무 하얗게 묻힌다.
  static const line = Color(0xFFD6DBE6);
  static const outline = Color(0xFFB4BCCC);
  static const point = Color(0xFF4D5E82);
  static const ink = Color(0xFF1C1C21);
  static const muted = Color(0xFF6E6E7A);
  static const subtle = Color(0xFFEDEDF1);
  static const graphite = Color(0xFF2C2E35);
  static const live = Color(0xFFE5484D);

  // 어두운 테마
  static const stage = Color(0xFF141417);
  static const stagePanel = Color(0xFF1F1F24);
  static const stageLine = Color(0xFF30364A);
  static const stageOutline = Color(0xFF4A5268);
  static const stagePoint = Color(0xFF93A5CC);
  static const stageText = Color(0xFFEDEDF0);
  static const stageMuted = Color(0xFF9A9AA6);
}

/// 둥글기 3단계: 컨트롤 / 패널 / 다이얼로그.
class AppRadius {
  static const control = 6.0;
  static const panel = 10.0;
  static const dialog = 14.0;
}
