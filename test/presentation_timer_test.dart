import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/singer_web_server.dart';
import 'package:worship_slides/src/features/praise/presentation/presentation_timer.dart';

void main() {
  group('PresentationTimer', () {
    late DateTime now;
    late PresentationTimer timer;
    setUp(() {
      now = DateTime(2026, 10, 18, 19, 30);
      timer = PresentationTimer(now: () => now);
    });

    test('기준 시각으로 세므로 매초 더하지 않아도 흐른다', () {
      timer.start();
      now = now.add(const Duration(minutes: 3, seconds: 5));
      expect(timer.elapsed, const Duration(minutes: 3, seconds: 5));
      expect(timer.isRunning, isTrue);
    });

    test('일시정지하면 멈추고, 계속하면 멈춘 자리부터 센다', () {
      timer.start();
      now = now.add(const Duration(seconds: 10));
      timer.togglePause(presenting: true);
      now = now.add(const Duration(minutes: 5));
      expect(timer.elapsed, const Duration(seconds: 10));
      expect(timer.isPaused, isTrue);
      timer.togglePause(presenting: true);
      now = now.add(const Duration(seconds: 2));
      expect(timer.elapsed, const Duration(seconds: 12));
    });

    test('발표가 끝나면 마지막 값에서 멈추고, 다시 시작하면 0부터', () {
      timer.start();
      now = now.add(const Duration(seconds: 30));
      timer.stop();
      now = now.add(const Duration(minutes: 1));
      expect(timer.elapsed, const Duration(seconds: 30));
      // 발표 중이 아닐 때 '계속' 을 눌러도 흐르지 않는다.
      timer.togglePause(presenting: false);
      timer.togglePause(presenting: false);
      now = now.add(const Duration(minutes: 1));
      expect(timer.elapsed, const Duration(seconds: 30));
      timer.start();
      expect(timer.elapsed, Duration.zero);
    });

    test('리셋은 흐르던 상태를 그대로 두고 0으로', () {
      timer.start();
      now = now.add(const Duration(seconds: 40));
      timer.reset();
      now = now.add(const Duration(seconds: 3));
      expect(timer.elapsed, const Duration(seconds: 3));
    });

    test('바뀔 때마다 rev 가 오르고 알린다 — 같은 목표·같은 표시는 무시', () {
      var calls = 0;
      timer.addListener(() => calls++);
      final rev = timer.revision;
      timer.setTargetMinutes(30);
      timer.setTargetMinutes(30);
      timer.setTargetMinutes(0);
      timer.setShowOnSinger(false);
      timer.setShowOnSinger(false);
      expect(calls, 2);
      expect(timer.revision, rev + 2);
      final json = timer.toSingerJson();
      expect(json['target_ms'], 30 * 60 * 1000);
      expect(json['show'], isFalse);
      expect(json['running'], isFalse);
    });
  });

  test('휴대폰에는 보내는 순간의 경과 시간을 앞에 붙여 준다', () async {
    final server = SingerWebServer();
    await server.start();
    addTearDown(server.stop);
    final url = Uri.parse(server.urlFor('127.0.0.1'));
    final k = url.queryParameters['k']!;
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<String> state() async {
      final res = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/state?k=$k'),
      )).close();
      return res.transform(utf8.decoder).join();
    }

    server.update({
      'current': {'main_text': '불을 내려주소서'},
      'next': null,
      'page_number': 1,
      'total_pages': 2,
      'blackout': false,
      'clock': {
        'show': true,
        'elapsed_ms': 5000,
        'running': true,
        'target_ms': 1200000,
        'rev': 3,
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final text = await state();
    final match = RegExp(r'^\{"clock_ms":(\d+),').firstMatch(text);
    expect(match, isNotNull);
    expect(int.parse(match!.group(1)!), greaterThanOrEqualTo(5100));
    final data = jsonDecode(text) as Map<String, dynamic>;
    // 비교용으로 저장한 JSON 에는 흐르는 값이 없다(바뀐 게 없으면 다시 안 민다).
    expect((data['clock'] as Map).containsKey('elapsed_ms'), isFalse);
    expect(data['clock']['rev'], 3);
  });
}
