import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/obs_overlay_server.dart';
import 'package:worship_slides/src/features/praise/data/obs_overlay_store.dart';
import 'package:worship_slides/src/features/praise/domain/obs_caption.dart';

const _key = 'abcdefgh23456789';

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

Future<(int, String)> _get(String url) async {
  final client = HttpClient();
  try {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    return (
      res.statusCode,
      await res.transform(const Utf8Decoder(allowMalformed: true)).join(),
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  // 글꼴 에셋(rootBundle)을 읽으려면 바인딩이 필요하다. 바인딩은 HttpClient 를 가짜로 바꾸므로 되돌린다.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late ObsOverlayServer server;
  late int port;
  const config = ObsOverlayConfig();
  const shown = ObsCaption(show: true, kind: 'song', main: '주의 사랑');

  setUp(() async {
    server = ObsOverlayServer();
    port = await _freePort();
    await server.start(port: port, key: _key, allowLan: false);
  });
  tearDown(() => server.stop());

  test('키가 맞아야 열린다, 페이지는 투명 바탕 HTML', () async {
    expect(server.status.value, ObsServerStatus.running);
    expect(server.port, port);
    final bad = await _get('http://127.0.0.1:$port/obs?k=wrong');
    expect(bad.$1, HttpStatus.forbidden);
    final page = await _get('http://127.0.0.1:$port/obs?k=$_key');
    expect(page.$1, HttpStatus.ok);
    expect(page.$2, contains('background:transparent'));
    expect(page.$2, contains('/obs/events'));
  });

  test('state 는 마지막 자막, 같은 내용은 다시 안 만든다', () async {
    server.update(shown, config, 'Pretendard');
    final state = await _get('http://127.0.0.1:$port/obs/state?k=$_key');
    final json = jsonDecode(state.$2) as Map<String, dynamic>;
    expect(json['caption']['main'], '주의 사랑');
    expect(json['design']['font_family'], 'Pretendard');
    expect(jsonEncode(json['design']), isNot(contains(_key)));
  });

  test('SSE: 붙자마자 지금 자막, 바뀌면 새 자막, 끄면 투명 한 번', () async {
    server.update(shown, config, 'Pretendard');
    final client = HttpClient();
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/obs/events?k=$_key'),
    );
    final res = await req.close();
    final messages = <Map<String, dynamic>>[];
    final got = StreamController<void>.broadcast();
    res.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('data: ')) {
        messages.add(jsonDecode(line.substring(6)) as Map<String, dynamic>);
        got.add(null);
      }
    }, onError: (_) {});
    await got.stream.first.timeout(const Duration(seconds: 5));
    expect(messages.last['caption']['main'], '주의 사랑');
    expect(server.clients.value, 1);

    server.update(
      const ObsCaption(show: true, kind: 'song', main: '다음 장'),
      config,
      'Pretendard',
    );
    await got.stream.first.timeout(const Duration(seconds: 5));
    expect(messages.last['caption']['main'], '다음 장');

    final hidden = got.stream.first.timeout(const Duration(seconds: 5));
    await server.stop();
    await hidden;
    expect(messages.last['caption']['show'], isFalse);
    expect(server.status.value, ObsServerStatus.off);
    client.close(force: true);
  });

  test('포트를 다른 프로그램이 쓰면 옮기지 않고 portInUse', () async {
    final other = ObsOverlayServer();
    await other.start(port: port, key: _key, allowLan: false);
    expect(other.status.value, ObsServerStatus.portInUse);
    expect(other.isRunning, isFalse);
    await other.stop();
  });

  test('글꼴: 내장 글꼴은 에셋, 번호 밖은 404, POST 는 막힘', () async {
    expect(obsFontSources('Pretendard').length, 4);
    expect(obsFontSources('없는 글꼴'), isEmpty);
    server.setFonts(obsFontSources('NanumGothic'));
    server.update(shown, config, 'NanumGothic');
    final state = jsonDecode(
      (await _get('http://127.0.0.1:$port/obs/state?k=$_key')).$2,
    );
    final fonts = state['fonts'] as List;
    expect(fonts, hasLength(2));
    final font = await _get('http://127.0.0.1:$port${fonts.first['url']}');
    expect(font.$1, HttpStatus.ok);
    expect((await _get('http://127.0.0.1:$port/obs/font/9?k=$_key')).$1, 404);

    final client = HttpClient();
    final post = await (await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/obs/state?k=$_key'),
    )).close();
    expect(post.statusCode, HttpStatus.forbidden);
    client.close(force: true);
  });

  test('키를 바꿔 다시 켜면 옛 키는 막힌다', () async {
    await server.start(port: port, key: 'zzzzzzzz23456789', allowLan: false);
    expect(
      (await _get('http://127.0.0.1:$port/obs?k=$_key')).$1,
      HttpStatus.forbidden,
    );
  });
}
