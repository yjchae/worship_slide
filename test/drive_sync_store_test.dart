import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:worship_slides/src/features/praise/data/drive_sync_store.dart';
import 'package:worship_slides/src/features/praise/data/sync_store.dart';

/// Drive REST 를 흉내 내는 아주 작은 서버(폴더 하나).
class _FakeDrive {
  final files = <String, ({String name, List<int> body, DateTime at})>{};
  var revoked = false;

  /// 다음 Drive 요청 하나에 401 을 돌려준다(토큰이 일찍 무효가 된 경우).
  var staleOnce = false;
  var tokenRequests = 0;
  var _next = 0;

  Map<String, Object?> _meta(String id) => {
    'id': id,
    'name': files[id]!.name,
    'modifiedTime': files[id]!.at.toUtc().toIso8601String(),
    'size': '${files[id]!.body.length}',
  };

  late final client = MockClient((req) async {
    final u = req.url;
    if (u.host == 'oauth2.googleapis.com') {
      tokenRequests += 1;
      return revoked
          ? http.Response('{"error":"invalid_grant"}', 400)
          : http.Response('{"access_token":"t","expires_in":3600}', 200);
    }
    expect(req.headers['Authorization'], 'Bearer t');
    if (staleOnce) {
      staleOnce = false;
      return http.Response('{}', 401);
    }
    final path = u.pathSegments;
    if (u.host == 'upload.test') {
      final id = u.queryParameters['id'] ?? 'f${_next++}';
      files[id] = (
        name: u.queryParameters['name'] ?? files[id]!.name,
        body: req.bodyBytes,
        at: DateTime.now(),
      );
      return http.Response(jsonEncode(_meta(id)), 200);
    }
    if (path.first == 'upload') {
      final location = req.method == 'POST'
          ? 'https://upload.test/?name=${(jsonDecode(req.body) as Map)['name']}'
          : 'https://upload.test/?id=${path.last}';
      return http.Response('', 200, headers: {'location': location});
    }
    if (path.last == 'files') {
      final q = u.queryParameters['q']!;
      final name = RegExp(r"name = '([^']+)'").firstMatch(q)?.group(1);
      return http.Response(
        jsonEncode({
          'files': [
            for (final id in files.keys)
              if (name == null || files[id]!.name == name) _meta(id),
          ],
        }),
        200,
      );
    }
    final id = path.last;
    if (id == 'folder') return http.Response('{"id":"folder"}', 200);
    if (!files.containsKey(id)) return http.Response('{}', 404);
    if (req.method == 'DELETE') {
      files.remove(id);
      return http.Response('', 204);
    }
    return http.Response.bytes(files[id]!.body, 200);
  });
}

String _key() =>
    DriveKey.prefix +
    base64Url.encode(
      utf8.encode(
        jsonEncode({
          'client_id': 'c',
          'client_secret': 's',
          'refresh_token': 'r',
          'folder_id': 'folder',
          'folder_name': '찬양 동기화',
        }),
      ),
    );

void main() {
  test('접속 키: 줄바꿈이 섞여도 읽고, 잘린 키는 거절한다', () {
    final key = _key();
    final parsed = DriveKey.parse(
      '  ${key.substring(0, 10)}\n${key.substring(10)} ',
    );
    expect(parsed.folderId, 'folder');
    expect(parsed.folderName, '찬양 동기화');
    expect(() => DriveKey.parse('abc'), throwsFormatException);
    expect(
      () => DriveKey.parse(key.substring(0, key.length - 8)),
      throwsFormatException,
    );
  });

  test('쓰기·덮어쓰기·읽기·올리기·내려받기·지우기', () async {
    final drive = _FakeDrive();
    final store = DriveSyncStore(DriveKey.parse(_key()), client: drive.client);
    await store.check();
    final first = await store.write('a.json', '하나');
    await store.write('a.json', '둘');
    expect(drive.files, hasLength(1)); // 같은 이름은 새로 만들지 않고 바꾼다
    final listed = (await store.list()).single;
    expect(listed.id, first.id);
    expect(await store.read(listed), '둘');

    final tmp = await Directory.systemTemp.createTemp('drive_test_');
    addTearDown(() => tmp.delete(recursive: true));
    final src = File('${tmp.path}/src')..writeAsBytesSync([1, 2, 3]);
    final up = await store.upload('conti_x.wsconti', src);
    final out = File('${tmp.path}/out');
    await store.download(up, out);
    expect(out.readAsBytesSync(), [1, 2, 3]);

    await store.delete('a.json');
    expect((await store.list()).map((e) => e.name), ['conti_x.wsconti']);
  });

  test('취소된 키는 알아볼 수 있는 오류로 막는다', () async {
    final drive = _FakeDrive()..revoked = true;
    final store = DriveSyncStore(DriveKey.parse(_key()), client: drive.client);
    await expectLater(
      store.check(),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          contains('새 키'),
        ),
      ),
    );
  });

  test('토큰이 일찍 무효가 되면(401) 새로 받아 한 번 더 보낸다', () async {
    final drive = _FakeDrive();
    final store = DriveSyncStore(DriveKey.parse(_key()), client: drive.client);
    await store.check();
    drive.staleOnce = true;
    await store.check();
    expect(drive.tokenRequests, 2);
  });

  test('멈춘 요청(올리기 포함)은 cancel 로 끊기고 "취소했습니다" 로 실패한다', () async {
    // 토큰만 주고 나머지는 끊길 때까지 응답이 없다(연결이 멎은 것처럼).
    final client = _StuckClient();
    final store = DriveSyncStore(DriveKey.parse(_key()), client: client);
    final checking = store.check();
    final uploading = store.write('a.json', '{}');
    await client.stuck.future;
    while (client.waiting < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    store.cancel();
    for (final job in [checking, uploading]) {
      await expectLater(
        job,
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            cancelledMessage,
          ),
        ),
      );
    }
    // 취소한 뒤 같은 작업이 이어서 보내는 요청도 끊긴다(요청 사이에 누른 취소).
    client.answer = true;
    await expectLater(store.check(), throwsA(isA<FileSystemException>()));
    // 다음 작업을 시작하면(resetCancel) 다시 보낸다.
    store.resetCancel();
    await store.check();
  });
}

/// 토큰·목록·올리기 시작은 주고, 폴더 확인·올리기 본문(PUT)은 [answer] 가 아니면 abortTrigger 가 올 때까지 붙잡는다.
class _StuckClient extends http.BaseClient {
  final stuck = Completer<void>();
  var waiting = 0;
  var answer = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Future<http.StreamedResponse> ok(String body) async =>
        http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
    if (request.url.host == 'oauth2.googleapis.com') {
      return ok('{"access_token":"t","expires_in":3600}');
    }
    // 올리기는 시작(POST)까지 받아 주고 본문 보내기(PUT)에서 멎는다.
    if (request.method == 'POST') {
      return http.StreamedResponse(
        const Stream.empty(),
        200,
        headers: {'location': 'https://upload.test/'},
      );
    }
    if (request.url.pathSegments.lastOrNull == 'files') {
      return ok('{"files":[]}');
    }
    if (answer) return ok('{"id":"folder"}');
    final trigger = (request as http.Abortable).abortTrigger!;
    waiting += 1;
    if (!stuck.isCompleted) stuck.complete();
    await trigger;
    throw http.RequestAbortedException(request.url);
  }
}
