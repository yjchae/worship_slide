import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/export_style_store.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_page_data.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_text_layout.dart';

ExportStyle _style([Map<String, dynamic> extra = const {}]) =>
    ExportStyle.fromJson({'font_size': 20, 'bible_font_size': 20, ...extra});

SlidePageData _page({
  required bool isBible,
  double spacing = 1.0,
  String main = '1 태초에 하나님이 천지를 창조하시니라',
}) => SlidePageData(
  mainText: main,
  englishText: '1 In the beginning God created the heavens and the earth.',
  extraText: '1 Au commencement, Dieu créa les cieux et la terre.',
  isBible: isBible,
  pageIndex: 0,
  totalPages: 1,
  style: _style({'bible_line_spacing': spacing}),
);

List<double> _heights(SlidePageData data) => [
  for (final c in SlideTextLayout.bodySpan(data).children!.cast<TextSpan>())
    c.style!.height!,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bible_line_spacing 저장', () {
    test('toJson → fromJson 왕복, 없으면 1.0, 범위 밖은 0.8~2.0', () {
      final s = _style().copyWith(bibleLineSpacing: 1.5);
      expect(
        ExportStyle.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
        ).bibleLineSpacing,
        1.5,
      );
      expect(_style().bibleLineSpacing, 1.0);
      expect(_style({'bible_line_spacing': 5.0}).bibleLineSpacing, 2.0);
      expect(_style({'bible_line_spacing': 0.1}).bibleLineSpacing, 0.8);
      expect(_style().copyWith(bibleLineSpacing: 9).bibleLineSpacing, 2.0);
    });

    test('ExportStyleStore 저장 → load 에서 유지', () async {
      final temp = await Directory.systemTemp.createTemp('line_spacing');
      addTearDown(() => temp.delete(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => temp.path,
          );
      final store = ExportStyleStore();
      await store.save(_style().copyWith(bibleLineSpacing: 1.5));
      expect((await store.load())!.bibleLineSpacing, 1.5);
    });
  });

  group('미리보기 줄 높이', () {
    test('성경만 배율을 곱한다', () {
      expect(_heights(_page(isBible: true)), [1.25, 1.3, 1.3]);
      expect(_heights(_page(isBible: true, spacing: 1.5)), [
        closeTo(1.875, 1e-9),
        closeTo(1.95, 1e-9),
        closeTo(1.95, 1e-9),
      ]);
      expect(_heights(_page(isBible: false, spacing: 1.5)), [1.25, 1.3, 1.3]);
    });

    test('배율이 커지면 넘침 비율도 커진다(캐시 키에 배율 포함)', () {
      final a = SlideTextLayout.cachedOverflowRatio(_page(isBible: true));
      final b = SlideTextLayout.cachedOverflowRatio(
        _page(isBible: true, spacing: 1.5),
      );
      expect(b, greaterThan(a));
    });
  });

  group('찬양 낱말 단위 줄바꿈', () {
    List<String> spanLines(InlineSpan span, double width) {
      final p = TextPainter(text: span, textDirection: TextDirection.ltr)
        ..layout(maxWidth: width);
      final shown = p.plainText;
      final out = <String>[];
      var start = 0;
      while (start < shown.length) {
        final end = p.getLineBoundary(TextPosition(offset: start)).end;
        if (end <= start) break;
        out.add(shown.substring(start, end).replaceAll('⁠', ''));
        start = end;
        while (start < shown.length && shown[start] == ' ') {
          start++;
        }
      }
      expect(p.width, lessThanOrEqualTo(width));
      p.dispose();
      return out;
    }

    List<String> lines(String text, double width) => spanLines(
      SlideTextLayout.bodySpan(
        _page(isBible: false, main: text),
      ).children!.first,
      width,
    );

    // 줄 경계가 원래 낱말 안에 오지 않는지(모든 줄 조각이 원문 낱말 그대로인지).
    void expectWhole(List<String> got, String text) {
      final words = text.split(' ').toSet();
      expect(got.length, greaterThan(1));
      for (final line in got) {
        for (final w in line.trim().split(' ')) {
          expect(words, contains(w), reason: '낱말이 잘림: $got');
        }
      }
    }

    test('한글 낱말 안에서 줄이 나뉘지 않는다', () {
      const text =
          '하나님이 세상을 이처럼 사랑하사 독생자를 주셨으니 이는 그를 믿는 자마다 멸망하지 않고 영생을 얻게 하려 하심이라';
      final words = text.split(' ').toSet();
      final got = lines(text, 333);
      expect(got.length, greaterThan(1));
      for (final line in got) {
        for (final w in line.trim().split(' ')) {
          expect(words, contains(w), reason: '낱말이 잘림: $got');
        }
      }
    });

    test('상자보다 긴 낱말은 여러 줄로 나뉘고 폭을 넘지 않는다', () {
      final got = lines('가' * 40, 333);
      expect(got.length, greaterThan(1));
      expect(got.join(), '가' * 40);
    });

    // 글자 크기 16 이면 폭 120 에 7자 — 가장 긴 낱말 'Jesus께서'(7자)도 들어간다.
    test('한글과 숫자·영문이 붙은 낱말도 안에서 나뉘지 않는다', () {
      // 성경: _splitNum 이 절 번호 뒤 본문에 keepWords 를 씌운 것과 같다.
      const bible = '그 날에 3천명이나 더하더라 바울이 2년을 머물며 Paul이 가르치니';
      const hymn = 'Jesus께서 100배나 주시네';
      for (final width in [120.0, 150.0, 200.0]) {
        expectWhole(
          spanLines(
            TextSpan(
              text: SlideTextLayout.keepWords(bible),
              style: const TextStyle(fontSize: 16),
            ),
            width,
          ),
          bible,
        );
        expectWhole(
          spanLines(
            SlideTextLayout.bodySpan(
              _page(isBible: false, main: hymn),
              fontScale: 0.8,
            ).children!.first,
            width,
          ),
          hymn,
        );
      }
    });

    test('word joiner 는 한글 음절 사이·한글과 숫자·영문 사이에만 들어간다', () {
      expect(SlideTextLayout.keepWords('사랑 하사'), '사\u2060랑 하\u2060사');
      expect(SlideTextLayout.keepWords('3천명'), '3\u2060천\u2060명');
      expect(SlideTextLayout.keepWords('Paul이'), 'Paul\u2060이');
      expect(SlideTextLayout.keepWords('100배나'), '100\u2060배\u2060나');
      for (final s in [
        'Amazing grace',
        '찬양 🙏🏻 👨‍👩‍👧',
        '\u1109\u1161\u1105\u1161\u11BC', // NFD '사랑'
        'cafe\u0301', // e + 결합 악센트
      ]) {
        final got = SlideTextLayout.keepWords(s).replaceAll('찬\u2060양', '찬양');
        expect(got, s, reason: s);
      }
    });
  });
}
