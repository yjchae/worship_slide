import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// 같은 망의 휴대폰 브라우저에서 싱어 화면(현재 + 다음 페이지)을 보게 하는 작은 HTTP 서버.
///
/// - `GET /`        싱어 페이지(HTML 하나, 외부 파일 없음)
/// - `GET /events`  Server-Sent Events. 페이지가 바뀔 때마다 [SingerViewData] JSON 을 민다.
///                  브라우저 EventSource 가 끊기면 알아서 다시 붙고, 붙자마자 지금 페이지를 받는다
/// - `GET /img/current`, `/img/next`  지금·다음 페이지 이미지(PPT 페이지).
///   **로컬 경로를 그대로 받지 않는다** — 지금 띄운 두 장만 내보내므로 망 안의 누구도 다른 파일은 못 읽는다
///
/// 모든 요청은 켤 때마다 새로 만드는 토큰(`?k=`)이 맞아야 한다. 주소·QR 에 들어 있어서 찍은 사람만 본다
/// (게스트 와이파이처럼 모르는 사람이 같은 망에 있어도 포트만으로는 못 본다).
///
/// **발표자 리모컨**: 같은 페이지를 리모컨 키(`?k=` 가 [remoteToken])로 열면 넘기기·확대·블랙아웃 제스처가 켜진다.
/// - `POST /control?action=next|prev&from=<보던 쪽>` / `action=blackout&on=0|1` / `action=zoom&on&x&y&size`
///   → [onControl] 을 부르고 바뀐 상태 JSON 을 돌려준다
/// - 리모컨에만 가는 값(`note`·`zoom`, [remoteOnlyKeys])은 싱어 키로 받는 쪽에서 뺀다.
///   싱어 QR 을 단체방에 돌려도 그 키로는 넘기지도, 발표자 메모를 보지도 못한다
///
/// **바깥 망 주소**: cloudflared 가 깔려 있으면 Cloudflare 임시 터널(`*.trycloudflare.com`, 계정 불필요)을
/// 같이 띄워 https 공개 주소를 만든다. 다른 망의 휴대폰도 그 주소로 본다. 토큰은 그대로 필요하다.
/// 없으면 같은 망 주소만 쓴다(LibreOffice·Tesseract 처럼 선택 의존성).
enum TunnelState { off, missing, connecting, ready, failed }

class SingerWebServer {
  static const preferredPort = 8765;

  HttpServer? _server;
  final _clients = <HttpResponse>{};
  Timer? _ping;
  String? _lastJson; // 지금 페이지. SSE(/events)·폴링(/state) 둘 다 이걸 보낸다
  String _token = '';
  String _remoteToken = '';
  String? _lastRemoteJson; // 리모컨용(메모·확대 포함)
  final _remoteClients = <HttpResponse>{};

  static const remoteOnlyKeys = ['note', 'zoom'];

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

  /// 다른 망에서 열 주소(토큰 포함). 터널이 아직이면 null.
  String? publicUrl({bool remote = false}) => _publicBase == null
      ? null
      : '$_publicBase/?k=${remote ? _remoteToken : _token}';

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  /// 휴대폰에서 열 주소(토큰 포함).
  String urlFor(String address, {bool remote = false}) =>
      'http://$address:$port/?k=${remote ? _remoteToken : _token}';

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
    final rnd = Random.secure();
    // 터널 주소는 인터넷 어디서나 닿으므로 넉넉히(31^16 ≈ 7×10^23).
    String newToken() => List.generate(
      16,
      (_) => 'abcdefghjkmnpqrstuvwxyz23456789'[rnd.nextInt(31)],
    ).join();
    _token = newToken();
    _remoteToken = newToken();
    try {
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
    _images.clear();
    running.value = false;
  }

  /// cloudflared 를 켜 둔 뒤에 설치했을 때 — 서버는 그대로 두고 터널만 띄운다(같은 망 주소·키 유지).
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
    final public = <String, dynamic>{...data};
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
        copy['image_path'] = '/img/$key?v=${_version(path)}&k=$_token';
      }
      public[key] = copy;
    }
    final remoteJson = jsonEncode(public);
    for (final k in remoteOnlyKeys) {
      public.remove(k);
    }
    final json = jsonEncode(public);
    if (remoteJson == _lastRemoteJson) return;
    _lastRemoteJson = remoteJson;
    // 메모·확대만 바뀌었으면 싱어 쪽엔 보내지 않는다.
    final singerChanged = json != _lastJson;
    _lastJson = json;
    _broadcast(
      singerChanged ? 'data: $json\n\n' : null,
      'data: $remoteJson\n\n',
    );
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
    final key = req.uri.queryParameters['k'];
    final remote = _remoteToken.isNotEmpty && key == _remoteToken;
    if (!remote && (_token.isEmpty || key != _token)) {
      res.statusCode = HttpStatus.forbidden;
      res.headers.contentType = ContentType.text;
      res.write('QR 코드나 앱에 나온 주소로 다시 열어 주세요.');
      await res.close();
      return;
    }
    try {
      switch (req.uri.path) {
        case '/':
          res.headers.contentType = ContentType.html;
          res.write(
            remote
                ? singerPageHtml.replaceFirst('<body>', '<body class="remote">')
                : singerPageHtml,
          );
          await res.close();
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
          res.write(last == null ? ': hello\n\n' : 'data: $last\n\n');
        // 지금 페이지 JSON 한 번. Cloudflare 임시 터널은 SSE 를 붙잡아 두고 안 흘려보내서
        // (trycloudflare 의 알려진 제한) 터널(https) 주소에서는 페이지가 이걸 0.5초마다 묻는다.
        case '/state':
          res.headers
            ..contentType = ContentType.json
            ..set(HttpHeaders.cacheControlHeader, 'no-store');
          res.write((remote ? _lastRemoteJson : _lastJson) ?? '{}');
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
          res.write(_lastRemoteJson ?? '{}');
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
          res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
          final lower = path.toLowerCase();
          res.headers.contentType =
              lower.endsWith('.jpg') || lower.endsWith('.jpeg')
              ? ContentType('image', 'jpeg')
              : ContentType('image', 'png');
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

/// 싱어 페이지. 네이티브 싱어 창(MainFlutterWindow.swift)과 같은 모양·같은 글자 맞춤 규칙
/// (원본 줄 그대로, 너무 작아지면 그때만 줄바꿈). 글자는 textContent 로만 넣는다(HTML 주입 없음).
///
/// `<body class="remote">`(리모컨 키로 연 경우)면 발표자 리모컨이 된다: 현재 페이지는 관객 화면과 같은 16:9 틀
/// (그래야 핀치로 고른 영역이 관객 화면 좌표와 맞는다), 메모·블랙아웃 버튼, 제스처.
/// 확대 영역은 발표 보기 '영역 확대'와 같은 값(x·y = 왼쪽 위, size = 폭 비율, 0~1)이다.
const singerPageHtml =
    r'''<!DOCTYPE html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>싱어 화면</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box;}
  html,body{width:100%;height:100%;overflow:hidden;background:#0d0f12;color:#fff;
    font-family:-apple-system,'Apple SD Gothic Neo','Malgun Gothic','Noto Sans KR',sans-serif;}
  body{display:flex;flex-direction:column;height:100vh;height:100dvh;
    padding:max(2vh,env(safe-area-inset-top)) 3vw max(2vh,env(safe-area-inset-bottom));gap:1.4vh;}
  header{display:flex;align-items:center;gap:2vw;font-size:2.4vh;color:#9aa4b1;flex:none;}
  #title{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-weight:600;}
  #page{font-variant-numeric:tabular-nums;font-weight:700;color:#e6e9ee;}
  .badge{background:#e5484d;color:#fff;border-radius:999px;padding:.2em .8em;font-size:2vh;font-weight:700;}
  .off{background:#59626e;}
  #label{font-size:2.1vh;color:#8b95a2;font-weight:600;flex:none;white-space:nowrap;overflow:hidden;
    text-overflow:ellipsis;border-top:1px solid #3a424d;padding-top:1.2vh;margin-top:.4vh;}
  .box{position:relative;border-radius:1.4vh;overflow:hidden;min-height:0;}
  .stage{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
    padding:1.6vh 3vw;transform-origin:0 0;}
  #panes{flex:1;min-height:0;display:flex;flex-direction:column;gap:1.4vh;}
  #side{flex:37;min-height:0;display:flex;flex-direction:column;gap:1.4vh;}
  #current{flex:63;background:#1b2028;border:2px solid #5a6472;}
  #next{flex:1;background:#0f1215;border:1px solid #232930;}
  /* 좌우 배치(휴대폰마다 따로 기억) */
  body.row #panes{flex-direction:row;gap:2vw;}
  body.row #label{border-top:none;padding-top:0;margin-top:0;}
  #layout{flex:none;background:#1b2028;color:#e6e9ee;border:1px solid #3a424d;border-radius:.8vh;
    font:inherit;font-size:2vh;font-weight:700;padding:.3em .7em;}
  .fit{width:100%;max-height:100%;text-align:center;line-height:1.3;font-weight:700;}
  .main,.sub{white-space:pre;}
  .wrap .main,.wrap .sub{white-space:pre-wrap;word-break:keep-all;}
  .sub{color:#ffd54f;font-size:.78em;margin-top:.45em;}
  #next .main{color:#c3cad4;}
  #next .sub{color:#b8a25a;}
  .placeholder{color:#59626e;font-size:3vh;font-weight:600;}
  img{max-width:100%;max-height:100%;object-fit:contain;display:block;}
  #note,#bar,#flash{display:none;}
  body.remote{touch-action:none;overscroll-behavior:none;-webkit-user-select:none;user-select:none;
    -webkit-touch-callout:none;}
  .remote #current{flex:none;aspect-ratio:16/9;width:min(100%,calc(46vh*16/9));
    width:min(100%,calc(46dvh*16/9));align-self:center;}
  .remote.row #current{width:min(62%,calc(60vh*16/9));width:min(62%,calc(60dvh*16/9));}
  .remote #current .stage{padding:0;}
  .remote #current .fit{padding:0 4%;}
  .remote #side{flex:1;}
  .remote #next{flex:none;aspect-ratio:16/9;width:calc(min(100%,calc(46vh*16/9))*.62);
    width:calc(min(100%,calc(46dvh*16/9))*.62);align-self:center;}
  .remote.row #side{justify-content:center;}
  .remote.row #next{width:100%;}
  .remote #note{display:block;flex:none;max-height:16vh;overflow:auto;touch-action:pan-y;white-space:pre-wrap;
    font-size:2.3vh;line-height:1.4;color:#e6e9ee;background:#1a1f26;border-left:3px solid #ffd54f;
    border-radius:.8vh;padding:1vh 3vw;}
  .remote #note:empty{display:none;}
  .remote #bar{display:flex;flex:none;}
  #black{flex:1;position:relative;overflow:hidden;border:1px solid #3a424d;border-radius:1vh;background:#1b2028;
    color:#e6e9ee;font:inherit;font-size:2.2vh;font-weight:700;padding:1.6vh 0;}
  #black::before{content:'';position:absolute;inset:0;background:#e5484d;transform:scaleX(0);transform-origin:0 50%;}
  #black.hold::before{transform:scaleX(1);transition:transform .6s linear;}
  #black span{position:relative;}
  #black.on{background:#e5484d;border-color:#e5484d;}
  .remote #flash{display:block;position:fixed;top:0;bottom:0;width:16vw;pointer-events:none;opacity:0;
    transition:opacity .35s;background:linear-gradient(to right,rgba(255,213,79,.45),transparent);}
  #flash.r{right:0;background:linear-gradient(to left,rgba(255,213,79,.45),transparent);}
  #flash.show{opacity:1;transition:none;}
</style></head><body>
  <header><span id="title"></span><span id="badge"></span><span id="page"></span>
    <button id="layout"></button></header>
  <div id="panes">
    <div class="box" id="current"></div>
    <div id="side"><div id="label">다음</div><div class="box" id="next"></div></div>
  </div>
  <div id="note"></div>
  <div id="bar"><button id="black"><span>화면 끄기 (길게 누르기)</span></button></div>
  <div id="flash"></div>
<script>
function el(tag, cls, text){ var e=document.createElement(tag); if(cls) e.className=cls;
  if(text!=null) e.textContent=text; return e; }
var REMOTE=document.body.classList.contains('remote');
if(REMOTE) document.title='발표자 리모컨';
function fill(box, page, empty){
  box.textContent='';
  var st=el('div','stage'); box.appendChild(st);
  if(!page){ st.appendChild(el('div','placeholder',empty)); return; }
  if(page.image_path){ var img=el('img'); img.src=page.image_path; st.appendChild(img); return; }
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
  fitAll(); if(REMOTE) showZoom();
}
document.getElementById('layout').addEventListener('click',function(){
  setLayout(!document.body.classList.contains('row'));
});
function render(d){
  var cur=d.current||{}, next=d.next;
  document.getElementById('title').textContent=cur.title||'';
  document.getElementById('page').textContent=d.page_number+' / '+d.total_pages;
  var badge=document.getElementById('badge'); badge.textContent=''; badge.className='';
  if(d.blackout){ badge.textContent='관객 화면 꺼짐'; badge.className='badge'; }
  var nt=next&&next.title; document.getElementById('label').textContent=
    (nt && nt!==cur.title) ? '다음 · '+nt : '다음';
  // 메모·확대만 바뀌었으면 다시 채우지 않는다(이미지를 다시 받느라 깜빡이지 않게).
  var pages=JSON.stringify([d.current,next]);
  if(pages!==lastPages){
    lastPages=pages;
    fill(document.getElementById('current'), d.current, '빈 화면');
    fill(document.getElementById('next'), next, '마지막 페이지');
    fitAll();
  }
  if(REMOTE) renderRemote(d);
}
var lastPages='';
function setBadge(text, cls){
  var b=document.getElementById('badge'); b.textContent=text; b.className=cls;
}
var last='';
function offline(){ last=''; lastPages=''; setBadge('연결 끊김','badge off'); }
function apply(text){
  if(text===last) return;
  last=text;
  // 아직 보낸 페이지가 없어도({}) 연결은 된 것이니 "연결 끊김" 은 지운다.
  if(text==='{}'){ setBadge('',''); return; }
  try{ render(JSON.parse(text)); }catch(_){}
}
if(location.protocol==='https:'){
  // 바깥 망 터널 주소: Cloudflare 임시 터널이 SSE 를 흘려보내지 않아서 폴링.
  // 끊기면(PC 인터넷이 잠깐 끊김 등) 간격을 3초까지 늘려 가며 계속 묻는다 — 터널이 같은 주소로
  // 다시 붙으면 저절로 이어진다. 403 은 키가 바뀐 것(앱에서 껐다 켬)이라 묻기를 멈춘다.
  // 화면이 가려져 있는 동안은 묻지 않는다(배터리).
  var delay=500, timer=null;
  function poll(){
    timer=null;
    if(document.hidden) return;
    fetch('/state'+location.search,{cache:'no-store'})
      .then(function(r){
        if(r.status===403){ setBadge('주소가 바뀌었습니다 · 새 QR 로 여세요','badge off'); return 'stop'; }
        if(!r.ok) throw 0;
        return r.text().then(function(t){ apply(t); delay=500; });
      })
      .catch(function(){ offline(); delay=Math.min(delay*2,3000); })
      .then(function(stop){ if(stop!=='stop' && !timer) timer=setTimeout(poll,delay); });
  }
  document.addEventListener('visibilitychange', function(){
    if(!document.hidden && !timer){ delay=500; poll(); }
  });
  poll();
}else{
  var es=new EventSource('/events'+location.search);
  es.onopen=function(){ if(last==='') apply('{}'); };
  es.onmessage=function(ev){ apply(ev.data); };
  es.onerror=offline;
}
window.addEventListener('resize', function(){ fitAll(); if(REMOTE) showZoom(); });

// ── 발표자 리모컨 ──
// 좌우로 밀기·양쪽 끝 누르기 = 넘기기, 두 손가락 = 확대(확대 중엔 한 손가락 = 옮기기),
// 가운데 두 번 누르기 = 확대 풀기, '화면 끄기' 길게 = 블랙아웃.
var state=null, zoom={on:false,x:0,y:0,size:1}, zoomLocalUntil=0, zoomSyncTimer=null;
var MIN_ZOOM=0.12, MAX_ZOOM=0.9; // 발표 보기 _ZoomRegionOverlay 와 같다
function renderRemote(d){
  state=d;
  var note=document.getElementById('note');
  // 메모가 생기거나 없어지면 다음 페이지 칸 높이가 바뀌므로 글자 크기를 다시 맞춘다.
  if(note.textContent!==(d.note||'')){ note.textContent=d.note||''; fitAll(); }
  var b=document.getElementById('black');
  b.classList.toggle('on',!!d.blackout); // 길게 누르는 중(hold)은 그대로 둔다
  b.firstChild.textContent=d.blackout?'화면 켜기 (길게 누르기)':'화면 끄기 (길게 누르기)';
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
function showZoom(){
  var box=document.getElementById('current'), st=box.querySelector('.stage'); if(!st) return;
  if(!zoom.on){ st.style.transform=''; return; }
  st.style.transform='scale('+(1/zoom.size)+') translate('+(-zoom.x*box.clientWidth)+'px,'
    +(-zoom.y*box.clientHeight)+'px)';
}
function control(q){
  return fetch('/control'+location.search+'&action='+q,{method:'POST',cache:'no-store'})
    .then(function(r){ return r.ok?r.text():null; })
    .then(function(t){ if(t) apply(t); })
    .catch(function(){});
}
function buzz(){ if(navigator.vibrate) navigator.vibrate(15); }
var flashTimer=null;
function go(dir){
  if(!state) return;
  // 마지막·첫 페이지면 넘길 곳이 없다.
  if(dir>0 ? state.page_number>=state.total_pages : state.page_number<=1) return;
  var f=document.getElementById('flash');
  f.className=dir>0?'r show':'show';
  clearTimeout(flashTimer); flashTimer=setTimeout(function(){ f.className=dir>0?'r':''; },120);
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
  var r={left:b.left+box.clientLeft, top:b.top+box.clientTop, width:box.clientWidth||1, height:box.clientHeight||1};
  g={n:p.length, t0:keep?keep.t0:Date.now(), sx:keep?keep.sx:m.x, sy:keep?keep.sy:m.y,
    moved:keep?keep.moved:false, multi:(keep&&keep.multi)||p.length>1, zoomed:keep?keep.zoomed:false,
    onNote:keep?keep.onNote:!!e.target.closest('#note'),
    r:r, mx:m.x, my:m.y, lx:m.x, ly:m.y, d0:spread(p), z0:{x:zoom.on?zoom.x:0, y:zoom.on?zoom.y:0, size:zoom.on?zoom.size:1}};
}
if(REMOTE){
  // 메모칸 위는 위아래 밀기를 브라우저에 맡긴다(긴 메모 스크롤). 좌우 밀기는 그대로 넘기기.
  function own(e){ if(!e.target.closest('#note')) e.preventDefault(); }
  document.addEventListener('touchstart',function(e){
    if(e.target.closest('#bar,#layout')) return;
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
    }else if(!g.multi && dt<600 && Math.abs(dx)>60 && Math.abs(dx)>1.5*Math.abs(dy)){
      go(dx<0?1:-1);
    }
    g=null;
  }
  document.addEventListener('touchend',end);
  document.addEventListener('touchcancel',function(){ g=null; });
  // 블랙아웃은 잘못 눌러 꺼지지 않게 0.6초 길게 눌러야 한다.
  var black=document.getElementById('black'), holdTimer=null;
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
}
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
setLayout(savedLayout==='row');
</script></body></html>
''';
