import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:worship_slides/src/features/praise/data/b_screen_store.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/slide_media.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_page_data.dart';

const _style = ExportStyle(
  fontSize: 30,
  bibleFontSize: 30,
  backgroundColor: Color(0xFF1B1B1B),
  textColor: Colors.white,
  bibleTextColor: Colors.white,
  textPosition: VerticalTextPosition.bottom,
  bibleTextPosition: VerticalTextPosition.middle,
  lyricsTextAlign: HorizontalPosition.center,
  bibleTextAlign: HorizontalPosition.center,
  includeEnglishLyrics: true,
  englishTextColor: Color(0xFFFFF176),
  showSongTitle: true,
  showBibleTitle: false,
  titleFontSize: 14,
  bibleTitleFontSize: 14,
  titleTextColor: Colors.white,
  bibleTitleTextColor: Colors.white,
  titleHorizontalPosition: HorizontalPosition.right,
  titleVerticalPosition: VerticalTextPosition.bottom,
  bibleTitleHorizontalPosition: HorizontalPosition.right,
  bibleTitleVerticalPosition: VerticalTextPosition.bottom,
);

void main() {
  group('bSplitRects', () {
    test('위쪽 0.65 — 디자인의 1248×702 + 자막 띠 1920×378', () {
      final r = bSplitRects(1920, 1080, BSide.top, 0.65, true);
      expect(r.slide.width * 1920, closeTo(1248, 0.01));
      expect(r.slide.height * 1080, closeTo(702, 0.01));
      expect(r.slide.top, 0);
      expect(r.slide.center.dx, closeTo(0.5, 1e-9));
      expect(r.sub!.top, closeTo(r.slide.bottom, 1e-9));
      expect(r.sub!.width, 1);
      expect(r.sub!.height * 1080, closeTo(378, 0.01));
    });

    test('어느 위치·몫·모니터에서든 슬라이드는 16:9 이고 칸이 안 겹친다', () {
      for (final (w, h) in [
        (1920, 1080),
        (1920, 1200),
        (1024, 768),
        (3440, 1440),
      ]) {
        for (final side in BSide.values) {
          for (var share = 0.4; share <= 0.8; share += 0.05) {
            final r = bSplitRects(w, h, side, share, true);
            expect(
              (r.slide.width * w) / (r.slide.height * h),
              closeTo(16 / 9, 1e-6),
            );
            expect(r.slide.left, greaterThanOrEqualTo(-1e-9));
            expect(r.slide.top, greaterThanOrEqualTo(-1e-9));
            expect(r.slide.right, lessThanOrEqualTo(1 + 1e-9));
            expect(r.slide.bottom, lessThanOrEqualTo(1 + 1e-9));
            expect(r.slide.intersect(r.sub!).isEmpty, isTrue);
          }
        }
      }
    });

    test('아래·왼쪽·오른쪽 자리', () {
      final bottom = bSplitRects(1920, 1080, BSide.bottom, 0.5, true);
      expect(bottom.slide.bottom, closeTo(1, 1e-9));
      expect(bottom.sub!.bottom, closeTo(bottom.slide.top, 1e-9));
      final left = bSplitRects(1920, 1080, BSide.left, 0.5, true);
      expect(left.slide.left, 0);
      expect(left.sub!.left, closeTo(0.5, 1e-9));
      final right = bSplitRects(1920, 1080, BSide.right, 0.5, true);
      expect(right.slide.right, closeTo(1, 1e-9));
      expect(right.sub!.right, closeTo(0.5, 1e-9));
    });

    test('자막이 없으면 슬라이드가 전체', () {
      final r = bSplitRects(1920, 1080, BSide.left, 0.4, false);
      expect(r.slide.width, closeTo(1, 1e-9));
      expect(r.slide.height, closeTo(1, 1e-9));
      expect(r.sub, isNull);
    });
  });

  group('폴더 대응표', () {
    late Directory temp;
    late String aDir, bDir;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('b_screen');
      aDir = p.join(temp.path, 'a');
      bDir = p.join(temp.path, 'b');
      Directory(aDir).createSync();
      Directory(bDir).createSync();
      File(p.join(bDir, '0007.png')).writeAsBytesSync([0]);
      File(p.join(bDir, '0001.media.json')).writeAsStringSync('{}');
    });
    tearDown(() => temp.deleteSync(recursive: true));

    BPptPair pair() =>
        BPptPair(bDir: bDir, bName: 'en.pptx', aCount: 24, bCount: 1);

    test('같은 파일 이름으로 잇고, 없는 쪽·연결 없는 폴더·이미지 없는 페이지는 그대로', () {
      final pairs = {aDir: pair()};
      expect(
        bImagePath(p.join(aDir, '0007.png'), pairs),
        p.join(bDir, '0007.png'),
      );
      final missing = p.join(aDir, '0008.png');
      expect(bImagePath(missing, pairs), missing);
      expect(bImagePath('/other/0007.png', pairs), '/other/0007.png');
      expect(bImagePath(null, pairs), isNull);
    });

    test('A 를 다시 구우면 대응이 새 폴더로 옮겨 간다', () {
      final config = BScreenConfig(pairs: {aDir: pair()});
      final moved = config.movePair(aDir, '/new', 25);
      expect(moved.pairs.keys, ['/new']);
      expect(moved.pairs['/new']!.bDir, bDir);
      expect(moved.pairs['/new']!.aCount, 25);
      // 같은 폴더로 다시 구워도 대응이 남는다.
      expect(config.movePair(aDir, aDir, 25).pairs[aDir]!.aCount, 25);
      expect(config.movePair('/none', '/new', 1).pairs, config.pairs);
    });

    test('장수는 렌더 페이지만 센다, .wsconti 이미지는 이을 수 없다', () async {
      expect(await countRenderedPages(bDir), 1);
      expect(isRenderedPage('/x/0007.png'), isTrue);
      expect(isRenderedPage('/imported_contis/1/0.png'), isFalse);
    });

    test('설정이 JSON 을 오가도 남고, 깨진 값은 기본값으로', () {
      final config = BScreenConfig(
        side: BSide.right,
        share: 0.5,
        subtitleUrl: '',
        pairs: {aDir: pair()},
      );
      final back = BScreenConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
      );
      expect(back.side, BSide.right);
      expect(back.share, 0.5);
      expect(back.subtitleUrl, '');
      expect(back.pairs[aDir]!.bName, 'en.pptx');

      final bad = BScreenConfig.fromJson({'side': 'x', 'share': 9, 'pairs': 1});
      expect(bad.side, BSide.top);
      expect(bad.share, maxBShare);
      expect(bad.subtitleUrl, defaultBSubtitleUrl);
    });
  });

  group('연결 끊기·바꾸기는 옛 폴더 키까지', () {
    const old = BPptPair(bDir: '/b', bName: 'en', aCount: 5, bCount: 5);
    const other = BPptPair(bDir: '/c', bName: 'id', aCount: 3, bCount: 3);
    // /a1 을 다시 구워 /a2 가 됐고 옛 키가 남은 상태.
    const config = BScreenConfig(pairs: {'/a1': old, '/a2': old, '/z': other});

    test('끊기', () {
      expect(config.unlinkPair('/a2').pairs.keys, ['/z']);
      expect(config.unlinkPair('/없음').pairs, hasLength(3));
    });

    test('바꾸기', () {
      const next = BPptPair(bDir: '/n', bName: 'new', aCount: 6, bCount: 6);
      final pairs = config.linkPair('/a2', next).pairs;
      expect(pairs['/a2']!.aCount, 6);
      expect(pairs['/a1']!.bDir, '/n');
      expect(pairs['/a1']!.bName, 'new');
      expect(pairs['/a1']!.aCount, 5);
      expect(pairs['/z']!.bDir, '/c');
    });

    test('새로 잇기는 다른 연결을 건드리지 않는다', () {
      const next = BPptPair(bDir: '/n', bName: 'new', aCount: 1, bCount: 1);
      final pairs = config.linkPair('/새', next).pairs;
      expect(pairs['/새']!.bDir, '/n');
      expect(pairs['/a1']!.bDir, '/b');
    });
  });

  test('자막 주소 검사와 칸 JSON', () {
    expect(isValidBSubtitleUrl(''), isTrue);
    expect(isValidBSubtitleUrl(defaultBSubtitleUrl), isTrue);
    expect(isValidBSubtitleUrl('  https://a.local/x  '), isTrue);
    expect(isValidBSubtitleUrl('ftp://x'), isFalse);
    expect(isValidBSubtitleUrl('http://'), isFalse);
    expect(isValidBSubtitleUrl('https://'), isFalse);
    expect(isValidBSubtitleUrl('http://:8000/x'), isFalse);
    expect(isValidBSubtitleUrl('http://a b/x'), isFalse);

    final none = const BScreenConfig(subtitleUrl: ' ').layoutJson(1920, 1080);
    expect(none['sub_rect'], isNull);
    expect(none['sub_url'], '');
    expect(
      const BScreenConfig().layoutJson(1920, 1080)['sub_rect'],
      hasLength(4),
    );
  });

  group('forB', () {
    SlidePageData page({
      String english = '',
      String extra = '셋째',
      String? image,
      SlideMedia? media,
    }) => SlidePageData(
      mainText: '주 사랑',
      englishText: english,
      extraText: extra,
      title: '곡',
      isBible: false,
      pageIndex: 2,
      totalPages: 9,
      style: _style,
      imagePath: image,
      media: media,
    );

    test('보조와 추가 보조가 다 있으면 보조가 본문, 추가 보조가 보조 줄이다', () {
      final b = page(english: 'Tuhan').forB(null);
      expect(b.mainText, 'Tuhan');
      expect(b.englishText, '셋째');
      expect(b.extraText, '');
      expect(b.pageIndex, 2);
    });

    test('보조만 있으면 본문으로 올린다', () {
      final b = page(english: 'Tuhan', extra: '').forB(null);
      expect(b.mainText, 'Tuhan');
      expect(b.englishText, '');
    });

    test('추가 보조만 있으면 본문으로 올린다', () {
      final b = page(english: ' ').forB(null);
      expect(b.mainText, '셋째');
      expect(b.englishText, '');
      expect(b.extraText, '');
    });

    test('둘 다 없으면 원본 그대로다', () {
      final b = page(extra: '').forB(null);
      expect(b.mainText, '주 사랑');
      expect(b.englishText, '');
      expect(b.extraText, '');
    });

    test('설교 부제는 올리지 않는다', () {
      final b = page(english: '요 3:16').forB(null, sermon: true);
      expect(b.mainText, '주 사랑');
      expect(b.englishText, '요 3:16');
      expect(b.extraText, '셋째');
    });

    test('이미지를 바꾸고 미디어는 뺀다', () {
      final a = page(
        image: '/a/0001.png',
        media: const SlideMedia(kind: MediaKind.video, source: '/v.mp4'),
      );
      final json = a.forB('/b/0001.png').toJson();
      expect(json['image_path'], '/b/0001.png');
      expect(json['media'], isNull);
      expect(a.media, isNotNull);
    });
  });
}
