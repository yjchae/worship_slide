import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/singer_web_server.dart';

const testPin = '1234';

/// 테스트 요청엔 늘 맞는 PIN 쿠키를 싣는다(싱어 쪽은 쿠키를 보지 않는다).
extension on HttpClient {
  Future<HttpClientRequest> getP(Uri url) async =>
      (await getUrl(url))..cookies.add(Cookie('ws_pin', testPin));
  Future<HttpClientRequest> openP(String method, Uri url) async =>
      (await openUrl(method, url))..cookies.add(Cookie('ws_pin', testPin));
}

void main() {
  test('키 없이 고정 주소로 열리고, 실시간 갱신·지금 페이지 이미지만 내보낸다', () async {
    final server = SingerWebServer()..presenterPin = testPin;
    await server.start();
    addTearDown(server.stop);
    final url = Uri.parse(server.urlFor('127.0.0.1'));
    final base = 'http://127.0.0.1:${server.port}';
    // 주소에 키가 없다 — 껐다 켜도 같은 주소.
    expect(url.toString(), '$base/');
    expect(server.urlFor('127.0.0.1', remote: true), '$base/presenter');
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<HttpClientResponse> get(String path) async =>
        (await client.getP(Uri.parse('$base$path'))).close();

    expect((await get('/img/current')).statusCode, 404); // 아직 페이지 없음

    final page = await (await client.getP(url)).close();
    expect(await page.transform(utf8.decoder).join(), contains('EventSource'));

    final img = File('${Directory.systemTemp.createTempSync().path}/p.png')
      ..writeAsBytesSync([1, 2, 3]);
    final events = await get('/events');
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
    expect((await get('/img/current?v=old')).statusCode, 404);
    expect((await get('/img/next')).statusCode, 404);

    // 터널 주소용 폴링도 같은 내용.
    final state = await get('/state');
    expect(
      jsonDecode(
        await state.transform(utf8.decoder).join(),
      )['current']['image_path'],
      imgUrl,
    );
  });

  test('발표자 쪽(p=1)만 넘길 수 있고, 메모·확대는 발표자 쪽에만 간다', () async {
    final server = SingerWebServer()..presenterPin = testPin;
    await server.start();
    addTearDown(server.stop);
    final base = 'http://127.0.0.1:${server.port}';
    final calls = <String>[];
    server.onControl = (action, params) async {
      calls.add('$action ${params['from']}');
      server.update({
        'current': {'main_text': '다음 쪽'},
        'page_number': 2,
        'note': '여기서 기도',
        'zoom': {'on': false},
      });
    };
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<(int, String)> send(String method, String path) async {
      final res = await (await client.openP(
        method,
        Uri.parse('$base$path'),
      )).close();
      return (res.statusCode, await res.transform(utf8.decoder).join());
    }

    // 싱어 쪽으로는 못 넘긴다. GET 도 안 된다(미리 불러오기 등으로 넘어가지 않게).
    expect((await send('POST', '/control?action=next')).$1, 403);
    expect((await send('GET', '/control?p=1&action=next')).$1, 403);
    expect(calls, isEmpty);

    final (code, body) = await send('POST', '/control?p=1&action=next&from=1');
    expect(code, 200);
    expect(calls, ['next 1']);
    // 응답에 바뀐 상태가 실린다.
    expect(jsonDecode(body)['note'], '여기서 기도');

    final singer = jsonDecode((await send('GET', '/state')).$2);
    expect(singer['current']['main_text'], '다음 쪽');
    expect(singer.containsKey('note'), isFalse);
    expect(singer.containsKey('zoom'), isFalse);

    // /presenter 로 연 페이지만 제스처가 켜진다.
    final page = (await send('GET', '/presenter')).$2;
    expect(page, contains('<body class="remote">'));
    expect(
      (await send('GET', '/')).$2,
      isNot(contains('<body class="remote">')),
    );
  });

  test('메시지는 리모컨에만 가고, 메시지만 바뀌면 싱어 쪽엔 보내지 않는다', () async {
    final server = SingerWebServer()..presenterPin = testPin;
    await server.start();
    addTearDown(server.stop);
    final base = 'http://127.0.0.1:${server.port}';
    const singerK = '';
    const remoteK = '?p=1';
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<HttpClientResponse> get(String path) async =>
        (await client.getP(Uri.parse('$base$path'))).close();
    Future<Map<String, dynamic>> state(String k) async =>
        jsonDecode(await (await get('/state$k')).transform(utf8.decoder).join())
            as Map<String, dynamic>;

    // SSE 로 받은 data 줄을 모은다. 붙자마자 지금 값을 받으면(늦게 접속) 그것도 들어온다.
    Future<List<Map<String, dynamic>>> listen(String k) async {
      final got = <Map<String, dynamic>>[];
      (await get('/events$k')).transform(utf8.decoder).listen((chunk) {
        for (final line in chunk.split('\n')) {
          if (line.startsWith('data: ')) {
            got.add(jsonDecode(line.substring(6)) as Map<String, dynamic>);
          }
        }
      }, onError: (_) {}); // 끝날 때 서버를 끄면 연결이 끊긴다
      return got;
    }

    final page = {
      'current': {'main_text': '주의 인자'},
      'page_number': 1,
      'total_pages': 3,
      'note': '',
      'zoom': {'on': false},
    };
    server.update({...page, 'message': ''});
    final singerEvents = await listen(singerK);
    final remoteEvents = await listen(remoteK);
    await pumpEventQueue(times: 50);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(singerEvents, hasLength(1));
    expect(remoteEvents, hasLength(1));

    server.update({...page, 'message': '2절 반복'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(remoteEvents, hasLength(2));
    expect(remoteEvents.last['message'], '2절 반복');
    expect(singerEvents, hasLength(1));
    expect(singerEvents.single.containsKey('message'), isFalse);

    // 폴링·늦게 붙은 휴대폰도 같다.
    expect((await state(remoteK))['message'], '2절 반복');
    expect((await state(singerK)).containsKey('message'), isFalse);
    final late = await listen(remoteK);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(late.single['message'], '2절 반복');
  });

  test('썸네일러가 멈춰도 시간 제한 뒤 원본을 보내고 다음 요청은 처리된다', () async {
    final server = SingerWebServer()
      ..presenterPin = testPin
      ..thumbnailTimeout = const Duration(milliseconds: 100);
    await server.start();
    addTearDown(server.stop);
    final base = 'http://127.0.0.1:${server.port}';
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final dir = Directory.systemTemp.createTempSync('thumb_timeout');
    final stuck = File('${dir.path}/0001.png')..writeAsBytesSync([1, 2, 3]);
    final ok = File('${dir.path}/0002.png')..writeAsBytesSync([4, 5, 6]);
    final never = Completer<List<int>?>();
    server.thumbnailer = (path) =>
        path == stuck.path ? never.future : Future.value([9]);
    server.update({
      'current': {'main_text': ''},
      'pages': [
        {'id': 'a', 'text': '', 'image': stuck.path},
        {'id': 'b', 'text': '', 'image': ok.path},
      ],
    });
    final list =
        jsonDecode(
              await (await (await client.getP(
                Uri.parse('$base/pages?p=1'),
              )).close()).transform(utf8.decoder).join(),
            )
            as Map;
    Future<List<int>> img(int i) async {
      final url = (list['pages'] as List)[i]['image'] as String;
      final res = await (await client.getP(Uri.parse('$base$url'))).close();
      expect(res.statusCode, 200);
      return res.expand((b) => b).toList();
    }

    final both = await Future.wait([img(0), img(1)]);
    expect(both[0], [1, 2, 3]); // 멈춘 쪽은 원본
    expect(both[1], [9]); // 뒤 요청은 막히지 않는다
  });

  test('발표자 모드 페이지 목록·썸네일은 발표자 쪽(p=1)만, 로컬 경로 없이', () async {
    final server = SingerWebServer()..presenterPin = testPin;
    await server.start();
    addTearDown(server.stop);
    final base = 'http://127.0.0.1:${server.port}';
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<HttpClientResponse> get(String path) async =>
        (await client.getP(Uri.parse('$base$path'))).close();
    Future<String> body(String path) async =>
        (await get(path)).transform(utf8.decoder).join();

    final dir = Directory.systemTemp.createTempSync('Application Support');
    final img = File('${dir.path}/0001.png')..writeAsBytesSync([1, 2, 3]);
    final pages = [
      {'id': '-1:0:false', 'text': '', 'image': null, 'blank': true},
      {'id': '5:0:false', 'text': '주의 인자', 'image': null},
      {'id': '7:0:false', 'text': '', 'image': img.path},
    ];
    var thumbCalls = 0;
    var inFlight = 0;
    server.thumbnailer = (path) async {
      thumbCalls++;
      inFlight++;
      expect(inFlight, 1); // 줄이기는 하나씩 차례로
      await Future<void>.delayed(const Duration(milliseconds: 30));
      inFlight--;
      return [9, 9];
    };
    final base0 = {
      'current': {'main_text': '주의 인자'},
      'page_number': 2,
      'message': '2절 반복',
      'message_id': 3,
    };
    server.update({...base0, 'pages': pages});

    // 싱어 쪽: 목록·썸네일 403, JSON 에 목록·메시지 없음.
    final pageUrl = '/img/page/2';
    expect((await get('/pages')).statusCode, 403);
    expect((await get('$pageUrl?v=x')).statusCode, 403);
    final singer = jsonDecode(await body('/state')) as Map;
    for (final key in ['pages', 'pages_rev', 'message', 'message_id']) {
      expect(singer.containsKey(key), isFalse, reason: key);
    }

    // 발표자 쪽: JSON 엔 판 값만, 목록엔 로컬 경로 없음.
    final remote = jsonDecode(await body('/state?p=1')) as Map;
    expect(remote.containsKey('pages'), isFalse);
    expect(remote['message_id'], 3);
    final rev = remote['pages_rev'] as String;
    expect(rev, isNotEmpty);
    final listText = await body('/pages?p=1');
    expect(listText, isNot(contains(dir.path)));
    for (final bad in ['/Users/', r'C:\\', 'Application Support']) {
      expect(listText, isNot(contains(bad)));
    }
    final list = jsonDecode(listText) as Map;
    expect(list['rev'], rev);
    final got = (list['pages'] as List).cast<Map>();
    expect(got[1]['text'], '주의 인자');
    expect(got[1]['image'], isNull);
    final imgUrl = got[2]['image'] as String;
    expect(imgUrl, matches(RegExp(r'^/img/page/2\?v=[0-9a-f]+&p=1$')));

    // 지금 목록 번호 + 맞는 v 일 때만. 동시에 와도 한 번만 줄인다.
    final res = await Future.wait([get(imgUrl), get(imgUrl)]);
    for (final r in res) {
      expect(r.statusCode, 200);
      expect(r.headers.value('cache-control'), 'private, max-age=3600');
      expect(await r.expand((b) => b).toList(), [9, 9]);
    }
    expect(thumbCalls, 1);
    final v = Uri.parse(imgUrl).queryParameters['v'];
    expect((await get('$pageUrl?v=old&p=1')).statusCode, 404);
    expect((await get('/img/page/1?v=$v&p=1')).statusCode, 404);
    expect((await get('/img/page/3?v=$v&p=1')).statusCode, 404);
    expect((await get('/img/page/x?v=$v&p=1')).statusCode, 404);

    // 썸네일러가 없으면 원본 그대로.
    server.thumbnailer = null;
    server.update({
      ...base0,
      'pages': [...pages],
    });
    final orig = await get(imgUrl);
    expect(orig.statusCode, 200);
    expect(await orig.expand((b) => b).toList(), [9, 9]); // 기억한 썸네일
    await server.stop();
    await server.start();
    final b2 = 'http://127.0.0.1:${server.port}';
    server.update({...base0, 'pages': pages});
    final raw = await (await client.getP(
      Uri.parse('$b2/img/page/2?v=$v&p=1'),
    )).close();
    expect(await raw.expand((b) => b).toList(), [1, 2, 3]); // 끌 때 캐시도 비웠다

    // 목록이 같으면 판 값 그대로, 페이지를 빼거나 넣으면 바뀐다.
    Future<String> revNow() async =>
        (jsonDecode(
                  await (await (await client.getP(
                    Uri.parse('$b2/state?p=1'),
                  )).close()).transform(utf8.decoder).join(),
                )
                as Map)['pages_rev']
            as String;
    final rev2 = await revNow();
    server.update({
      ...base0,
      'page_number': 3,
      'pages': [...pages],
    });
    expect(await revNow(), rev2);
    server.update({...base0, 'pages': pages.sublist(1)});
    expect(await revNow(), isNot(rev2));
    server.update({
      ...base0,
      'pages': [...pages, pages[1]],
    });
    expect(await revNow(), isNot(rev2));
  });

  test('goto 는 발표자 쪽(p=1) POST 로만 id 를 넘긴다', () async {
    final server = SingerWebServer()..presenterPin = testPin;
    await server.start();
    addTearDown(server.stop);
    final base = 'http://127.0.0.1:${server.port}';
    const singerK = '';
    const remoteK = 'p=1&';
    final ids = ['-1:0:false', '5:0:false', '5:1:false'];
    var current = 0;
    server.onControl = (action, params) async {
      if (action != 'goto') return;
      final i = ids.indexOf(params['id'] ?? '');
      if (i < 0) return; // 없는 키는 그대로
      current = i;
      server.update({'page_number': current + 1});
    };
    server.update({'page_number': 1});
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<(int, Map)> send(String method, String k, String id) async {
      final res = await (await client.openP(
        method,
        Uri.parse('$base/control?${k}action=goto&id=$id'),
      )).close();
      final text = await res.transform(utf8.decoder).join();
      return (
        res.statusCode,
        res.statusCode == 200 ? jsonDecode(text) as Map : {},
      );
    }

    expect((await send('POST', singerK, '5:1:false')).$1, 403);
    expect((await send('GET', remoteK, '5:1:false')).$1, 403);
    expect(current, 0);
    final (code, state) = await send('POST', remoteK, '5:1:false');
    expect(code, 200);
    expect(state['page_number'], 3);
    expect((await send('POST', remoteK, '9:9:false')).$2['page_number'], 3);
  });

  test('다른 프로그램이 127.0.0.1:8765 만 잡고 있으면 다른 포트로 켠다 (터널이 그쪽으로 새지 않게)', () async {
    ServerSocket? holder;
    try {
      holder = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        SingerWebServer.preferredPort,
      );
      addTearDown(holder.close);
    } on SocketException {
      // 이미 누가 잡고 있으면 그대로 시험이 된다.
    }
    final server = SingerWebServer()..presenterPin = testPin;
    addTearDown(server.stop);
    await server.start();
    expect(server.port, isNot(SingerWebServer.preferredPort));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final res = await (await client.getP(
      Uri.parse('http://127.0.0.1:${server.port}/'),
    )).close();
    expect(res.statusCode, 200);
    expect(await res.transform(utf8.decoder).join(), contains('EventSource'));
  });

  test('끄고 바로 켜도, 두 번 켜도 서버는 하나이고 이전 이미지는 남지 않는다', () async {
    final server = SingerWebServer()..presenterPin = testPin;
    addTearDown(server.stop);
    var portTaken = false;
    try {
      await (await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        SingerWebServer.preferredPort,
      )).close();
    } on SocketException {
      portTaken = true;
    }
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
    // 이 PC 의 다른 프로그램이 8765 를 쓰고 있으면 다른 포트로 켜지는 게 맞다.
    if (!portTaken) expect(server.port, SingerWebServer.preferredPort);
    expect(server.running.value, isTrue);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final res = await (await client.getP(
      Uri.parse('http://127.0.0.1:${server.port}/img/current'),
    )).close();
    expect(res.statusCode, 404);
  });

  test('발표자 쪽은 PIN 쿠키가 있어야 하고, PIN 을 바꾸면 다시 묻는다', () async {
    final server = SingerWebServer()..presenterPin = testPin;
    await server.start();
    addTearDown(server.stop);
    server.onControl = (action, params) async {};
    server.update({
      'current': {'main_text': '주의 인자'},
      'note': '여기서 기도',
    });
    final base = 'http://127.0.0.1:${server.port}';
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<(int, String, HttpClientResponse)> send(
      String method,
      String path, {
      String? cookie,
      String? body,
      String? origin,
    }) async {
      final req = await client.openUrl(method, Uri.parse('$base$path'))
        ..followRedirects = false;
      if (cookie != null) req.cookies.add(Cookie('ws_pin', cookie));
      if (origin != null) req.headers.set('origin', origin);
      if (body != null) {
        req.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        );
        req.write(body);
      }
      final res = await req.close();
      return (res.statusCode, await res.transform(utf8.decoder).join(), res);
    }

    // 싱어 쪽은 PIN 없이 열린다.
    expect((await send('GET', '/')).$1, 200);
    expect((await send('GET', '/state')).$1, 200);
    // 발표자 쪽: 쿠키 없음·틀린 쿠키 = 401, 화면은 PIN 입력 페이지.
    for (final c in [null, '9999']) {
      expect((await send('GET', '/state?p=1', cookie: c)).$1, 401);
      expect((await send('GET', '/events?p=1', cookie: c)).$1, 401);
      expect((await send('GET', '/pages?p=1', cookie: c)).$1, 401);
      expect(
        (await send('POST', '/control?p=1&action=next', cookie: c)).$1,
        401,
      );
      final page = (await send('GET', '/presenter', cookie: c)).$2;
      expect(page, contains('action="/login"'));
      expect(page, isNot(contains('<body class="remote">')));
    }

    // 틀린 PIN → 401 + 안내, 맞는 PIN → 쿠키 + /presenter 로.
    final wrong = await send('POST', '/login', body: 'pin=0000');
    expect(wrong.$1, 401);
    expect(wrong.$2, contains('PIN 이 맞지 않습니다'));
    final ok = await send('POST', '/login', body: 'pin=$testPin');
    expect(ok.$1, 303);
    expect(ok.$3.headers.value('location'), '/presenter');
    final cookie = ok.$3.cookies.singleWhere((c) => c.name == 'ws_pin');
    expect(cookie.value, testPin);
    expect(cookie.httpOnly, isTrue);
    expect(
      (await send('GET', '/presenter', cookie: cookie.value)).$2,
      contains('<body class="remote">'),
    );
    expect(
      jsonDecode((await send('GET', '/state?p=1', cookie: testPin)).$2)['note'],
      '여기서 기도',
    );

    // 다른 사이트에서 온 POST 는 PIN 이 맞아도 막는다.
    expect(
      (await send(
        'POST',
        '/control?p=1&action=next',
        cookie: testPin,
        origin: 'http://evil.example',
      )).$1,
      403,
    );
    expect(
      (await send(
        'POST',
        '/control?p=1&action=next',
        cookie: testPin,
        origin: base,
      )).$1,
      200,
    );

    // PC 에서 PIN 을 바꾸면 옛 쿠키는 401.
    server.presenterPin = '5678';
    expect((await send('GET', '/state?p=1', cookie: testPin)).$1, 401);
    expect((await send('GET', '/state?p=1', cookie: '5678')).$1, 200);
  });

  test('PIN 을 여러 번 틀리면 잠깐 받지 않는다', () async {
    final server = SingerWebServer()..presenterPin = testPin;
    await server.start();
    addTearDown(server.stop);
    final base = 'http://127.0.0.1:${server.port}';
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<int> login(String pin) async {
      final req = await client.postUrl(Uri.parse('$base/login'))
        ..followRedirects = false
        ..headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        )
        ..write('pin=$pin');
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }

    // 깨진 본문·너무 긴 본문은 틀린 PIN 으로 보고 응답한다(멈추지 않는다).
    Future<int> raw(List<int> body) async {
      final req = await client.postUrl(Uri.parse('$base/login'))
        ..followRedirects = false
        ..headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        )
        ..add(body);
      final res = await req.close().timeout(const Duration(seconds: 3));
      await res.drain<void>();
      return res.statusCode;
    }

    expect(await raw(utf8.encode('pin=%ZZ')), 401);
    expect(await raw([0x70, 0x69, 0x6e, 0x3d, 0xff, 0xfe]), 401);
    expect(await raw(List.filled(100000, 0x31)), 401);
    // 위 3번도 틀린 횟수로 센다.
    for (var i = 0; i < SingerWebServer.maxPinFailures - 3; i++) {
      expect(await login('0000'), 401);
    }
    // 잠긴 동안은 맞는 PIN 도 안 된다.
    expect(await login(testPin), 401);
  });

  test('PIN 이 정해지지 않았으면 발표자 쪽은 아무도 못 들어온다', () async {
    final server = SingerWebServer();
    await server.start();
    addTearDown(server.stop);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final req =
        await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/state?p=1'),
          )
          ..cookies.add(Cookie('ws_pin', ''));
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 401);
  });

  test('휴대폰이 닿는 사설망 주소·실제 네트워크만 고른다', () {
    expect(SingerWebServer.isPrivateIPv4('192.168.0.12'), isTrue);
    expect(SingerWebServer.isPrivateIPv4('10.0.0.5'), isTrue);
    expect(SingerWebServer.isPrivateIPv4('172.20.1.1'), isTrue);
    expect(SingerWebServer.isPrivateIPv4('172.32.1.1'), isFalse);
    expect(SingerWebServer.isPrivateIPv4('100.64.1.2'), isFalse); // VPN(CGNAT)
    expect(SingerWebServer.isPrivateIPv4('8.8.8.8'), isFalse);
    expect(SingerWebServer.isVirtualInterface('utun3'), isTrue);
    expect(
      SingerWebServer.isVirtualInterface('bridge100'),
      isTrue,
    ); // Parallels
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
