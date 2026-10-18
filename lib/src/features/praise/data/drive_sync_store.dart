import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'sync_store.dart';

/// 관리자가 `scripts/make_sync_key.py` 로 만들어 사용자들에게 따로 건네는 접속 키.
/// `WS1-` + base64url(JSON) 한 줄에 OAuth 클라이언트·refresh token·폴더가 다 들어 있어서
/// PC 에서는 이 줄을 한 번 붙여 넣기만 하면 된다(구글 로그인 없음). 모든 PC 가 관리자 계정으로
/// 접속하지만 권한이 `drive.file` 이라 이 앱이 만든 파일(= 동기화 폴더)만 보인다.
/// 키는 git 에 두지 않는다 — PC 의 `Application Support/sync_key.txt` 에만 있다.
class DriveKey {
  const DriveKey({
    required this.clientId,
    required this.clientSecret,
    required this.refreshToken,
    required this.folderId,
    required this.folderName,
  });

  static const prefix = 'WS1-';

  final String clientId;
  final String clientSecret;
  final String refreshToken;
  final String folderId;
  final String folderName;

  /// 모양이 틀리면 [FormatException].
  static DriveKey parse(String text) {
    final compact = text.replaceAll(RegExp(r'\s'), '');
    if (!compact.startsWith(prefix)) {
      throw const FormatException('접속 키 모양이 아닙니다(WS1- 로 시작해야 합니다).');
    }
    final Object? json;
    try {
      json = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(compact.substring(prefix.length))),
        ),
      );
    } catch (_) {
      throw const FormatException('접속 키가 잘렸거나 잘못 복사되었습니다.');
    }
    String field(String key) {
      final v = json is Map ? json[key] : null;
      if (v is! String || v.isEmpty) {
        throw const FormatException('접속 키가 잘렸거나 잘못 복사되었습니다.');
      }
      return v;
    }

    return DriveKey(
      clientId: field('client_id'),
      clientSecret: field('client_secret'),
      refreshToken: field('refresh_token'),
      folderId: field('folder_id'),
      folderName: json is Map && json['folder_name'] is String
          ? json['folder_name'] as String
          : '구글 드라이브',
    );
  }
}

/// 구글 드라이브 폴더 하나를 [SyncStore] 로 쓴다(Drive REST v3).
/// 드라이브는 같은 이름 파일을 여럿 둘 수 있다 — 쓸 때는 있으면 가장 최근 것을 바꾸고,
/// 지울 때는 같은 이름을 모두 지운다.
class DriveSyncStore implements SyncStore {
  DriveSyncStore(this.key, {http.Client? client})
    : _client = client ?? http.Client();

  final DriveKey key;
  final http.Client _client;

  static const _api = 'https://www.googleapis.com/drive/v3/files';
  static const _uploadApi = 'https://www.googleapis.com/upload/drive/v3/files';
  static const _fields = 'id,name,modifiedTime,size';

  /// 응답 머리가 올 때까지 기다리는 시간 — 끊긴 연결에 동기화 큐가 영영 묶이지 않게.
  /// 올리기(PUT)는 본문을 다 보낸 뒤에야 머리가 오므로 걸지 않는다.
  static const _timeout = Duration(seconds: 30);

  String? _token;
  DateTime _tokenUntil = DateTime(0);

  @override
  String get label => '구글 드라이브 · ${key.folderName}';

  static FileSystemException _offline() => const FileSystemException(
    '구글 드라이브에 연결하지 못했습니다. 인터넷 연결을 확인해 주세요.',
  );

  Future<String> _accessToken() async {
    if (_token != null && DateTime.now().isBefore(_tokenUntil)) return _token!;
    final http.Response res;
    try {
      res = await _client.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        body: {
          'client_id': key.clientId,
          'client_secret': key.clientSecret,
          'refresh_token': key.refreshToken,
          'grant_type': 'refresh_token',
        },
      ).timeout(_timeout);
    } on SocketException {
      throw _offline();
    } on http.ClientException {
      throw _offline();
    } on TimeoutException {
      throw _offline();
    }
    final json = _json(res.body);
    if (res.statusCode != 200 || json['access_token'] is! String) {
      throw FileSystemException(
        res.statusCode == 400 || res.statusCode == 401
            ? '접속 키를 더 이상 쓸 수 없습니다(취소·만료). 관리자에게 새 키를 받아 넣어 주세요.'
            : '구글 로그인 서버 오류 (${res.statusCode})',
      );
    }
    final expires = json['expires_in'] is int ? json['expires_in'] as int : 3600;
    _token = json['access_token'] as String;
    _tokenUntil = DateTime.now().add(Duration(seconds: expires - 60));
    return _token!;
  }

  static Map<String, Object?> _json(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map<String, Object?> ? v : const {};
    } catch (_) {
      return const {};
    }
  }

  /// 요청을 보내고 2xx 가 아니면 던진다. 받아 둔 토큰이 만료 전에 무효가 되면(401) 새로 받아
  /// 한 번 더 보낸다 — 본문을 흘려보내는 올리기(StreamedRequest)는 다시 못 보내므로 빼고.
  Future<http.StreamedResponse> _send(
    http.BaseRequest req, {
    bool retried = false,
  }) async {
    req.headers['Authorization'] = 'Bearer ${await _accessToken()}';
    final http.StreamedResponse res;
    try {
      final sending = _client.send(req);
      res = await (req is http.StreamedRequest
          ? sending
          : sending.timeout(_timeout));
    } on SocketException {
      throw _offline();
    } on http.ClientException {
      throw _offline();
    } on TimeoutException {
      throw _offline();
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    if (res.statusCode == 401 && !retried && req is http.Request) {
      await res.stream.drain<void>().catchError((_) {});
      _token = null;
      return _send(
        http.Request(req.method, req.url)
          ..headers.addAll(req.headers)
          ..bodyBytes = req.bodyBytes,
        retried: true,
      );
    }
    final body = await res.stream.bytesToString().catchError((_) => '');
    final error = _json(body)['error'];
    final message = error is Map ? error['message'] : null;
    throw FileSystemException(
      res.statusCode == 404
          ? '구글 드라이브에서 동기화 폴더나 파일을 찾지 못했습니다.'
          : '구글 드라이브 오류 (${res.statusCode})${message is String ? ': $message' : ''}',
    );
  }

  /// 본문을 다 받는다. 받다가 끊기면 [FileSystemException] — 부르는 쪽은 그것만 잡는다.
  static Future<List<int>> _bytes(http.StreamedResponse res) async {
    try {
      return await res.stream.toBytes();
    } on SocketException {
      throw _offline();
    } on http.ClientException {
      throw _offline();
    }
  }

  static Future<String> _text(http.StreamedResponse res) async =>
      utf8.decode(await _bytes(res), allowMalformed: true);

  Future<Map<String, Object?>> _getJson(Uri uri) async =>
      _json(await _text(await _send(http.Request('GET', uri))));

  static SyncEntry _entry(Map<String, Object?> f) => SyncEntry(
    name: f['name'] as String? ?? '',
    id: f['id'] as String? ?? '',
    modified:
        DateTime.tryParse(f['modifiedTime'] as String? ?? '') ?? DateTime(0),
    size: int.tryParse(f['size'] as String? ?? '') ?? 0,
  );

  @override
  Future<void> check() async {
    final f = await _getJson(
      Uri.parse(
        '$_api/${key.folderId}?fields=id,trashed&supportsAllDrives=true',
      ),
    );
    if (f['trashed'] == true) {
      throw const FileSystemException('구글 드라이브의 동기화 폴더가 휴지통에 있습니다.');
    }
  }

  Future<List<SyncEntry>> _query(String q) async {
    final result = <SyncEntry>[];
    String? page;
    do {
      final json = await _getJson(
        Uri.parse(_api).replace(
          queryParameters: {
            'q': "'${key.folderId}' in parents and trashed = false$q",
            'fields': 'nextPageToken,files($_fields)',
            'pageSize': '1000',
            'supportsAllDrives': 'true',
            'includeItemsFromAllDrives': 'true',
            'pageToken': ?page,
          },
        ),
      );
      final files = json['files'];
      if (files is List) {
        result.addAll(files.whereType<Map<String, Object?>>().map(_entry));
      }
      page = json['nextPageToken'] as String?;
    } while (page != null);
    return result;
  }

  /// 같은 이름이 여럿이면 가장 최근 것 하나만 — 쓸 때 바꾸는 것도 그것이다([_named]).
  @override
  Future<List<SyncEntry>> list() async {
    final newest = <String, SyncEntry>{};
    for (final e in await _query('')) {
      final seen = newest[e.name];
      if (seen == null || e.modified.isAfter(seen.modified)) newest[e.name] = e;
    }
    return newest.values.toList();
  }

  /// 이름 검색 — 이름은 늘 앱이 만든 것(hex·`conti_`·확장자)이라 따옴표가 들어가지 않는다.
  Future<List<SyncEntry>> _named(String name) async =>
      (await _query(" and name = '$name'"))
        ..sort((a, b) => b.modified.compareTo(a.modified));

  Uri _media(SyncEntry entry) =>
      Uri.parse('$_api/${entry.id}?alt=media&supportsAllDrives=true');

  @override
  Future<String> read(SyncEntry entry) async =>
      _text(await _send(http.Request('GET', _media(entry))));

  @override
  Future<void> download(SyncEntry entry, File to) async {
    final res = await _send(http.Request('GET', _media(entry)));
    final sink = to.openWrite();
    try {
      await sink.addStream(res.stream);
    } on SocketException {
      throw _offline();
    } on http.ClientException {
      throw _offline();
    } finally {
      // 실패해도 닫는다 — 열린 채면 Windows 에서 임시 폴더를 못 지운다.
      await sink.close().catchError((_) {});
    }
  }

  /// 이어 올리기(resumable) 한 번에 다 보낸다 — 단순 올리기는 5MB 까지라 콘티(수백 MB)를 못 올린다.
  /// 드라이브는 다 받은 뒤에 내용을 바꾸므로 다른 PC 가 반쯤 올린 파일을 읽지 않는다.
  Future<SyncEntry> _put(
    String name,
    int length,
    Stream<List<int>> Function() body,
  ) async {
    final existing = await _named(name);
    final start = existing.isEmpty
        ? http.Request(
            'POST',
            Uri.parse(
              '$_uploadApi?uploadType=resumable&supportsAllDrives=true&fields=$_fields',
            ),
          )
        : http.Request(
            'PATCH',
            Uri.parse(
              '$_uploadApi/${existing.first.id}?uploadType=resumable&supportsAllDrives=true&fields=$_fields',
            ),
          );
    start.headers['Content-Type'] = 'application/json; charset=UTF-8';
    start.headers['X-Upload-Content-Length'] = '$length';
    start.body = jsonEncode(
      existing.isEmpty
          ? {
              'name': name,
              'parents': [key.folderId],
            }
          : const {},
    );
    final started = await _send(start);
    await started.stream.drain<void>();
    final location = started.headers['location'];
    if (location == null) {
      throw const FileSystemException('구글 드라이브가 올리기 주소를 주지 않았습니다.');
    }
    final upload = http.StreamedRequest('PUT', Uri.parse(location))
      ..contentLength = length;
    final sent = _send(upload);
    // addStream 은 보내는 쪽이 밀리면 파일 읽기를 멈춘다(listen + add 는 수백 MB 를 메모리에 쌓는다).
    unawaited(upload.sink.addStream(body()).then((_) => upload.sink.close()));
    final res = await sent;
    return _entry(_json(await _text(res)));
  }

  @override
  Future<SyncEntry> write(String name, String text) {
    final bytes = utf8.encode(text);
    return _put(name, bytes.length, () => Stream.value(bytes));
  }

  @override
  Future<SyncEntry> upload(String name, File from) async =>
      _put(name, await from.length(), from.openRead);

  @override
  Future<void> delete(String name) async {
    for (final entry in await _named(name)) {
      final res = await _send(
        http.Request(
          'DELETE',
          Uri.parse('$_api/${entry.id}?supportsAllDrives=true'),
        ),
      );
      await res.stream.drain<void>();
    }
  }
}
