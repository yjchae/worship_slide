import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/singer_web_server.dart';

void main() {
  test('토큰이 맞아야 하고, 실시간 갱신·지금 페이지 이미지만 내보낸다', () async {
    final server = SingerWebServer();
    await server.start();
    addTearDown(server.stop);
    final url = Uri.parse(server.urlFor('127.0.0.1'));
    final base = 'http://127.0.0.1:${server.port}';
    final k = url.queryParameters['k']!;
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<HttpClientResponse> get(String path) async =>
        (await client.getUrl(Uri.parse('$base$path'))).close();

    // 토큰 없이는 아무것도 못 본다.
    expect((await get('/')).statusCode, 403);
    expect((await get('/events')).statusCode, 403);
    expect((await get('/img/current')).statusCode, 403);

    final page = await (await client.getUrl(url)).close();
    expect(await page.transform(utf8.decoder).join(), contains('EventSource'));

    final img = File('${Directory.systemTemp.createTempSync().path}/p.png')
      ..writeAsBytesSync([1, 2, 3]);
    final events = await get('/events?k=$k');
    final got = Completer<Map<String, dynamic>>();
    events.transform(utf8.decoder).listen((chunk) {
      for (final line in chunk.split('\n')) {
        if (line.startsWith('data: ') && !got.isCompleted) {
          got.complete(jsonDecode(line.substring(6)) as Map<String, dynamic>);
        }
      }
    }, onError: (_) {}); // 끝날 때 서버를 끄면 연결이 끊긴다
    server.update({
      'current': {'main_text': '주의 인자', 'image_path': img.path},
      'next': null,
      'page_number': 1,
      'total_pages': 3,
      'blackout': false,
    });
    final data = await got.future.timeout(const Duration(seconds: 3));
    expect(data['current']['main_text'], '주의 인자');
    final imgUrl = data['current']['image_path'] as String;
    // 로컬 경로는 밖으로 나가지 않는다.
    expect(imgUrl, startsWith('/img/current'));

    final bytes = await get(imgUrl);
    expect(bytes.headers.value('cache-control'), 'no-store');
    expect(await bytes.expand((b) => b).toList(), [1, 2, 3]);
    // 버전이 다르면(그 사이 페이지가 넘어감) 주지 않는다.
    expect((await get('/img/current?v=old&k=$k')).statusCode, 404);
    expect((await get('/img/next?k=$k')).statusCode, 404);

    // 터널 주소용 폴링도 같은 내용, 토큰 필요.
    expect((await get('/state')).statusCode, 403);
    final state = await get('/state?k=$k');
    expect(
      jsonDecode(
        await state.transform(utf8.decoder).join(),
      )['current']['image_path'],
      imgUrl,
    );
  });

  test('끄고 바로 켜도, 두 번 켜도 서버는 하나이고 이전 이미지는 남지 않는다', () async {
    final server = SingerWebServer();
    addTearDown(server.stop);
    await server.start();
    final img = File('${Directory.systemTemp.createTempSync().path}/p.png')
      ..writeAsBytesSync([1]);
    server.update({
      'current': {'image_path': img.path},
    });
    // 기다리지 않고 연달아 부른다(발표 종료 직후 다시 켜기·버튼 두 번).
    unawaited(server.stop());
    unawaited(server.start());
    await server.start();
    expect(server.isRunning, isTrue);
    expect(server.port, SingerWebServer.preferredPort);
    expect(server.running.value, isTrue);
    final k = Uri.parse(server.urlFor('127.0.0.1')).queryParameters['k'];
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final res = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/img/current?k=$k'),
    )).close();
    expect(res.statusCode, 404);
  });

  test('휴대폰이 닿는 사설망 주소·실제 네트워크만 고른다', () {
    expect(SingerWebServer.isPrivateIPv4('192.168.0.12'), isTrue);
    expect(SingerWebServer.isPrivateIPv4('10.0.0.5'), isTrue);
    expect(SingerWebServer.isPrivateIPv4('172.20.1.1'), isTrue);
    expect(SingerWebServer.isPrivateIPv4('172.32.1.1'), isFalse);
    expect(SingerWebServer.isPrivateIPv4('100.64.1.2'), isFalse); // VPN(CGNAT)
    expect(SingerWebServer.isPrivateIPv4('8.8.8.8'), isFalse);
    expect(SingerWebServer.isVirtualInterface('utun3'), isTrue);
    expect(SingerWebServer.isVirtualInterface('bridge100'), isTrue); // Parallels
    expect(SingerWebServer.isVirtualInterface('vEthernet (WSL)'), isTrue);
    expect(SingerWebServer.isVirtualInterface('en0'), isFalse);
    expect(SingerWebServer.isVirtualInterface('Wi-Fi'), isFalse);
  });

  test('cloudflared 로그에서 임시 터널 주소만 뽑는다', () {
    expect(
      SingerWebServer.tunnelUrlIn(
        '2026-10-15T01:02:03Z INF |  https://rich-tide-alpha-sun.trycloudflare.com                |',
      ),
      'https://rich-tide-alpha-sun.trycloudflare.com',
    );
    expect(
      SingerWebServer.tunnelUrlIn(
        'ERR failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel"',
      ),
      isNull,
    );
    expect(
      SingerWebServer.tunnelUrlIn(
        'INF Requesting new quick Tunnel on trycloudflare.com...',
      ),
      isNull,
    );
  });
}
