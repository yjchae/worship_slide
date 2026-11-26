import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'fnv_hash.dart';

/// 같은 망의 휴대폰 브라우저에서 싱어 화면(현재 + 다음 페이지)을 보게 하는 작은 HTTP 서버.
///
/// - `GET /`        싱어 페이지(HTML 하나, 외부 파일 없음)
/// - `GET /events`  Server-Sent Events. 페이지가 바뀔 때마다 [SingerViewData] JSON 을 민다.
///                  브라우저 EventSource 가 끊기면 알아서 다시 붙고, 붙자마자 지금 페이지를 받는다
/// - `GET /img/current`, `/img/next`  지금·다음 페이지 이미지(PPT 페이지).
///   **로컬 경로를 그대로 받지 않는다** — 지금 띄운 두 장만 내보내므로 망 안의 누구도 다른 파일은 못 읽는다
///
/// **키(토큰)가 없다** — `http://<IP>:<포트>/` 를 치면 누구나 싱어창을 본다. 주소가 늘 같아서(포트 8765)
/// 발표를 끝냈다 다시 시작하거나 연결이 끊겨도 휴대폰은 다시 찍을 필요 없이 저절로 다시 붙는다.
/// 같은 망(와이파이)에 있는 사람은 누구나 볼 수 있다는 뜻이다(사용자가 고른 편의 쪽).
///
/// **발표자 주소(발표자 모드·싱어창)**: `/presenter` 로 열면 넘기기·확대·블랙아웃 제스처가 켜진다.
/// 그 페이지의 요청은 `?p=1`(발표자 쪽)을 달고 온다.
/// - **PIN**: 발표자 쪽은 PC 에서 정한 4자리 [presenterPin] 이 맞아야 한다. 휴대폰이 `/presenter` 를 처음 열면
///   PIN 입력 페이지([pinPageHtml])가 나오고, `POST /login` 이 맞으면 쿠키(`ws_pin`, 1년)를 남겨 그 휴대폰은
///   다음부터 묻지 않는다. 쿠키라서 `<img>` 썸네일 요청에도 저절로 실린다. PIN 을 바꾸면 쿠키가 안 맞아
///   발표자 쪽 요청이 401 → 휴대폰 페이지가 새로 읽혀 PIN 을 다시 묻는다
/// - PIN 을 5번 틀리면 30초 동안 받지 않는다(4자리라 대입을 막으려고, 접속 주소마다)
/// - `POST` 는 Origin 이 이 서버 주소와 다르면 403 — 같은 망 기기에서 열린 다른 웹 페이지가 발표를 조작하지 못하게
/// - `POST /control?action=next|prev&from=<보던 쪽>` / `action=blackout&on=0|1` / `action=zoom&on&x&y&size`
///   → [onControl] 을 부르고 바뀐 상태 JSON 을 돌려준다
/// - 리모컨에만 가는 값(`note`·`zoom`·`message`, [remoteOnlyKeys])은 싱어 주소로 받는 쪽에서 뺀다
///
/// **발표자 모드 페이지 목록**(발표자 쪽 `?p=1` 만, 싱어 쪽은 403):
/// - [update] 의 `pages`(`phonePageList`) 는 JSON 에 싣지 않고 따로 둔다. JSON 엔 판 값 `pages_rev` 만 —
///   휴대폰은 이 값이 바뀔 때만 `GET /pages` 로 목록(`{rev, pages}`)을 다시 받는다
/// - `GET /img/page/<n>?v=` 목록 n번 그림 페이지의 썸네일([thumbnailer]). 로컬 경로는 목록에도 주소에도 없다
///
/// **바깥 망 주소**: cloudflared 가 깔려 있으면 Cloudflare 임시 터널(`*.trycloudflare.com`, 계정 불필요)을
/// 같이 띄워 https 공개 주소를 만든다. 다른 망의 휴대폰도 그 주소로 본다(임시 터널 주소는 켤 때마다 바뀐다).
/// 없으면 같은 망 주소만 쓴다(LibreOffice·Tesseract 처럼 선택 의존성).
enum TunnelState { off, missing, connecting, ready, failed }

class SingerWebServer {
  static const preferredPort = 8765;

  HttpServer? _server;
  final _clients = <HttpResponse>{};
  Timer? _ping;
  String? _lastJson; // 지금 페이지. SSE(/events)·폴링(/state) 둘 다 이걸 보낸다
  String? _lastRemoteJson; // 리모컨용(메모·확대 포함)
  final _remoteClients = <HttpResponse>{};

  static const remoteOnlyKeys = [
    'note',
    'zoom',
    'message',
    'message_id',
    'pages_rev',
  ];

  // 발표자 모드 페이지 목록. 받은 그대로의 JSON 이 같으면 다시 만들지 않는다.
  String? _pagesSource;
  String _pagesRev = '';
  String _pagesJson = '{"rev":"","pages":[]}'; // GET /pages 본문(로컬 경로 없음)
  List<String?> _pageImages = const []; // 목록 번호 → 로컬 그림 경로

  /// 그림 페이지 썸네일(PNG 바이트). 없거나 null 을 돌려주면 원본 파일을 그대로 보낸다.
  /// 한 번에 하나씩만 부른다(메인 isolate 에서 줄여도 UI 가 덜 끊기게). 결과는 서버를 끌 때까지 기억한다.
  Future<List<int>?> Function(String path)? thumbnailer;

  /// 썸네일 하나를 기다리는 한도. 넘으면 그 요청은 원본을 보내고 다음 요청으로 넘어간다.
  // ponytail: 넘긴 줄이기는 취소하지 못하고 뒤에서 끝까지 돈다(다음 줄이기와 잠깐 겹칠 수 있다).
  @visibleForTesting
  Duration thumbnailTimeout = const Duration(seconds: 10);
  final _thumbs = <String, List<int>>{}; // 로컬 경로 → 썸네일
  Future<void> _thumbQueue = Future.value();

  // 경과 시간(clock.elapsed_ms)은 흐르는 동안 매번 달라서 저장한 JSON 에서 빼 두고, 보낼 때
  // 그 순간 값으로 맨 앞에 붙인다(`{"clock_ms":N,...`). 늦게 연 휴대폰도 맞는 시간을 받는다.
  int _clockMs = 0;
  bool _clockRunning = false;
  bool _hasClock = false;
  final _clockWatch = Stopwatch();

  /// 리모컨 요청. 다 처리한 뒤([update] 까지 끝난 뒤) 돌아와야 응답에 바뀐 상태가 실린다.
  Future<void> Function(String action, Map<String, String> params)? onControl;
  Future<void> _control = Future.value();
  final _images = <String, String>{}; // 'current' | 'next' → 로컬 경로
  // start/stop 을 차례로만 돌린다. 발표 종료(stop) 직후 다시 켜거나(start) 버튼을 두 번 눌러도
  // 서로 겹치지 않는다.
  Future<void> _queue = Future.value();

  /// 다이얼로그가 듣는다 — 발표가 끝나 꺼지면 QR 대신 "꺼짐" 을 보여 준다.
  final running = ValueNotifier(false);

  /// 바깥 망 터널 상태. [TunnelState.ready] 일 때 [publicUrl] 이 있다.
  final tunnel = ValueNotifier(TunnelState.off);
  Process? _tunnelProcess;
  String? _publicBase; // https://xxxx.trycloudflare.com

  /// 발표자 화면 경로. 싱어창은 `/`.
  static const presenterPath = '/presenter';

  /// 발표자 쪽 PIN(숫자 4자리). 비어 있으면 발표자 쪽은 아무도 못 들어온다.
  /// 바꾸면 이미 들어와 있던 휴대폰도 다음 요청부터 다시 묻는다.
  String get presenterPin => _presenterPin;
  set presenterPin(String pin) {
    if (pin == _presenterPin) return;
    _presenterPin = pin;
    // 열려 있는 발표자 SSE 는 새 요청을 안 보내서 PIN 검사를 다시 안 거친다 — 끊어서 다시 붙게(→ 401 → PIN 입력).
    for (final c in _remoteClients.toList()) {
      c.close().catchError((_) {});
    }
    _remoteClients.clear();
  }

  String _presenterPin = '';

  static const _pinCookie = 'ws_pin';
  static const maxPinFailures = 5;
  static const pinLockout = Duration(seconds: 30);
  final _pinFailures = <String, (int, DateTime)>{}; // 접속 주소 → (틀린 횟수, 마지막 시각)

  /// 다른 망에서 열 주소. 터널이 아직이면 null.
  String? publicUrl({bool remote = false}) => _publicBase == null
      ? null
      : '$_publicBase${remote ? presenterPath : '/'}';

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  /// 휴대폰에서 열 주소. 키가 없어 늘 같다(포트를 다른 프로그램이 쓰고 있을 때만 바뀐다).
  String urlFor(String address, {bool remote = false}) =>
      'http://$address:$port${remote ? presenterPath : '/'}';

  // 앞 작업이 실패해도(포트 못 잡음 등) 줄이 막히지 않게 오류는 그 호출에만 돌려준다.
  // 막히면 그 뒤 stop 이 영영 안 돌아 터널이 앱 밖에 남는다.
  Future<void> start() => _enqueue(_start);
  Future<void> stop() => _enqueue(_stop);

  Future<void> _enqueue(Future<void> Function() job) {
    final f = _queue.catchError((_) {}).then((_) => job());
    _queue = f;
    return f;
  }

  Future<void> _start() async {
    if (_server != null) return;
    try {
      // 다른 프로그램이 127.0.0.1 로만 잡고 있어도 0.0.0.0 bind 는 성공한다(macOS). 그러면
      // 터널(127.0.0.1 로 붙는다)이 그 프로그램으로 가므로 127.0.0.1 도 비었는지 먼저 본다.
      await (await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        preferredPort,
      )).close();
      _server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      // 다른 프로그램이 쓰고 있으면 아무 빈 포트나.
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server!.listen(_handle, onError: (_) {});
    unawaited(_runTunnel(_server!));
    // 휴대폰이 잠깐 잠들었다 깨도 끊긴 걸 알아채게 주기적으로 빈 줄을 보낸다.
    _ping = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _broadcast(': ping\n\n', ': ping\n\n'),
    );
    running.value = true;
  }

  Future<void> _stop() async {
    _ping?.cancel();
    _ping = null;
    final server = _server;
    _server = null;
    // force 로 소켓부터 끊는다. 잠든 휴대폰 연결의 close() 를 기다리면 TCP 시간 초과까지 멈춘다.
    await server?.close(force: true);
    _tunnelProcess?.kill();
    if (_tunnelProcess != null) {
      try {
        _tunnelPidFile.deleteSync();
      } catch (_) {}
    }
    _tunnelProcess = null;
    _publicBase = null;
    tunnel.value = TunnelState.off;
    for (final c in [..._clients, ..._remoteClients]) {
      c.close().catchError((_) {});
    }
    _clients.clear();
    _remoteClients.clear();
    _lastJson = null;
    _lastRemoteJson = null;
    _clockMs = 0;
    _clockRunning = false;
    _hasClock = false;
    _images.clear();
    _pagesSource = null;
    _pagesRev = '';
    _pagesJson = '{"rev":"","pages":[]}';
    _pageImages = const [];
    _thumbs.clear();
    _thumbQueue = Future.value();
    running.value = false;
  }

  /// cloudflared 를 켜 둔 뒤에 설치했을 때 — 서버는 그대로 두고 터널만 띄운다(같은 망 주소 유지).
  void retryTunnel() {
    final server = _server;
    if (server != null && tunnel.value == TunnelState.missing) {
      // 바로 상태를 바꿔 둔다 — 연달아 불려도 터널 루프가 둘 생기지 않게.
      tunnel.value = TunnelState.connecting;
      unawaited(_runTunnel(server));
    }
  }

  // cloudflared 임시 터널. 서버가 켜져 있는 동안 계속 살려 둔다.
  //
  // 인터넷이 잠깐 끊기는 건 cloudflared 가 스스로 다시 붙는다 — 프로세스가 살아 있으면 주소가
  // 그대로라 휴대폰은 아무것도 안 해도 이어진다(페이지가 계속 다시 묻는다). `--retries 2` 는
  // 다시 붙는 간격을 20~40초로 줄인다(기본 5 면 끊김이 길어질 때 5분까지 벌어진다. 포기하지는 않는다).
  // 프로세스 자체가 죽었을 때만 새로 띄우는데, 그러면 주소가 바뀌어 QR 을 다시 찍어야 한다.
  Future<void> _runTunnel(HttpServer server) async {
    final exe = await findCloudflared();
    if (_server != server) return;
    if (exe == null) {
      tunnel.value = TunnelState.missing;
      return;
    }
    var wait = const Duration(seconds: 5);
    while (_server == server) {
      tunnel.value = TunnelState.connecting;
      final reached = await _tunnelOnce(exe, server);
      if (_server != server) return;
      _publicBase = null;
      tunnel.value = TunnelState.failed;
      // 한 번 붙었다 죽었으면 바로, 처음부터 안 붙으면 점점 길게(최대 1분).
      wait = reached
          ? const Duration(seconds: 2)
          : Duration(seconds: min(wait.inSeconds * 2, 60));
      await Future.delayed(wait);
    }
  }

  /// cloudflared 한 번 띄우기. 주소를 받았으면(=한 번은 붙었으면) true. 프로세스가 끝나야 돌아온다.
  Future<bool> _tunnelOnce(String exe, HttpServer server) async {
    final Process proc;
    try {
      proc = await Process.start(exe, [
        'tunnel',
        '--no-autoupdate',
        '--retries',
        '2',
        '--url',
        'http://127.0.0.1:${server.port}',
      ]);
    } catch (_) {
      return false;
    }
    // 그 사이 꺼졌으면 바로 정리.
    if (_server != server) {
      proc.kill();
      return false;
    }
    _tunnelProcess = proc;
    _rememberTunnelPid(proc.pid);
    final found = Completer<String?>();
    void scan(String line) {
      final url = tunnelUrlIn(line);
      if (url != null && !found.isCompleted) found.complete(url);
    }

    for (final stream in [proc.stdout, proc.stderr]) {
      stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(scan, onError: (_) {});
    }
    final exited = proc.exitCode.whenComplete(() {
      if (!found.isCompleted) found.complete(null);
      if (_tunnelProcess == proc) _tunnelProcess = null;
    });
    final url = await found.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => null,
    );
    if (url == null) {
      proc.kill();
      await exited;
      return false;
    }
    if (_tunnelProcess == proc) {
      _publicBase = url;
      tunnel.value = TunnelState.ready;
    }
    await exited;
    return true;
  }

  // 앱이 강제 종료되거나 Windows 에서 종료 신호 없이 끝나면 cloudflared 가 앱 밖에 남는다.
  // 띄울 때 번호를 적어 두고 다음 시작 때 그 번호가 아직 cloudflared 면 끈다.
  static File get _tunnelPidFile => File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}worship_slides_cloudflared.pid',
  );

  static void _rememberTunnelPid(int pid) {
    try {
      _tunnelPidFile.writeAsStringSync('$pid');
    } catch (_) {}
  }

  /// 지난번에 남은 cloudflared 를 끈다. 번호가 다른 프로그램에 다시 쓰였을 수 있으니
  /// 이름이 cloudflared 일 때만.
  static Future<void> killLeftoverTunnel() async {
    try {
      final file = _tunnelPidFile;
      if (!await file.exists()) return;
      final pid = int.tryParse((await file.readAsString()).trim());
      await file.delete();
      if (pid == null) return;
      final r = Platform.isWindows
          ? await Process.run('tasklist', [
              '/FI',
              'PID eq $pid',
              '/FO',
              'CSV',
              '/NH',
            ])
          : await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
      if ((r.stdout as String).toLowerCase().contains('cloudflared')) {
        Process.killPid(pid);
      }
    } catch (_) {}
  }

  /// cloudflared 로그 한 줄에서 임시 터널 주소. 터널 이름은 낱말을 `-` 로 이은 꼴이라
  /// 실패 로그의 `https://api.trycloudflare.com` 은 걸리지 않는다.
  @visibleForTesting
  static String? tunnelUrlIn(String line) => RegExp(
    r'https://[a-z0-9]+(?:-[a-z0-9]+)+\.trycloudflare\.com',
  ).firstMatch(line)?.group(0);

  static String? _cloudflaredPath; // 찾은 경로는 기억한다(켤 때마다 which/where 를 안 돌게)

  /// cloudflared 실행 파일. 앱 폴더 → 흔한 설치 위치 → PATH 순.
  /// 앱을 켠 뒤에 설치해도 찾게 PATH 보다 설치 위치를 먼저 직접 본다
  /// (Finder 로 띄운 macOS 앱은 PATH 에 Homebrew 가 없고, Windows 는 켤 때의 PATH 를 쓴다).
  static Future<String?> findCloudflared() async {
    final cached = _cloudflaredPath;
    if (cached != null && await File(cached).exists()) return cached;
    final name = Platform.isWindows ? 'cloudflared.exe' : 'cloudflared';
    final exe = File(Platform.resolvedExecutable);
    final sep = Platform.pathSeparator;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final candidates = [
      // 배포 폴더(DB 가 있는 곳). macOS 는 .app/Contents/MacOS/exe 라 네 단계 위.
      '${(Platform.isMacOS ? exe.parent.parent.parent.parent : exe.parent).path}$sep$name',
      if (Platform.isMacOS) ...[
        '/opt/homebrew/bin/cloudflared',
        '/usr/local/bin/cloudflared',
      ],
      if (Platform.isWindows) ...[
        r'C:\Program Files (x86)\cloudflared\cloudflared.exe',
        r'C:\Program Files\cloudflared\cloudflared.exe',
        if (localAppData != null)
          '$localAppData\\Microsoft\\WinGet\\Links\\cloudflared.exe',
      ],
    ];
    for (final c in candidates) {
      if (await File(c).exists()) return _cloudflaredPath = c;
    }
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', [
        'cloudflared',
      ]);
      final first = (r.stdout as String).trim().split(RegExp(r'\r?\n')).first;
      if (r.exitCode == 0 && first.isNotEmpty) {
        return _cloudflaredPath = first.trim();
      }
    } catch (_) {}
    return null;
  }

  /// [SingerViewData.toJson] 에 리모컨용 값([remoteOnlyKeys])을 얹어 받는다. 내용이 같으면 보내지 않는다.
  void update(Map<String, dynamic> data) {
    if (_server == null) return;
    final public = <String, dynamic>{...data}..remove('pages');
    _setPages(data['pages']);
    if (_pagesRev.isNotEmpty) public['pages_rev'] = _pagesRev;
    for (final key in const ['current', 'next']) {
      final page = data[key];
      if (page is! Map) continue;
      final path = page['image_path'] as String? ?? '';
      final copy = {...page};
      if (path.isEmpty) {
        _images.remove(key);
      } else {
        _images[key] = path;
        // 경로 대신 주소. v 는 이미지가 바뀌면 브라우저 캐시를 피하려는 값.
        copy['image_path'] = '/img/$key?v=${_version(path)}';
      }
      public[key] = copy;
    }
    final clock = public['clock'];
    _hasClock = clock is Map;
    if (clock is Map) {
      _clockMs = (clock['elapsed_ms'] as num?)?.toInt() ?? 0;
      _clockRunning = clock['running'] == true;
      _clockWatch
        ..reset()
        ..start();
      public['clock'] = {...clock}..remove('elapsed_ms');
    }
    final remoteJson = jsonEncode(public);
    for (final k in remoteOnlyKeys) {
      public.remove(k);
    }
    final json = jsonEncode(public);
    if (remoteJson == _lastRemoteJson) return;
    _lastRemoteJson = remoteJson;
    // 메모·확대·메시지만 바뀌었으면 싱어 쪽엔 보내지 않는다.
    final singerChanged = json != _lastJson;
    _lastJson = json;
    _broadcast(
      singerChanged ? 'data: ${_live(json)}\n\n' : null,
      'data: ${_live(remoteJson)}\n\n',
    );
  }

  void _setPages(Object? pages) {
    final source = pages is List ? jsonEncode(pages) : null;
    if (source == _pagesSource) return;
    _pagesSource = source;
    final images = <String?>[];
    final list = <Map<String, Object?>>[];
    for (final p in pages is List ? pages : const []) {
      final page = p is Map ? p : const {};
      final path =
          page['image'] is String && (page['image'] as String).isNotEmpty
          ? page['image'] as String
          : null;
      images.add(path);
      list.add({
        ...page.cast<String, Object?>(),
        'image': path == null
            ? null
            : '/img/page/${images.length - 1}?v=${_pathVersion(path)}&p=1',
      });
    }
    _pageImages = images;
    _pagesRev = source == null ? '' : fnvHex(utf8.encode(source));
    _pagesJson = jsonEncode({'rev': _pagesRev, 'pages': list});
    // 목록에서 빠진 그림의 썸네일은 버린다(콘티를 고칠수록 쌓이지 않게).
    final kept = images.toSet();
    _thumbs.removeWhere((path, _) => !kept.contains(path));
  }

  // 썸네일 판 값. 넘길 때마다 목록 전체를 stat 하지 않으려고 경로만 본다
  // (다시 구운 PPT 는 새 폴더에 구워져 경로가 바뀐다).
  static String _pathVersion(String path) => fnvHex(utf8.encode(path));

  Future<List<int>?> _thumbnail(String path) {
    final job = _thumbQueue.catchError((_) {}).then((_) async {
      final cached = _thumbs[path];
      if (cached != null) return cached;
      // 멈춘 줄이기가 큐를 막지 않게 — 넘으면 던지고, 요청은 원본을 보낸다.
      final made = await thumbnailer?.call(path).timeout(thumbnailTimeout);
      if (made != null && _server != null) _thumbs[path] = made;
      return made;
    });
    _thumbQueue = job;
    return job;
  }

  /// 저장한 JSON 앞에 지금 경과 시간을 붙인다. 페이지는 이 값을 떼어 내고 나머지로 바뀐 걸 가린다.
  String _live(String json) {
    if (!_hasClock || !json.startsWith('{') || json == '{}') return json;
    final ms = _clockMs + (_clockRunning ? _clockWatch.elapsedMilliseconds : 0);
    return '{"clock_ms":$ms,${json.substring(1)}';
  }

  void _broadcast(String? singerText, String remoteText) {
    for (final (clients, text) in [
      (_clients, singerText),
      (_remoteClients, remoteText),
    ]) {
      if (text == null) continue;
      for (final c in clients.toList()) {
        try {
          c.write(text);
        } catch (_) {
          clients.remove(c);
        }
      }
    }
  }

  // 이미지 버전 값. 경로가 같아도 파일을 다시 구웠으면 달라지게 수정 시각까지 넣는다.
  static String _version(String path) {
    try {
      return '${path.hashCode}-${File(path).lastModifiedSync().millisecondsSinceEpoch}';
    } catch (_) {
      return '${path.hashCode}';
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    // 싱어 쪽은 주소만으로 열린다. 발표자 페이지가 보내는 요청만 `p=1` 을 달고, PIN 쿠키가 맞아야 한다.
    final remote = req.uri.queryParameters['p'] == '1';
    try {
      if (req.method == 'POST' && !_sameOrigin(req)) {
        res.statusCode = HttpStatus.forbidden;
        await res.close();
        return;
      }
      if (remote && !_pinOk(req)) {
        res.statusCode = HttpStatus.unauthorized;
        res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        await res.close();
        return;
      }
      switch (req.uri.path) {
        case '/':
          res.headers
            ..contentType = ContentType.html
            ..set(HttpHeaders.cacheControlHeader, 'no-store');
          res.write(singerPageHtml);
          await res.close();
        case presenterPath || '$presenterPath/':
          res.headers
            ..contentType = ContentType.html
            ..set(HttpHeaders.cacheControlHeader, 'no-store');
          res.write(
            _pinOk(req)
                ? singerPageHtml.replaceFirst('<body>', '<body class="remote">')
                : pinPageHtml(),
          );
          await res.close();
        case '/login':
          await _login(req);
        case '/events':
          res.bufferOutput = false;
          res.headers
            ..contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            )
            ..set(HttpHeaders.cacheControlHeader, 'no-cache');
          (remote ? _remoteClients : _clients).add(res);
          unawaited(
            res.done.catchError((_) {}).whenComplete(() {
              _clients.remove(res);
              _remoteClients.remove(res);
            }),
          );
          final last = remote ? _lastRemoteJson : _lastJson;
          res.write(last == null ? ': hello\n\n' : 'data: ${_live(last)}\n\n');
        // 지금 페이지 JSON 한 번. Cloudflare 임시 터널은 SSE 를 붙잡아 두고 안 흘려보내서
        // (trycloudflare 의 알려진 제한) 터널(https) 주소에서는 페이지가 이걸 0.5초마다 묻는다.
        case '/state':
          res.headers
            ..contentType = ContentType.json
            ..set(HttpHeaders.cacheControlHeader, 'no-store');
          res.write(_live((remote ? _lastRemoteJson : _lastJson) ?? '{}'));
          await res.close();
        case '/control':
          if (!remote || req.method != 'POST') {
            res.statusCode = HttpStatus.forbidden;
            await res.close();
            return;
          }
          final params = req.uri.queryParameters;
          // 앞 요청이 끝난 뒤에 처리한다(확대 요청이 뒤바뀌어 도착해도 순서대로).
          // 실패해도 응답은 닫는다 — 안 닫으면 휴대폰 브라우저의 연결 수가 차서 폴링·이미지까지 막힌다.
          // 앱이 멈춰(네이티브 응답 없음) 끝나지 않아도 다음 요청이 영영 막히지 않게 5초에서 끊는다.
          final job = _control
              .catchError((_) {})
              .then((_) => onControl?.call(params['action'] ?? '', params))
              .timeout(const Duration(seconds: 5));
          _control = job;
          try {
            await job;
          } catch (_) {}
          res.headers
            ..contentType = ContentType.json
            ..set(HttpHeaders.cacheControlHeader, 'no-store');
          res.write(_live(_lastRemoteJson ?? '{}'));
          await res.close();
        case '/pages':
          if (!remote) {
            res.statusCode = HttpStatus.forbidden;
            await res.close();
            return;
          }
          res.headers
            ..contentType = ContentType.json
            ..set(HttpHeaders.cacheControlHeader, 'no-store');
          res.write(_pagesJson);
          await res.close();
        case final p when p.startsWith('/img/page/'):
          if (!remote) {
            res.statusCode = HttpStatus.forbidden;
            await res.close();
            return;
          }
          final n = int.tryParse(p.substring('/img/page/'.length));
          final path = n != null && n >= 0 && n < _pageImages.length
              ? _pageImages[n]
              : null;
          if (path == null ||
              req.uri.queryParameters['v'] != _pathVersion(path) ||
              !File(path).existsSync()) {
            res.statusCode = HttpStatus.notFound;
            await res.close();
            return;
          }
          List<int>? thumb;
          try {
            thumb = await _thumbnail(path);
          } catch (_) {}
          res.headers
            ..set(HttpHeaders.cacheControlHeader, 'private, max-age=3600')
            ..contentType = thumb != null
                ? ContentType('image', 'png')
                : _imageType(path);
          if (thumb != null) {
            res.add(thumb);
          } else {
            await res.addStream(File(path).openRead());
          }
          await res.close();
        case '/img/current' || '/img/next':
          final path = _images[req.uri.path.substring(5)];
          final file = path == null ? null : File(path);
          // 그 사이 페이지가 넘어갔으면(버전이 다르면) 다른 페이지 이미지를 주지 않는다.
          // 브라우저가 그 주소에 엉뚱한 이미지를 기억해 두면 나중에 그 페이지에서 잘못 보인다.
          if (file == null ||
              req.uri.queryParameters['v'] != _version(path!) ||
              !file.existsSync()) {
            res.statusCode = HttpStatus.notFound;
            await res.close();
            return;
          }
          res.headers
            ..set(HttpHeaders.cacheControlHeader, 'no-store')
            ..contentType = _imageType(path);
          await res.addStream(file.openRead());
          await res.close();
        default:
          res.statusCode = HttpStatus.notFound;
          await res.close();
      }
    } catch (_) {
      _clients.remove(res);
      _remoteClients.remove(res);
    }
  }

  // 쿠키가 지금 PIN 과 맞는가. PIN 이 없으면(아직 안 정함) 아무도 못 들어온다.
  bool _pinOk(HttpRequest req) {
    if (presenterPin.isEmpty) return false;
    try {
      for (final c in req.cookies) {
        if (c.name == _pinCookie && c.value == presenterPin) return true;
      }
    } catch (_) {} // 같은 주소의 다른 프로그램이 남긴 깨진 쿠키
    return false;
  }

  // POST 의 Origin 이 이 서버 주소(Host)와 같은가. Origin 이 없으면(앱 밖 도구·옛 브라우저) 받는다.
  // 터널 주소(https://*.trycloudflare.com)도 받는다 — cloudflared 가 Host 를 원래대로 넘기는지 확인 못 해서.
  bool _sameOrigin(HttpRequest req) {
    final origin = req.headers.value('origin');
    if (origin == null || origin.isEmpty) return true;
    if (_publicBase != null && origin == _publicBase) return true;
    final host = req.headers.value(HttpHeaders.hostHeader);
    final o = Uri.tryParse(origin);
    return o != null && host != null && o.hasAuthority && o.authority == host;
  }

  // PIN 입력 폼(`pin=1234`, application/x-www-form-urlencoded). 맞으면 쿠키를 남기고 발표자 화면으로 보낸다.
  Future<void> _login(HttpRequest req) async {
    final res = req.response;
    if (req.method != 'POST') {
      res.statusCode = HttpStatus.methodNotAllowed;
      await res.close();
      return;
    }
    final who = req.connectionInfo?.remoteAddress.address ?? '';
    final now = DateTime.now();
    final (fails, at) = _pinFailures[who] ?? (0, now);
    final locked = fails >= maxPinFailures && now.difference(at) < pinLockout;
    // 폼은 `pin=1234` 하나라 짧다. 길거나 깨진 본문(잘못된 % 인코딩·UTF-8)은 틀린 PIN 으로 본다.
    var pin = '';
    try {
      final bytes = <int>[];
      await for (final chunk in req) {
        bytes.addAll(chunk);
        if (bytes.length > 256) throw const FormatException('too long');
      }
      pin = Uri.splitQueryString(utf8.decode(bytes))['pin']?.trim() ?? '';
    } catch (_) {}
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (!locked && presenterPin.isNotEmpty && pin == presenterPin) {
      _pinFailures.remove(who);
      res.cookies.add(
        Cookie(_pinCookie, pin)
          ..path = '/'
          ..httpOnly = true
          // Strict 면 QR 카메라·메신저에서 연 첫 화면에 쿠키가 안 실린다. 다른 사이트의 POST·fetch 는
          // Lax 로도 안 실리고, POST 는 Origin 검사로 한 번 더 막는다.
          ..sameSite = SameSite.lax
          ..maxAge = const Duration(days: 365).inSeconds,
      );
      res.statusCode = HttpStatus.seeOther;
      res.headers.set(HttpHeaders.locationHeader, presenterPath);
      await res.close();
      return;
    }
    if (!locked) {
      // 잠금이 풀린 뒤 처음 틀리면 1부터 다시 센다.
      final base = fails >= maxPinFailures ? 0 : fails;
      _pinFailures[who] = (base + 1, now);
    }
    res.statusCode = HttpStatus.unauthorized;
    res.headers.contentType = ContentType.html;
    res.write(
      pinPageHtml(
        error: locked || (_pinFailures[who]?.$1 ?? 0) >= maxPinFailures
            ? '여러 번 틀렸습니다. 30초 뒤에 다시 넣어 주세요.'
            : 'PIN 이 맞지 않습니다.',
      ),
    );
    await res.close();
  }

  static ContentType _imageType(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') || lower.endsWith('.jpeg')
        ? ContentType('image', 'jpeg')
        : ContentType('image', 'png');
  }

  /// 휴대폰에서 열 주소 후보. 사설망 IPv4 만, 와이파이·유선을 앞에 둔다.
  /// VPN(utun·100.x)·가상 머신(Parallels·VMware·Docker·Hyper-V) 주소는 휴대폰이 못 닿으므로 뺀다.
  static Future<List<String>> lanAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      final picked = <(int, String)>[];
      for (final i in interfaces) {
        if (isVirtualInterface(i.name)) continue;
        for (final a in i.addresses) {
          if (isPrivateIPv4(a.address)) {
            picked.add((isPhysicalInterface(i.name) ? 0 : 1, a.address));
          }
        }
      }
      picked.sort((a, b) => a.$1.compareTo(b.$1));
      return [for (final p in picked) p.$2];
    } catch (_) {
      return const [];
    }
  }

  @visibleForTesting
  static bool isPrivateIPv4(String ip) {
    final p = ip.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.contains(null)) return false;
    return p[0] == 10 ||
        (p[0] == 192 && p[1] == 168) ||
        (p[0] == 172 && p[1]! >= 16 && p[1]! <= 31);
  }

  @visibleForTesting
  static bool isVirtualInterface(String name) {
    final n = name.toLowerCase();
    return const [
      'utun',
      'bridge',
      'vmnet',
      'vnic',
      'docker',
      'veth',
      'vboxnet',
      'vethernet',
      'tailscale',
      'zerotier',
    ].any(n.startsWith);
  }

  // macOS en0·en1, 리눅스 eth/wlan, Windows "Wi-Fi"·"이더넷"·"Ethernet".
  static bool isPhysicalInterface(String name) {
    final n = name.toLowerCase();
    return n.startsWith('en') ||
        n.startsWith('eth') ||
        n.startsWith('wlan') ||
        n.contains('wi-fi') ||
        n.contains('이더넷');
  }
}

/// 발표자 PIN 입력 페이지. 맞으면 서버가 쿠키를 남기고 `/presenter` 로 보낸다(JS 없이 폼 하나).
String pinPageHtml({String error = ''}) {
  const esc = HtmlEscape();
  return '''<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>발표자 모드 · PIN</title>
<style>
  html,body{margin:0;height:100%;background:#111418;color:#e6e9ee;
    font-family:-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Malgun Gothic",sans-serif;}
  body{display:flex;align-items:center;justify-content:center;padding:24px;box-sizing:border-box;word-break:keep-all;}
  form{width:100%;max-width:320px;display:flex;flex-direction:column;gap:14px;text-align:center;}
  h1{font-size:20px;margin:0;}
  p{margin:0;color:#9aa3ad;font-size:14px;line-height:1.5;}
  input{font-size:32px;letter-spacing:.5em;text-align:center;padding:12px 0 12px .5em;border-radius:12px;
    border:1px solid #3a424d;background:#1b2027;color:#fff;outline:none;}
  input:focus{border-color:#7aa7ff;}
  button{font-size:17px;font-weight:700;padding:14px;border:0;border-radius:12px;background:#3b6fe0;color:#fff;}
  .err{color:#ff8a80;font-weight:600;min-height:1.4em;}
</style></head>
<body><form method="post" action="/login">
  <h1>발표자 모드</h1>
  <p>PC 의 휴대폰 화면 창(발표자 모드)에 나온<br>PIN 4자리를 넣어 주세요.</p>
  <input name="pin" aria-label="PIN 4자리" type="tel" inputmode="numeric" pattern="[0-9]*" maxlength="4" autocomplete="off" autofocus required>
  <div class="err">${esc.convert(error)}</div>
  <button type="submit">들어가기</button>
  <p>한 번 들어오면 이 휴대폰은 다음부터 묻지 않습니다.</p>
</form></body></html>''';
}

/// 싱어 페이지. 네이티브 싱어 창(MainFlutterWindow.swift)과 같은 모양·같은 글자 맞춤 규칙
/// (원본 줄 그대로, 너무 작아지면 그때만 줄바꿈). 글자는 textContent 로만 넣는다(HTML 주입 없음).
///
/// `<body class="remote">`(`/presenter` 로 연 경우)면 머리줄 [발표자 모드 | 싱어창] 으로 두 화면을 오간다(`presenter_view`).
/// 발표자 모드 = 이전·다음 버튼 + 현재·다음 + '모든 페이지' 한 줄(`/pages`, 눌러 `goto`). 싱어창 = 현재 페이지가
/// 관객 화면과 같은 16:9 틀(그래야 핀치로 고른 영역이 관객 화면 좌표와 맞는다), 메모·블랙아웃 버튼, 제스처.
/// 메시지 띠는 두 모드 공통 알림(`message_id` 가 바뀌면 뜨고 60초 뒤 사라짐).
/// 확대 영역은 발표 보기 '영역 확대'와 같은 값(x·y = 왼쪽 위, size = 폭 비율, 0~1)이다.
const singerPageHtml =
    r'''<!DOCTYPE html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>싱어창</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box;}
  html,body{width:100%;height:100%;overflow:hidden;background:#0d0f12;color:#fff;
    font-family:-apple-system,'Apple SD Gothic Neo','Malgun Gothic','Noto Sans KR',sans-serif;}
  body{display:flex;flex-direction:column;height:100vh;height:100dvh;
    padding:max(2vh,env(safe-area-inset-top)) max(3vw,env(safe-area-inset-right))
      max(2vh,env(safe-area-inset-bottom)) max(3vw,env(safe-area-inset-left));gap:1.4vh;}
  header{display:flex;align-items:center;gap:2vw;font-size:2.4vh;color:#9aa4b1;flex:none;}
  #title{flex:0 1 auto;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-weight:600;}
  header .grow{flex:1;}
  /* 조 배지는 중립색, 제목 바로 오른쪽(시계 경고색과 헷갈리지 않게). */
  #key{flex:none;font-size:2vh;font-weight:700;color:#8b95a2;border:1px solid #8b95a2;border-radius:999px;
    padding:.1em .7em;white-space:nowrap;}
  #key:empty{display:none;}
  #page{font-variant-numeric:tabular-nums;font-weight:700;color:#e6e9ee;}
  #page,#badge,#clock{flex:none;white-space:nowrap;}
  #clock{font-variant-numeric:tabular-nums;font-weight:700;color:#c3cad4;white-space:nowrap;}
  #clock .warn{color:#ffb547;} #clock .over{color:#ff6b6b;}
  .badge{background:#e5484d;color:#fff;border-radius:999px;padding:.2em .8em;font-size:2vh;font-weight:700;}
  .off{background:#59626e;}
  #label{font-size:2.1vh;color:#8b95a2;font-weight:600;flex:none;white-space:nowrap;overflow:hidden;
    text-overflow:ellipsis;}
  .box{position:relative;border-radius:1.4vh;overflow:hidden;min-height:0;}
  .stage{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
    padding:1.6vh 3vw;transform-origin:0 0;}
  /* 현재·다음 비율은 사이 막대(#split)를 끌어 바꾼다 — flex-grow 를 JS 가 넣는다. */
  #panes{flex:1;min-height:0;min-width:0;display:flex;flex-direction:column;}
  #current{flex:65 1 0;min-width:0;background:#1b2028;border:2px solid #5a6472;}
  #side{flex:35 1 0;min-height:0;min-width:0;display:flex;flex-direction:column;gap:1vh;}
  #next{flex:1;background:#0f1215;border:1px solid #232930;}
  #split{flex:none;height:3.2vh;display:flex;align-items:center;justify-content:center;
    touch-action:none;cursor:row-resize;}
  #split::before{content:'';width:12vw;height:.6vh;min-height:4px;border-radius:999px;background:#4a5360;}
  #split.drag::before{background:#ffd54f;}
  /* 좌우 배치(휴대폰마다 따로 기억) */
  body.row #panes{flex-direction:row;}
  body.row #split{height:auto;width:3.2vh;cursor:col-resize;}
  body.row #split::before{width:.6vh;min-width:4px;height:12vh;}
  #layout,#chords{flex:none;background:#1b2028;color:#e6e9ee;border:1px solid #3a424d;border-radius:.8vh;
    font:inherit;font-size:2vh;font-weight:700;padding:.3em .7em;}
  #chords.on{color:#FFA94D;border-color:#FFA94D;}
  #chords.dim{opacity:.45;}
  /* 송폼 칩: 칸 좌상단, 글자 맞춤·확대·눌림에 안 끼어든다. 다음 칸은 0.75배·테두리만. */
  .form{position:absolute;left:1vh;top:1vh;z-index:2;display:flex;gap:4px;pointer-events:none;
    transform-origin:0 0;}
  .form span{font-size:clamp(14px,3.2vw,22px);font-weight:700;line-height:1;padding:.15em .5em;border-radius:6px;
    color:#EDEDF0;background:rgba(147,165,204,.2);border:1px solid #4A5268;white-space:nowrap;}
  #next .form{transform:scale(.75);}
  #next .form span{background:transparent;color:#9A9AA6;}
  .fit{width:100%;max-height:100%;text-align:center;line-height:1.3;font-weight:700;}
  .main,.sub{white-space:pre;}
  .wrap .main,.wrap .sub{white-space:pre-wrap;word-break:keep-all;}
  .sub{color:#ffd54f;font-size:.78em;margin-top:.45em;}
  /* 코드 악보: 코드는 조각(.seg) 위 칸. 조각 폭 = max(가사, 코드 + 0.4em 틈). 줄바꿈은 낱말(.w) 사이 공백에서만. */
  .w{white-space:nowrap;}
  .seg{display:inline-block;text-align:left;}
  .seg .ch{display:block;font-size:.55em;line-height:1.15;color:#FFA94D;padding-right:.4em;white-space:pre;}
  .seg .ly{display:block;white-space:pre;}
  .cl.only{font-size:.55em;line-height:1.15;color:#FFA94D;}
  #next .seg .ch,#next .cl.only{color:#B07A40;}
  #hint{position:fixed;left:50%;bottom:12vh;transform:translateX(-50%);max-width:90vw;display:none;
    background:#1a1f26;color:#e6e9ee;border:1px solid #3a424d;border-radius:1vh;padding:1vh 3vw;font-size:2.2vh;
    font-weight:600;text-align:center;}
  #hint.show{display:block;}
  #next .main{color:#c3cad4;}
  #next .sub{color:#b8a25a;}
  .placeholder{color:#59626e;font-size:3vh;font-weight:600;}
  img{max-width:100%;max-height:100%;object-fit:contain;display:block;}
  #message,#note,#bar,#flash{display:none;}
  body.remote{touch-action:none;overscroll-behavior:none;-webkit-user-select:none;user-select:none;
    -webkit-touch-callout:none;}
  .remote #current .stage{padding:0;}
  .remote #current .fit{padding:2% 4%;}
  .remote #note{display:block;flex:none;max-height:16vh;overflow:auto;touch-action:pan-y;white-space:pre-wrap;
    font-size:2.3vh;line-height:1.4;color:#e6e9ee;background:#1a1f26;border-left:3px solid #ffd54f;
    border-radius:.8vh;padding:1vh 3vw;}
  .remote #note:empty{display:none;}
  /* 메시지 = 알림: 받으면 내려오며 뜨고 60초 뒤(또는 누르면) 사라진다. 아래 막대 = 남은 시간. */
  .remote #message{position:relative;flex:none;color:#000;background:#fff;border-radius:.8vh;overflow:hidden;
    opacity:0;transform:translateY(-12px);transition:opacity .3s,transform .3s;}
  .remote #message.show{display:block;}
  .remote #message.in{opacity:1;transform:none;transition:opacity .2s,transform .2s;}
  #mtext{max-height:22vh;overflow:auto;touch-action:pan-y;white-space:pre-wrap;overflow-wrap:anywhere;
    font-size:3.4vh;font-weight:700;line-height:1.35;padding:1.2vh 3vw calc(1.2vh + 3px);}
  #mbar{position:absolute;left:0;right:0;bottom:0;height:3px;background:rgba(13,15,18,.3);transform-origin:0 50%;}
  .remote #bar{display:flex;flex:none;}
  #black,#pblack{position:relative;overflow:hidden;border:1px solid #3a424d;background:#1b2028;color:#e6e9ee;
    font:inherit;font-weight:700;}
  #black{flex:1;border-radius:1vh;font-size:2.2vh;padding:1.6vh 0;}
  #black::before,#pblack::before{content:'';position:absolute;inset:0;background:#e5484d;transform:scaleX(0);
    transform-origin:0 50%;}
  #black.hold::before,#pblack.hold::before{transform:scaleX(1);transition:transform .6s linear;}
  #black span,#pblack span{position:relative;}
  #black.on,#pblack.on{background:#e5484d;border-color:#e5484d;}
  .sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;}
  button:focus-visible{outline:2px solid #ffd54f;outline-offset:2px;}
  /* ── 발표자 모드(발표자 주소 + presenter_view) ── 이동 줄 · 제목 줄 · 무대(현재 70% · 다음, 16:9) ·
     모든 페이지 한 줄 가로 스크롤 · 화면 끄기. 가로 화면(body.land)은 위 두 줄이 한 줄이 된다. */
  #top{display:flex;flex-direction:column;gap:8px;flex:none;}
  #pnav,#mode,#plist,#pblack{display:none;}
  .remote #mode{display:flex;flex:none;border:1px solid #3a424d;border-radius:10px;overflow:hidden;}
  /* 싱어창 머리줄에 전환이 붙으면 좁은 세로 화면에서 넘치므로 줄을 넘긴다. */
  .remote header{flex-wrap:wrap;row-gap:.8vh;}
  #mode button{height:44px;padding:0 12px;background:transparent;color:#9aa4b1;border:0;font:inherit;
    font-size:14px;font-weight:700;white-space:nowrap;}
  #mode button[aria-pressed=true]{background:#e6e9ee;color:#0d0f12;}
  body.presenter{touch-action:manipulation;gap:8px;padding:max(12px,env(safe-area-inset-top))
    max(12px,env(safe-area-inset-right)) max(12px,env(safe-area-inset-bottom)) max(12px,env(safe-area-inset-left));}
  .presenter #pnav{display:flex;align-items:center;gap:8px;height:56px;flex:none;}
  .pbtn{flex:none;min-width:96px;height:52px;background:#1b2028;color:#e6e9ee;border:1px solid #3a424d;
    border-radius:12px;font:inherit;font-size:18px;font-weight:700;padding:0 12px;white-space:nowrap;}
  .pbtn:active{background:#2a313b;}
  .pbtn:disabled{opacity:.35;}
  #pmid{flex:1;min-width:88px;height:52px;background:none;border:0;color:#e6e9ee;font:inherit;display:flex;
    flex-direction:column;align-items:center;justify-content:center;}
  #pnum{font-size:22px;font-weight:700;font-variant-numeric:tabular-nums;white-space:nowrap;}
  #pclock{font-size:14px;font-weight:700;color:#c3cad4;font-variant-numeric:tabular-nums;white-space:nowrap;}
  #pclock:empty{display:none;}
  #pclock .warn{color:#ffb547;} #pclock .over{color:#ff6b6b;}
  .presenter header{height:44px;font-size:16px;}
  .presenter #key,.presenter #clock,.presenter #page,.presenter #chords,.presenter #layout,
  .presenter #split,.presenter #note,.presenter #flash{display:none;}
  .presenter #panes{flex:1 1 0;flex-direction:row;align-items:flex-start;gap:8px;}
  .presenter #current,.presenter #side{flex:none!important;}
  .presenter #side{gap:4px;}
  .presenter #label{font-size:12px;}
  .presenter #next{flex:none;}
  .presenter.bo #current{border-color:#e5484d;}
  .presenter.pending #current{opacity:.6;}
  .presenter.dead #panes,.presenter.dead #plist{opacity:.5;}
  .presenter #plist{display:block;position:relative;flex:none;}
  #phead{height:28px;line-height:28px;font-size:13px;color:#8b95a2;}
  #strip{position:relative;display:flex;gap:8px;height:100px;padding:2px 0 8px;overflow-x:auto;overflow-y:hidden;
    touch-action:pan-x;overscroll-behavior:contain;}
  #pstat{position:absolute;left:0;right:0;top:28px;bottom:0;display:flex;align-items:center;justify-content:center;
    gap:12px;font-size:14px;color:#9aa4b1;text-align:center;}
  #pstat:empty{display:none;}
  #pstat .retry{height:44px;padding:0 16px;background:#1b2028;color:#e6e9ee;border:1px solid #3a424d;
    border-radius:10px;font:inherit;font-weight:700;}
  .th{flex:none;position:relative;width:160px;height:90px;padding:0;border:1px solid #232930;border-radius:6px;
    overflow:hidden;background:#1b2028;color:#c3cad4;font:inherit;display:flex;align-items:center;justify-content:center;}
  .th.pic.ok{background:#000;}
  .th img{width:100%;height:100%;max-width:none;max-height:none;object-fit:contain;}
  .th .tx{white-space:pre;overflow:hidden;max-width:100%;max-height:100%;padding:0 6px;font-size:9px;line-height:1.25;
    font-weight:600;text-align:center;}
  .th.blank{background:#0f1215;border:1px dashed #3a424d;}
  .th.spacer{opacity:.6;}
  .th .ph{font-size:10px;color:#8b95a2;}
  .th .no{position:absolute;left:0;top:0;font-size:11px;font-weight:700;line-height:1.2;background:rgba(0,0,0,.7);
    color:#e6e9ee;padding:2px 5px;border-bottom-right-radius:6px;font-variant-numeric:tabular-nums;}
  .th .tt{position:absolute;left:0;right:0;bottom:0;height:16px;line-height:16px;padding:0 4px;background:rgba(0,0,0,.72);
    font-size:10px;font-weight:700;color:#e6e9ee;text-align:left;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .th.cur::after,.th.pend::after{content:'';position:absolute;inset:0;border-radius:6px;pointer-events:none;}
  .th.cur::after{border:3px solid #ffd54f;}
  .th.pend::after{border:2px dashed #ffd54f;}
  .th.cur .no{background:#ffd54f;color:#0d0f12;}
  /* 가로 화면: 한 줄 머리 [◀ 이전 · 제목 · n/N·시계 · 배지 · 전환 · ⏻ · 다음 ▶], 목록 머리줄 없음. */
  .presenter.land #top{flex-direction:row;align-items:center;height:52px;}
  .presenter.land #pnav,.presenter.land header{display:contents;}
  .presenter.land .pbtn{min-width:88px;height:48px;}
  .presenter.land #pmid{flex:none;}
  .presenter.land #pblack{display:block;flex:none;width:48px;height:48px;border-radius:12px;font-size:20px;}
  .presenter.land #bar,.presenter.land #phead{display:none;}
  .presenter.land #strip{height:82px;}
  .presenter.land #pstat{top:0;}
  .presenter.land .th{width:128px;height:72px;}
  .presenter.land .th .tx{font-size:10px;}
  .presenter.land #pprev{order:1;} .presenter.land #title{order:2;} .presenter.land header .grow{order:3;}
  .presenter.land #pmid{order:4;} .presenter.land #badge{order:5;} .presenter.land #mode{order:6;}
  .presenter.land #pblack{order:7;} .presenter.land #pnext{order:8;}
  @media (max-height:339px){ #pclock{display:none;} }
  .remote #flash{display:block;position:fixed;top:0;bottom:0;width:16vw;pointer-events:none;opacity:0;
    transition:opacity .35s;background:linear-gradient(to right,rgba(255,213,79,.45),transparent);}
  #flash.r{right:0;background:linear-gradient(to left,rgba(255,213,79,.45),transparent);}
  #flash.show{opacity:1;transition:none;}
</style></head><body>
  <div id="message" aria-live="assertive"><div id="mtext"></div><div id="mbar"></div></div>
  <div id="top">
    <div id="pnav">
      <button class="pbtn" id="pprev" aria-label="이전 페이지" disabled>◀ 이전</button>
      <button id="pmid"><span id="pnum">– / –</span><span id="pclock"></span></button>
      <button id="pblack" aria-label="관객 화면 끄기, 길게 누르기"><span>⏻</span></button>
      <button class="pbtn" id="pnext" aria-label="다음 페이지" disabled>다음 ▶</button>
    </div>
    <header><span id="title"></span><span id="key"></span><span class="grow"></span><span id="badge"></span>
      <span id="clock"></span><span id="page"></span>
      <button id="chords">코드</button><button id="layout"></button>
      <span id="mode" role="group" aria-label="화면 보기"><button data-v="presenter">발표자 모드</button><button
        data-v="singer">싱어창</button></span></header>
  </div>
  <div id="panes">
    <div class="box" id="current" role="img" aria-label="현재 페이지"></div>
    <div id="split"></div>
    <div id="side"><div id="label">다음</div><div class="box" id="next" role="img" aria-label="다음 페이지"></div></div>
  </div>
  <div id="plist"><div id="phead"></div><div id="strip"></div><div id="pstat"></div></div>
  <div id="note"></div>
  <div id="bar"><button id="black" aria-label="관객 화면 끄기, 길게 누르기"><span>화면 끄기 (길게 누르기)</span></button></div>
  <div id="flash"></div>
  <div id="hint"></div>
  <div id="live" class="sr" aria-live="polite"></div>
<script>
function el(tag, cls, text){ var e=document.createElement(tag); if(cls) e.className=cls;
  if(text!=null) e.textContent=text; return e; }
function $(id){ return document.getElementById(id); }
var REMOTE=document.body.classList.contains('remote');
// 키 없음. 발표자 페이지 요청만 p=1 을 달아 발표자 쪽 값(메모·목록)을 받는다.
var Q=REMOTE?'?p=1':'';
// PC 에서 PIN 을 바꾸면 발표자 쪽 요청이 401 — 다시 읽으면 서버가 PIN 입력 페이지를 준다.
var pinGone=false;
function checkPin(r){ if(r && r.status===401 && !pinGone){ pinGone=true; location.reload(); } return r; }
// 발표자 주소로 열었을 때만: 발표자 모드(true) / 싱어창(false). setView 가 정한다.
var PRESENTER=false;
// ── 코드 ── 휴대폰마다 켜고 끈다(기본 끔). 앱은 chord_lines 를 늘 싣고 이 버튼이 정한다.
// 발표자 모드에선 늘 끈다(관객 화면 모양 확인용).
var CHORDS=false; try{ CHORDS=localStorage.getItem('singer_chords')==='1'; }catch(_){}
function chordsOn(){ return CHORDS && !PRESENTER; }
function hasChords(page){ return !!(page && page.chord_lines && page.chord_lines.length); }
// 코드 줄 하나 {t, c:[[오프셋, 이름]...]}. 오프셋은 t 안 UTF-16 위치라 JS 문자열 그대로 자른다.
// 낱말(.w)은 줄바꿈하지 않고, 코드가 붙은 자리부터는 조각(.seg: 위 코드 + 아래 가사)이다.
function chordLine(l){
  var t=l.t||'', c=l.c||[], d=el('div','cl');
  if(!t){ d.className='cl only'; d.textContent=c.map(function(p){ return p[1]; }).join('  '); return d; }
  var at={};
  c.forEach(function(p){ var o=Math.max(0,Math.min(t.length,p[0])); (at[o]=at[o]||[]).push(p[1]); });
  var word=null, tgt=null;
  function newWord(){ word=el('span','w'); d.appendChild(word); }
  for(var i=0;i<=t.length;i++){
    if(at[i]){
      if(!word) newWord();
      var s=el('span','seg'); s.appendChild(el('span','ch',at[i].join(' ')));
      tgt=el('span','ly'); s.appendChild(tgt); word.appendChild(s);
    }
    if(i===t.length) break;
    var ch=t.charAt(i);
    if(ch===' ' && !at[i]){ word=null; tgt=null; d.appendChild(document.createTextNode(' ')); continue; }
    if(!word){ newWord(); tgt=null; }
    if(!tgt){ tgt=document.createTextNode(''); word.appendChild(tgt); }
    if(tgt.nodeType===3) tgt.appendData(ch); else tgt.textContent+=ch;
  }
  // 줄 끝 코드처럼 글 없는 조각도 가사 줄 높이를 갖게(기준선이 맞도록).
  Array.prototype.forEach.call(d.querySelectorAll('.ly'),function(e){ if(!e.textContent) e.textContent='\u200b'; });
  return d;
}
function fill(box, page, empty){
  box.textContent='';
  var st=el('div','stage'); box.appendChild(st);
  if(!page){ st.appendChild(el('div','placeholder',empty)); return; }
  if(page.form && page.form.length){
    var fm=el('div','form'); page.form.forEach(function(t){ fm.appendChild(el('span',null,t)); });
    box.appendChild(fm);
  }
  if(page.image_path){ var img=el('img'); img.src=page.image_path; st.appendChild(img); return; }
  // 코드만 있는 페이지는 관객 화면엔 빈 페이지지만 여기선 코드가 보인다.
  if(chordsOn() && hasChords(page)){
    var f=el('div','fit'), m=el('div','main');
    page.chord_lines.forEach(function(l){ m.appendChild(chordLine(l)); });
    f.appendChild(m);
    if(page.english_text) f.appendChild(el('div','sub',page.english_text));
    st.appendChild(f); return;
  }
  if(page.is_blank){ st.appendChild(el('div','placeholder','빈 화면')); return; }
  var f=el('div','fit'); f.appendChild(el('div','main',page.main_text||''));
  if(page.english_text) f.appendChild(el('div','sub',page.english_text));
  st.appendChild(f);
}
// 글자 크기를 상자에 맞추고 그 크기를 돌려준다(가사가 아니면 null). cap = 넘지 않을 크기.
function fitBox(id, cap){
  var box=document.querySelector('#'+id+' .stage'), e=box&&box.querySelector('.fit'); if(!e) return null;
  var cs=getComputedStyle(box);
  var h=box.clientHeight-parseFloat(cs.paddingTop)-parseFloat(cs.paddingBottom);
  function fit(){
    var hi=Math.min(cap,Math.max(12,h*0.45)), lo=Math.min(8,hi);
    for(var i=0;i<18;i++){ var mid=(lo+hi)/2; e.style.fontSize=mid+'px';
      if(e.scrollHeight<=h+1 && e.scrollWidth<=e.clientWidth+1) lo=mid; else hi=mid; }
    e.style.fontSize=lo+'px'; return lo;
  }
  e.classList.remove('wrap');
  var s=fit();
  if(s<cap-0.5 && s<window.innerHeight*0.035){ e.classList.add('wrap'); s=fit(); }
  return s;
}
// 다음 페이지 글자는 현재 페이지보다 늘 작게(짧은 가사라도 현재보다 크게 보이지 않게).
function fitAll(){
  var c=fitBox('current',Infinity);
  fitBox('next',c?c*0.75:Infinity);
}
// 위아래 / 좌우 배치. 휴대폰(브라우저)마다 따로 기억한다.
function setLayout(row){
  document.body.classList.toggle('row',row);
  document.getElementById('layout').textContent=row?'⇅ 위아래':'⇆ 좌우';
  try{ localStorage.setItem('singer_layout',row?'row':'col'); }catch(_){}
  relayout();
}
// 크기·배치가 바뀌면: 가로/세로 판정 → 발표자 모드 칸 크기 → 글자 맞춤 → 확대.
function relayout(){
  document.body.classList.toggle('land',window.innerWidth>window.innerHeight);
  layoutPresenter(); fitAll(); if(REMOTE) showZoom();
}
// 발표자 모드 무대: 현재 칸 = 폭 70%(높이가 모자라면 높이에 맞춤), 다음 칸 = 나머지 폭
// (가로 화면은 현재 칸의 55% 까지), 둘 다 16:9. 싱어창으로 돌아가면 손으로 넣은 크기를 지운다.
function layoutPresenter(){
  var cur=$('current'), side=$('side'), nx=$('next');
  if(!PRESENTER){ cur.style.width=cur.style.height=side.style.width=nx.style.height=''; return; }
  var p=$('panes'), w=p.clientWidth, h=p.clientHeight;
  var cw=Math.max(0,Math.min((w-8)*0.7,h*16/9));
  var nw=Math.max(0,w-cw-8);
  if(document.body.classList.contains('land')) nw=Math.min(nw,cw*0.55);
  cur.style.width=cw+'px'; cur.style.height=cw*9/16+'px';
  side.style.width=nw+'px'; nx.style.height=nw*9/16+'px';
}
document.getElementById('layout').addEventListener('click',function(){
  setLayout(!document.body.classList.contains('row'));
});
function showChordButton(){
  var b=document.getElementById('chords');
  b.classList.toggle('on',CHORDS);
  b.textContent='♪ 코드';
}
document.getElementById('chords').addEventListener('click',function(){
  CHORDS=!CHORDS;
  try{ localStorage.setItem('singer_chords',CHORDS?'1':'0'); }catch(_){}
  showChordButton();
  if(lastData){ lastPages=''; render(lastData); }
});
showChordButton();
var hintTimer=null;
function hint(text){
  var h=document.getElementById('hint'); h.textContent=text; h.className='show';
  clearTimeout(hintTimer); hintTimer=setTimeout(function(){ h.className=''; },3500);
}
// 현재 페이지 몫(0.3~0.85). 발표 보기의 썸네일 줄 막대처럼 끌어서 바꾸고, 휴대폰마다 기억한다.
var splitRatio=0.65;
function setSplit(r){
  splitRatio=Math.max(0.3,Math.min(0.85,r));
  document.getElementById('current').style.flexGrow=splitRatio;
  document.getElementById('side').style.flexGrow=1-splitRatio;
}
(function(){
  var bar=document.getElementById('split'), panes=document.getElementById('panes'), raf=0;
  function ratioAt(e){
    var b=panes.getBoundingClientRect(), row=document.body.classList.contains('row');
    var len=(row?b.width:b.height)-(row?bar.offsetWidth:bar.offsetHeight);
    return ((row?e.clientX-b.left:e.clientY-b.top)-(row?bar.offsetWidth:bar.offsetHeight)/2)/(len||1);
  }
  bar.addEventListener('pointerdown',function(e){
    e.preventDefault(); bar.setPointerCapture(e.pointerId); bar.classList.add('drag');
  });
  bar.addEventListener('pointermove',function(e){
    if(!bar.classList.contains('drag')) return;
    setSplit(ratioAt(e));
    if(!raf) raf=requestAnimationFrame(function(){ raf=0; fitAll(); if(REMOTE) showZoom(); });
  });
  function done(){
    if(!bar.classList.contains('drag')) return;
    bar.classList.remove('drag');
    try{ localStorage.setItem('singer_split',String(splitRatio)); }catch(_){}
    fitAll(); if(REMOTE) showZoom();
  }
  bar.addEventListener('pointerup',done);
  bar.addEventListener('pointercancel',done);
})();
// ── 시계·경과 시간 ── 받은 순간부터 이 휴대폰 시계로 이어서 센다(매초 받지 않는다).
var clk={ms:0,at:0,run:false,show:false,target:0,rev:-1,last:null,paused:false};
function takeClock(text){
  var m=/^\{"clock_ms":(\d+),/.exec(text);
  if(!m) return text;
  var ms=+m[1], now=Date.now(), pred=clk.ms+(clk.run?now-clk.at:0);
  clk.last={ms:ms,now:now};
  // 폴링(0.5초)마다 맞추면 오가는 시간만큼 초가 흔들린다 — 1.5초 넘게 어긋날 때만 다시 맞춘다.
  if(Math.abs(pred-ms)>1500){ clk.ms=ms; clk.at=now; }
  return '{'+text.substring(m[0].length);
}
function renderClock(c){
  if(!c){ clk.show=false; drawClock(); return; }
  if(clk.last && (c.rev!==clk.rev || c.running!==clk.run)){ clk.ms=clk.last.ms; clk.at=clk.last.now; }
  clk.rev=c.rev; clk.run=!!c.running; clk.show=!!c.show; clk.target=c.target_ms||0;
  drawClock();
}
function two(n){ return (n<10?'0':'')+n; }
// 싱어창 머리줄(#clock)과 발표자 모드 이동 줄(#pclock) 두 곳에 같은 값을 그린다.
function drawClock(){
  ['clock','pclock'].forEach(function(id){
    var box=$(id);
    if(!clk.show){ box.textContent=''; return; }
    var ms=clk.ms+(clk.run?Date.now()-clk.at:0), sec=Math.floor(ms/1000);
    var now=new Date(), h=now.getHours();
    var time=(h<12?'오전 ':'오후 ')+((h%12)||12)+':'+two(now.getMinutes());
    var cls=clk.target>0 && ms>clk.target ? 'over' : (clk.target>0 && ms>=clk.target*0.8 ? 'warn' : '');
    box.textContent=time+' · ';
    box.appendChild(el('span',cls,two(Math.floor(sec/60))+':'+two(sec%60)));
    if(clk.target>0) box.appendChild(document.createTextNode(' / '+two(Math.floor(clk.target/60000))+':00'));
  });
}
setInterval(drawClock,500);
var lastData=null;
function render(d){
  lastData=d;
  renderClock(d.clock);
  var cur=d.current||{}, next=d.next;
  document.getElementById('title').textContent=cur.title||'';
  document.getElementById('key').textContent=chordsOn()?(cur.key_label||''):'';
  // 현재·다음 둘 다 코드가 없으면 흐리게(누를 수는 있다).
  document.getElementById('chords').classList.toggle('dim',!hasChords(cur) && !hasChords(next));
  document.getElementById('page').textContent=d.page_number+' / '+d.total_pages;
  var badge=document.getElementById('badge'); badge.textContent=''; badge.className='';
  if(d.blackout){ badge.textContent='관객 화면 꺼짐'; badge.className='badge'; }
  var nt=next&&next.title; document.getElementById('label').textContent=
    (nt && nt!==cur.title) ? '다음 · '+nt : '다음';
  // 메모·확대·메시지만 바뀌었으면 다시 채우지 않는다(이미지를 다시 받느라 깜빡이지 않게).
  var pages=JSON.stringify([d.current,next,chordsOn()]);
  if(pages!==lastPages){
    lastPages=pages;
    fill(document.getElementById('current'), d.current, '빈 화면');
    fill(document.getElementById('next'), next, '마지막 페이지');
    fitAll();
  }
  if(REMOTE){ renderRemote(d); renderPresenter(d); }
}
var lastPages='';
function setBadge(text, cls){
  var b=document.getElementById('badge'); b.textContent=text; b.className=cls;
}
var last='';
// 연결 상태. null = 아직 모름(처음 연결 중). 끊긴 지 10초가 넘으면 발표자에게 까닭을 짐작해 알린다.
var alive=null, deadTimer=null;
function setAlive(v){
  if(alive===v) return;
  alive=v;
  document.body.classList.toggle('dead',!v);
  clearTimeout(deadTimer);
  if(!v){
    live('연결 끊김');
    if(REMOTE) deadTimer=setTimeout(function(){
      hint('발표가 끝났거나 연결이 끊겼습니다. PC 에서 다시 켜지면 저절로 이어집니다');
    },10000);
  }else pagesAsked=''; // 다시 붙으면 목록을 한 번 다시 받는다
}
function offline(){ last=''; lastPages=''; setBadge('연결 끊김','badge off'); setAlive(false); }
function apply(text){
  setAlive(true);
  text=takeClock(text);
  if(text===last) return;
  last=text;
  // 아직 보낸 페이지가 없어도({}) 연결은 된 것이니 "연결 끊김" 은 지운다.
  if(text==='{}'){ setBadge('',''); if(PRESENTER && !lastData) fill($('current'),null,'빈 화면'); return; }
  try{ render(JSON.parse(text)); }catch(_){}
}
if(location.protocol==='https:'){
  // 바깥 망 터널 주소: Cloudflare 임시 터널이 SSE 를 흘려보내지 않아서 폴링.
  // 끊기면(PC 인터넷이 잠깐 끊김 등) 간격을 3초까지 늘려 가며 계속 묻는다 — 터널이 같은 주소로
  // 다시 붙으면 저절로 이어진다. 터널 주소는 앱에서 발표를 다시 시작하면 바뀌므로 그때는 새 QR 로 연다.
  // 화면이 가려져 있는 동안은 묻지 않는다(배터리).
  var delay=500, timer=null;
  function poll(){
    timer=null;
    if(document.hidden) return;
    fetch('/state'+Q,{cache:'no-store'})
      .then(function(r){
        checkPin(r);
        if(!r.ok) throw 0;
        return r.text().then(function(t){ apply(t); delay=500; });
      })
      .catch(function(){ offline(); delay=Math.min(delay*2,3000); })
      .then(function(){ if(!timer) timer=setTimeout(poll,delay); });
  }
  document.addEventListener('visibilitychange', function(){
    if(!document.hidden && !timer){ delay=500; poll(); }
  });
  poll();
}else{
  // 같은 망(http): SSE. 브라우저가 끊기면 다시 붙지만, 아예 닫아 버리면(서버가 한동안 꺼져 있음 등)
  // 3초 뒤 새로 연다 — 발표를 끝냈다 다시 시작해도 휴대폰은 그대로 두면 이어진다.
  var es=null, reopen=null;
  function connect(){
    reopen=null;
    es=new EventSource('/events'+Q);
    es.onopen=function(){ if(last==='') apply('{}'); };
    es.onmessage=function(ev){ apply(ev.data); };
    es.onerror=function(){
      offline();
      if(es.readyState===2 && !reopen){
        es.close();
        // 닫힌 까닭이 PIN(401)이면 다시 읽어 PIN 을 묻는다.
        if(REMOTE) fetch('/state'+Q,{cache:'no-store'}).then(checkPin).catch(function(){});
        reopen=setTimeout(connect,3000);
      }
    };
  }
  // 화면을 다시 켰을 때 연결이 닫혀 있으면 바로 다시 연다.
  document.addEventListener('visibilitychange', function(){
    if(!document.hidden && es && es.readyState===2){ clearTimeout(reopen); connect(); }
  });
  connect();
}
window.addEventListener('resize', relayout);

// ── 발표자 주소: 싱어창 제스처 ──
// 좌우로 밀기·양쪽 끝 누르기 = 넘기기, 두 손가락 = 확대(확대 중엔 한 손가락 = 옮기기),
// 가운데 두 번 누르기 = 확대 풀기, '화면 끄기' 길게 = 블랙아웃.
var state=null, zoom={on:false,x:0,y:0,size:1}, zoomLocalUntil=0, zoomSyncTimer=null;
var MIN_ZOOM=0.12, MAX_ZOOM=0.9; // 발표 보기 _ZoomRegionOverlay 와 같다
function renderRemote(d){
  state=d;
  var note=document.getElementById('note');
  // 메모가 생기거나 없어지면 다음 페이지 칸 높이가 바뀌므로 글자 크기를 다시 맞춘다.
  if(note.textContent!==(d.note||'')){ note.textContent=d.note||''; fitAll(); }
  showMessage(d);
  ['black','pblack'].forEach(function(id){
    var b=$(id);
    b.classList.toggle('on',!!d.blackout); // 길게 누르는 중(hold)은 그대로 둔다
    b.setAttribute('aria-label',d.blackout?'관객 화면 켜기, 길게 누르기':'관객 화면 끄기, 길게 누르기');
  });
  $('black').firstChild.textContent=d.blackout?'화면 켜기 (길게 누르기)':'화면 끄기 (길게 누르기)';
  // 손으로 확대하는 중·직후엔 서버 값(조금 전 상태)으로 되돌리지 않는다. 그 사이 온 값은
  // 다시 오지 않으므로(같은 글은 apply 가 거른다) 끝나면 마지막으로 받은 값을 입힌다.
  var wait=zoomLocalUntil-Date.now();
  if(wait>0){
    clearTimeout(zoomSyncTimer);
    zoomSyncTimer=setTimeout(function(){ if(state && !g) renderRemote(state); },wait+50);
  }else if(d.zoom && !g){
    zoom=d.zoom.on?{on:true,x:d.zoom.x,y:d.zoom.y,size:d.zoom.size}:{on:false,x:0,y:0,size:1};
  }
  showZoom();
}
// 현재 페이지 상자 안에 가운데로 맞춘 16:9 틀(상자 안쪽 좌표). 확대 좌표(= 슬라이드 좌표)의 기준이다.
// 그림은 이 틀에 꼭 맞게 그려지고, 가사는 휴대폰이 디자인 없이 그리므로 원래 대략이다.
function slideFrame(box){
  var w=box.clientWidth||1, h=box.clientHeight||1, fw=Math.min(w,h*16/9), fh=fw*9/16;
  return {x:(w-fw)/2, y:(h-fh)/2, w:fw, h:fh};
}
function showZoom(){
  var box=document.getElementById('current'), st=box.querySelector('.stage'); if(!st) return;
  if(!zoom.on || PRESENTER){ st.style.transform=''; return; } // 발표자 모드는 확대 없이 관객 화면 전체를 본다
  var f=slideFrame(box);
  st.style.transform='translate('+f.x+'px,'+f.y+'px) scale('+(1/zoom.size)+') translate('
    +(-f.x-zoom.x*f.w)+'px,'+(-f.y-zoom.y*f.h)+'px)';
}
function control(q){
  return fetch('/control?'+(Q?'p=1&':'')+'action='+q,{method:'POST',cache:'no-store'})
    .then(function(r){ checkPin(r); return r.ok?r.text():null; })
    .then(function(t){ if(t) apply(t); })
    .catch(function(){});
}
// 코드 줄 때문에 휴대폰 가사 배치가 관객 화면과 더 달라진다 — 처음 한 번만 알린다.
function chordZoomHint(){
  try{ if(localStorage.getItem('singer_chord_zoom_hint')) return; localStorage.setItem('singer_chord_zoom_hint','1'); }catch(_){}
  hint('코드 줄 때문에 확대 위치가 실제 화면과 조금 다를 수 있어요');
}
function buzz(){ if(navigator.vibrate) navigator.vibrate(15); }
var flashTimer=null;
function go(dir){
  if(!state) return;
  // 마지막·첫 페이지면 넘길 곳이 없다.
  if(dir>0 ? state.page_number>=state.total_pages : state.page_number<=1) return;
  if(!PRESENTER){
    var f=document.getElementById('flash');
    f.className=dir>0?'r show':'show';
    clearTimeout(flashTimer); flashTimer=setTimeout(function(){ f.className=dir>0?'r':''; },120);
  }
  buzz();
  // from = 보던 쪽. 앱은 지금 쪽과 다르면 무시한다(두 장씩 넘어가지 않게).
  control((dir>0?'next':'prev')+'&from='+state.page_number);
}
var zoomTimer=null;
function sendZoom(){
  zoomLocalUntil=Date.now()+800;
  if(zoomTimer) return; // 끄는 동안 80ms 에 한 번만
  zoomTimer=setTimeout(function(){
    zoomTimer=null;
    var on=zoom.on && zoom.size<=MAX_ZOOM;
    control('zoom&on='+(on?1:0)+'&x='+zoom.x.toFixed(4)+'&y='+zoom.y.toFixed(4)
      +'&size='+Math.min(zoom.size,MAX_ZOOM).toFixed(4));
  },80);
}
function clamp(v,lo,hi){ return Math.max(lo,Math.min(hi,v)); }
function points(e){ return Array.prototype.map.call(e.touches,function(t){ return {x:t.clientX,y:t.clientY}; }); }
function middle(p){ var x=0,y=0; p.forEach(function(q){ x+=q.x; y+=q.y; }); return {x:x/p.length,y:y/p.length}; }
function spread(p){ return p.length<2?1:Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y)||1; }
var g=null, lastTap=0;
// 손가락 수가 바뀔 때마다 기준을 다시 잡는다(두 손가락 → 한 손가락으로 옮기기 등).
function begin(e, keep){
  // 테두리를 뺀 안쪽(showZoom 이 쓰는 clientWidth 와 같은 기준).
  var p=points(e), m=middle(p), box=document.getElementById('current'), b=box.getBoundingClientRect();
  var f=slideFrame(box), r={left:b.left+box.clientLeft+f.x, top:b.top+box.clientTop+f.y, width:f.w, height:f.h};
  g={n:p.length, t0:keep?keep.t0:Date.now(), sx:keep?keep.sx:m.x, sy:keep?keep.sy:m.y,
    moved:keep?keep.moved:false, multi:(keep&&keep.multi)||p.length>1, zoomed:keep?keep.zoomed:false,
    onNote:keep?keep.onNote:!!e.target.closest('#note,#message'),
    onMessage:keep?keep.onMessage:!!e.target.closest('#message'),
    r:r, mx:m.x, my:m.y, lx:m.x, ly:m.y, d0:spread(p), z0:{x:zoom.on?zoom.x:0, y:zoom.on?zoom.y:0, size:zoom.on?zoom.size:1}};
}
if(REMOTE){
  // 메모칸 위는 위아래 밀기를 브라우저에 맡긴다(긴 메모 스크롤). 좌우 밀기는 그대로 넘기기.
  // 메시지 칸도 같고, 스크롤하다 넘어가지 않게 좌우 밀기까지 막는다.
  function own(e){ if(!e.target.closest('#note,#message')) e.preventDefault(); }
  document.addEventListener('touchstart',function(e){
    // 발표자 모드는 버튼·썸네일로만 옮긴다(밀기·확대·끝 누르기 없음, 목록은 브라우저가 스크롤).
    if(PRESENTER || e.target.closest('#bar,#layout,#chords,#split,#mode')) return;
    own(e);
    begin(e,g);
  },{passive:false});
  document.addEventListener('touchmove',function(e){
    if(!g) return;
    own(e);
    var p=points(e); if(p.length!==g.n) return;
    var m=middle(p);
    g.lx=m.x; g.ly=m.y;
    if(Math.abs(m.x-g.sx)>10 || Math.abs(m.y-g.sy)>10) g.moved=true;
    // 메모칸에서 시작한 손가락은 좌우 밀기만(스크롤하다 확대가 움직이지 않게).
    if(g.onNote || !(p.length>1 || zoom.on) || !g.moved) return;
    // 손가락 아래 슬라이드 점이 그대로 손가락을 따라오게.
    var size=clamp(g.z0.size*g.d0/spread(p),MIN_ZOOM,1);
    var px=g.z0.x+(g.mx-g.r.left)/g.r.width*g.z0.size, py=g.z0.y+(g.my-g.r.top)/g.r.height*g.z0.size;
    zoom={on:size<0.999, size:size,
      x:clamp(px-(m.x-g.r.left)/g.r.width*size,0,1-size), y:clamp(py-(m.y-g.r.top)/g.r.height*size,0,1-size)};
    if(!g.zoomed && CHORDS && state && hasChords(state.current)) chordZoomHint();
    g.zoomed=true;
    showZoom(); sendZoom();
  },{passive:false});
  function end(e){
    if(!g) return;
    if(e.touches.length){ begin(e,g); return; }
    // 끝 좌표는 마지막 touchmove 값(changedTouches 는 브라우저마다 믿기 어렵다).
    var dx=g.lx-g.sx, dy=g.ly-g.sy, dt=Date.now()-g.t0, w=window.innerWidth;
    if(g.zoomed){
      // 살짝만 벌렸으면(관객 화면 확대 범위 밖) 확대를 끈다.
      if(zoom.size>MAX_ZOOM) zoom={on:false,x:0,y:0,size:1};
      showZoom(); sendZoom();
    }else if(!g.multi && !g.moved && dt<350 && !g.onNote){
      if(g.lx<w*0.22) go(-1);
      else if(g.lx>w*0.78) go(1);
      else if(Date.now()-lastTap<320 && zoom.on){ zoom={on:false,x:0,y:0,size:1}; showZoom(); sendZoom(); buzz(); lastTap=0; }
      else lastTap=Date.now();
    }else if(!g.multi && !g.onMessage && dt<600 && Math.abs(dx)>60 && Math.abs(dx)>1.5*Math.abs(dy)){
      go(dx<0?1:-1);
    }
    g=null;
  }
  document.addEventListener('touchend',end);
  document.addEventListener('touchcancel',function(){ g=null; });
  // 블랙아웃은 잘못 눌러 꺼지지 않게 0.6초 길게 눌러야 한다. 세로 막대(#black)·가로 ⏻(#pblack) 공통.
  ['black','pblack'].forEach(function(id){
    var black=$(id), holdTimer=null;
    function release(){ clearTimeout(holdTimer); holdTimer=null; black.classList.remove('hold'); }
    black.addEventListener('touchstart',function(e){
      e.preventDefault();
      if(!state) return;
      black.classList.add('hold');
      holdTimer=setTimeout(function(){
        release(); buzz();
        control('blackout&on='+(state.blackout?0:1));
      },600);
    },{passive:false});
    black.addEventListener('touchend',release);
    black.addEventListener('touchcancel',release);
  });
}

// ── 메시지 알림(발표자 주소 두 모드 공통) ──
// message_id 가 바뀌면 띄우고 60초 뒤(PC 가 비우면 그 전에, 띠를 누르면 바로) 감춘다.
// 같은 글을 다시 보내도 id 가 바뀌어 다시 뜬다. 닫은 알림은 같은 id 로 다시 와도 안 띄운다.
var msgId, msgTimer=null, msgOut=null;
function showMessage(d){
  var text=d.message||'', m=$('message');
  if(!text){ hideMessage(); return; }
  if(d.message_id===msgId) return;
  msgId=d.message_id;
  var t=$('mtext'); t.textContent=text; t.scrollTop=0;
  clearTimeout(msgOut);
  m.classList.add('show'); void m.offsetWidth; m.classList.add('in');
  var bar=$('mbar');
  bar.style.transition='none'; bar.style.transform='scaleX(1)'; void bar.offsetWidth;
  bar.style.transition='transform 60s linear'; bar.style.transform='scaleX(0)';
  if(navigator.vibrate) navigator.vibrate(30);
  clearTimeout(msgTimer); msgTimer=setTimeout(hideMessage,60000);
  relayout();
}
function hideMessage(){
  var m=$('message');
  clearTimeout(msgTimer);
  if(!m.classList.contains('in')) return;
  m.classList.remove('in');
  clearTimeout(msgOut);
  msgOut=setTimeout(function(){ m.classList.remove('show'); relayout(); },300);
}
$('message').addEventListener('click',hideMessage);

// ── 발표자 모드 ──
// 이전·다음 = go(±1)(from 검사), 썸네일 = goto&id=<슬라이드 키>. 목록은 pages_rev 가 바뀔 때만 /pages 로 받는다.
var pages=null, pagesAsked='', pagesSeq=0, curIdx=-1, lastBo=null;
var pend=-1, pendTimer=null, stripTouched=0;
function live(text){ $('live').textContent=text; }
function stat(text, retry){
  var s=$('pstat'); s.className=''; s.textContent=text;
  if(retry){ var b=el('button','retry','다시 시도'); b.addEventListener('click',function(){ syncPages(true); }); s.appendChild(b); }
}
function syncPages(force){
  if(!PRESENTER || !lastData) return;
  var rev=lastData.pages_rev||'';
  if(!force && rev===pagesAsked) return;
  pagesAsked=rev;
  if(!pages) stat('페이지 목록을 받는 중…');
  var seq=++pagesSeq;
  fetch('/pages'+Q,{cache:'no-store'})
    .then(function(r){ checkPin(r); if(!r.ok) throw 0; return r.json(); })
    .then(function(j){ if(seq!==pagesSeq) return; pages=j.pages||[]; buildStrip(); })
    // 받는 동안·실패해도 옛 목록은 그대로 둔다. 목록이 없을 때만 알린다(다음 pages_rev 에 다시 받는다).
    .catch(function(){ if(seq===pagesSeq && !pages) stat('페이지 목록을 받지 못했습니다',true); });
}
function buildStrip(){
  var s=$('strip'); s.textContent='';
  pages.forEach(function(p,i){
    var b=el('button','th'), kind;
    if(p.image){
      b.classList.add('pic'); kind='그림';
      var im=el('img'); im.alt=''; im.loading='lazy'; im.decoding='async'; im.draggable=false;
      im.onload=function(){ b.classList.add('ok'); };
      im.onerror=function(){ im.remove(); b.classList.remove('pic'); b.insertBefore(el('span','ph','그림 없음'),b.firstChild); };
      im.src=p.image; b.appendChild(im);
    }else if(p.spacer){ b.classList.add('blank','spacer'); b.appendChild(el('span','ph','여백')); kind='여백'; }
    else if(p.blank){ b.classList.add('blank'); b.appendChild(el('span','ph','빈 화면')); kind='빈 화면'; }
    else { b.appendChild(el('span','tx',(p.text||'').split('\n').slice(0,3).join('\n'))); kind='가사'; }
    b.appendChild(el('span','no',String(i+1)));
    if(p.first && p.title) b.appendChild(el('span','tt',p.title));
    b.setAttribute('aria-label',(i+1)+'쪽, '+(kind==='가사' && p.title ? p.title+', ' : '')+kind);
    b.addEventListener('click',function(){ gotoPage(i); });
    s.appendChild(b);
  });
  $('phead').textContent='모든 페이지 · '+pages.length+'장';
  stat('');
  markCurrent(true);
}
function centerThumb(smooth){
  var s=$('strip'), t=s.children[curIdx]; if(!t) return;
  s.scrollTo({left:t.offsetLeft-(s.clientWidth-t.offsetWidth)/2, behavior:smooth?'smooth':'auto'});
}
// 지금 페이지 강조. 손으로 목록을 민 지 3초 안이면 스크롤은 하지 않는다.
function markCurrent(instant){
  var ths=$('strip').children;
  for(var i=0;i<ths.length;i++){
    var on=i===curIdx; ths[i].classList.toggle('cur',on);
    if(on) ths[i].setAttribute('aria-current','page'); else ths[i].removeAttribute('aria-current');
  }
  if(Date.now()-stripTouched>3000) centerThumb(!instant);
}
function clearPending(){
  clearTimeout(pendTimer); pend=-1; document.body.classList.remove('pending');
  Array.prototype.forEach.call(document.querySelectorAll('.th.pend'),function(t){ t.classList.remove('pend'); });
}
function canAct(){
  if(alive) return true;
  hint('연결이 끊겨 넘길 수 없습니다');
  return false;
}
function gotoPage(i){
  if(!canAct() || !state || !pages[i]) return;
  clearPending();
  if(i===curIdx) return;
  pend=i; $('strip').children[i].classList.add('pend'); document.body.classList.add('pending');
  buzz();
  control('goto&id='+encodeURIComponent(pages[i].id));
  // 2초 안에 안 바뀌면 그 사이 콘티가 바뀐 것 — 목록을 다시 받고 다시 누르게 한다.
  pendTimer=setTimeout(function(){
    if(pend!==i) return;
    clearPending(); hint('페이지 목록이 바뀌었습니다. 다시 눌러 주세요'); syncPages(true);
  },2000);
}
function renderPresenter(d){
  var n=d.page_number||0, t=d.total_pages||0;
  $('pnum').textContent=t?n+' / '+t:'– / –';
  $('pmid').setAttribute('aria-label','지금 '+n+'쪽, 전체 '+t+'쪽. 누르면 목록을 지금 페이지로 옮깁니다');
  $('pprev').disabled=n<=1; $('pnext').disabled=n>=t;
  document.body.classList.toggle('bo',!!d.blackout);
  var first=lastBo===null; // 처음 받은 값은 읽어 주지 않는다
  if(PRESENTER && !first && lastBo!==!!d.blackout && d.blackout) live('관객 화면 꺼짐');
  lastBo=!!d.blackout;
  if(n-1===pend) clearPending();
  if(n-1!==curIdx){ curIdx=n-1; if(PRESENTER && !first && n) live(n+'쪽으로 이동'); markCurrent(false); }
  syncPages();
}
$('pprev').addEventListener('click',function(){ if(canAct()) go(-1); });
$('pnext').addEventListener('click',function(){ if(canAct()) go(1); });
$('pmid').addEventListener('click',function(){ centerThumb(true); });
['touchmove','wheel'].forEach(function(ev){
  $('strip').addEventListener(ev,function(){ stripTouched=Date.now(); },{passive:true});
});
// 발표자 주소 화면의 [발표자 모드 | 싱어창]. 휴대폰마다 기억한다(기본 발표자 모드).
function setView(v){
  PRESENTER=REMOTE && v==='presenter';
  document.body.classList.toggle('presenter',PRESENTER);
  document.title=PRESENTER?'발표자 모드':'싱어창';
  Array.prototype.forEach.call(document.querySelectorAll('#mode button'),function(b){
    b.setAttribute('aria-pressed',String(b.getAttribute('data-v')===(PRESENTER?'presenter':'singer')));
  });
  if(REMOTE) try{ localStorage.setItem('presenter_view',PRESENTER?'presenter':'singer'); }catch(_){}
  if(lastData){ lastPages=''; render(lastData); }
  else if(PRESENTER) fill($('current'),null,'연결 중…');
  if(PRESENTER && !pages) stat('페이지 목록을 받는 중…');
  relayout();
  if(PRESENTER) markCurrent(true);
}
Array.prototype.forEach.call(document.querySelectorAll('#mode button'),function(b){
  b.addEventListener('click',function(){ setView(b.getAttribute('data-v')); });
});
// 화면 꺼짐 방지. https(바깥 망 터널 주소)에서만 된다 — 같은 망 http 주소면 조용히 건너뛰고,
// 앱 다이얼로그가 "휴대폰 자동 잠금을 꺼 두라"고 안내한다. 탭이 가려지면 풀리므로 돌아올 때 다시 건다.
function keepAwake(){
  if(navigator.wakeLock && document.visibilityState==='visible')
    navigator.wakeLock.request('screen').catch(function(){});
}
keepAwake();
document.addEventListener('visibilitychange', keepAwake);
// 저장해 둔 배치(맨 끝에서 — showZoom 이 쓰는 zoom 이 정해진 뒤에).
var savedLayout=null; try{ savedLayout=localStorage.getItem('singer_layout'); }catch(_){}
var savedSplit=NaN; try{ savedSplit=parseFloat(localStorage.getItem('singer_split')); }catch(_){}
setSplit(isNaN(savedSplit)?0.65:savedSplit);
setLayout(savedLayout==='row');
var savedView=null; try{ savedView=localStorage.getItem('presenter_view'); }catch(_){}
setView(savedView==='singer'?'singer':'presenter');
</script></body></html>
''';
