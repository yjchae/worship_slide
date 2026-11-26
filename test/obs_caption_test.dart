import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/obs_overlay_store.dart';
import 'package:worship_slides/src/features/praise/domain/obs_caption.dart';

void main() {
  const config = ObsOverlayConfig();
  const song = ObsSlide(
    mainText: '주의 사랑\n나를 감싸네  ',
    subText: 'Your love',
    extraText: '主の愛',
    title: '주의 사랑',
  );

  ObsCaption cap(
    ObsSlide? slide, {
    bool presenting = true,
    bool blackout = false,
    bool hidden = false,
    ObsOverlayConfig c = config,
  }) => obsCaptionFor(
    slide: slide,
    presenting: presenting,
    blackout: blackout,
    hidden: hidden,
    config: c,
  );

  test('찬양: 원본·보조, 추가 보조·곡 제목은 기본 끔, 줄 끝 공백만 정리', () {
    final c = cap(song);
    expect(c.show, isTrue);
    expect(c.kind, 'song');
    expect(c.main, '주의 사랑\n나를 감싸네');
    expect(c.sub, 'Your love');
    expect(c.extra, '');
    expect(c.heading, '');
  });

  test('보조·추가 보조·곡 제목 스위치는 OBS 설정을 따른다', () {
    final c = cap(
      song,
      c: config.copyWith(showSub: false, showExtra: true, showSongTitle: true),
    );
    expect(c.sub, '');
    expect(c.extra, '主の愛');
    expect(c.heading, '주의 사랑');
  });

  test('성경: 참조가 heading, 끄면 빠진다', () {
    const bible = ObsSlide(
      mainText: '1 태초에',
      subText: '1 In the beginning',
      title: '창세기 1:1',
      isBible: true,
    );
    expect(cap(bible).kind, 'bible');
    expect(cap(bible).heading, '창세기 1:1');
    expect(cap(bible, c: config.copyWith(showReference: false)).heading, '');
  });

  test('관객 화면 따라가기: 발표 전·블랙아웃·숨김이면 투명', () {
    expect(cap(song, presenting: false).reason, ObsHideReason.beforePresent);
    expect(cap(song, blackout: true).reason, ObsHideReason.blackout);
    expect(cap(song, hidden: true).reason, ObsHideReason.hidden);
    for (final c in [
      cap(song, presenting: false),
      cap(song, blackout: true),
      cap(song, hidden: true),
    ]) {
      expect(c.show, isFalse);
      expect(c.main, '');
    }
  });

  test('그림·미디어·빈 페이지·자동 여백은 투명', () {
    expect(cap(const ObsSlide(hasImage: true)).reason, ObsHideReason.image);
    expect(
      cap(const ObsSlide(mainText: '글', hasMedia: true)).reason,
      ObsHideReason.media,
    );
    expect(cap(const ObsSlide()).reason, ObsHideReason.empty);
    expect(cap(const ObsSlide(mainText: '  \n ')).show, isFalse);
    expect(cap(null).show, isFalse);
  });

  test('보조만 있는 페이지도 보조 스위치를 끄면 투명', () {
    const onlySub = ObsSlide(subText: 'English only');
    expect(cap(onlySub).show, isTrue);
    expect(cap(onlySub, c: config.copyWith(showSub: false)).show, isFalse);
  });

  test('설교 제목: 부제는 보조 스위치와 상관없이, 스위치를 끄면 투명', () {
    const sermon = ObsSlide(
      mainText: '은혜의 길',
      subText: '요 3:16',
      isSermon: true,
    );
    final c = cap(sermon, c: config.copyWith(showSub: false));
    expect(c.kind, 'sermon');
    expect(c.sub, '요 3:16');
    expect(
      cap(sermon, c: config.copyWith(showSermon: false)).reason,
      ObsHideReason.sermonOff,
    );
  });

  test('빈 페이지 문구는 text 로 나간다', () {
    final c = cap(const ObsSlide(mainText: '광고 시간'));
    expect(c.kind, 'text');
    expect(c.heading, '');
  });

  test('JSON 에 로컬 경로·코드 같은 칸이 없다', () {
    final json = cap(song).toJson();
    expect(json.keys.toSet(), {
      'show',
      'reason',
      'kind',
      'heading',
      'main',
      'sub',
      'extra',
    });
    expect(jsonEncode(json), isNot(contains('/')));
  });
}
