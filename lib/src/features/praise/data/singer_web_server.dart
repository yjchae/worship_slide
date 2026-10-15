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
  String? get publicUrl =>
      _publicBase == null ? null : '$_publicBase/?k=$_token';

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  /// 휴대폰에서 열 주소(토큰 포함).
  String urlFor(String address) => 'http://$address:$port/?k=$_token';

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
    _token = List.generate(
      16,
      (_) => 'abcdefghjkmnpqrstuvwxyz23456789'[rnd.nextInt(31)],
    ).join();
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
      (_) => _broadcast(': ping\n\n'),
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
    for (final c in _clients) {
      c.close().catchError((_) {});
    }
    _clients.clear();
    _lastJson = null;
    _images.clear();
    running.value = false;
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

  /// [SingerViewData.toJson] 을 그대로 받는다. 내용이 같으면 보내지 않는다.
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
    final json = jsonEncode(public);
    if (json == _lastJson) return;
    _lastJson = json;
    _broadcast('data: $json\n\n');
  }

  void _broadcast(String text) {
    for (final c in _clients.toList()) {
      try {
        c.write(text);
      } catch (_) {
        _clients.remove(c);
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
    if (_token.isEmpty || req.uri.queryParameters['k'] != _token) {
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
          res.write(singerPageHtml);
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
          _clients.add(res);
          unawaited(
            res.done
                .catchError((_) {})
                .whenComplete(() => _clients.remove(res)),
          );
          res.write(_lastJson == null ? ': hello\n\n' : 'data: $_lastJson\n\n');
        // 지금 페이지 JSON 한 번. Cloudflare 임시 터널은 SSE 를 붙잡아 두고 안 흘려보내서
        // (trycloudflare 의 알려진 제한) 터널(https) 주소에서는 페이지가 이걸 0.5초마다 묻는다.
        case '/state':
          res.headers
            ..contentType = ContentType.json
            ..set(HttpHeaders.cacheControlHeader, 'no-store');
          res.write(_lastJson ?? '{}');
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
  .box{position:relative;border-radius:1.4vh;overflow:hidden;display:flex;align-items:center;
    justify-content:center;padding:1.6vh 3vw;min-height:0;}
  #current{flex:63;background:#1b2028;border:2px solid #5a6472;}
  #next{flex:37;background:#0f1215;border:1px solid #232930;}
  .fit{width:100%;max-height:100%;text-align:center;line-height:1.3;font-weight:700;}
  .main,.sub{white-space:pre;}
  .wrap .main,.wrap .sub{white-space:pre-wrap;word-break:keep-all;}
  .sub{color:#ffd54f;font-size:.78em;margin-top:.45em;}
  #next .main{color:#c3cad4;}
  #next .sub{color:#b8a25a;}
  .placeholder{color:#59626e;font-size:3vh;font-weight:600;}
  img{max-width:100%;max-height:100%;object-fit:contain;display:block;}
</style></head><body>
  <header><span id="title"></span><span id="badge"></span><span id="page"></span></header>
  <div class="box" id="current"></div>
  <div id="label">다음</div>
  <div class="box" id="next"></div>
<script>
function el(tag, cls, text){ var e=document.createElement(tag); if(cls) e.className=cls;
  if(text!=null) e.textContent=text; return e; }
function fill(box, page, empty){
  box.textContent='';
  if(!page){ box.appendChild(el('div','placeholder',empty)); return; }
  if(page.image_path){ var img=el('img'); img.src=page.image_path; box.appendChild(img); return; }
  if(page.is_blank){ box.appendChild(el('div','placeholder','빈 화면')); return; }
  var f=el('div','fit'); f.appendChild(el('div','main',page.main_text||''));
  if(page.english_text) f.appendChild(el('div','sub',page.english_text));
  box.appendChild(f);
}
function fitAll(){
  document.querySelectorAll('.box').forEach(function(box){
    var e=box.querySelector('.fit'); if(!e) return;
    var cs=getComputedStyle(box);
    var w=box.clientWidth-parseFloat(cs.paddingLeft)-parseFloat(cs.paddingRight);
    var h=box.clientHeight-parseFloat(cs.paddingTop)-parseFloat(cs.paddingBottom);
    function fit(){
      var lo=8, hi=Math.max(12,h*0.45);
      for(var i=0;i<18;i++){ var mid=(lo+hi)/2; e.style.fontSize=mid+'px';
        if(e.scrollHeight<=h+1 && e.scrollWidth<=w+1) lo=mid; else hi=mid; }
      e.style.fontSize=lo+'px'; return lo;
    }
    e.classList.remove('wrap');
    if(fit() < window.innerHeight*0.035){ e.classList.add('wrap'); fit(); }
  });
}
function render(d){
  var cur=d.current||{}, next=d.next;
  document.getElementById('title').textContent=cur.title||'';
  document.getElementById('page').textContent=d.page_number+' / '+d.total_pages;
  var badge=document.getElementById('badge'); badge.textContent=''; badge.className='';
  if(d.blackout){ badge.textContent='관객 화면 꺼짐'; badge.className='badge'; }
  var nt=next&&next.title; document.getElementById('label').textContent=
    (nt && nt!==cur.title) ? '다음 · '+nt : '다음';
  fill(document.getElementById('current'), d.current, '빈 화면');
  fill(document.getElementById('next'), next, '마지막 페이지');
  fitAll();
}
function setBadge(text, cls){
  var b=document.getElementById('badge'); b.textContent=text; b.className=cls;
}
var last='';
function offline(){ last=''; setBadge('연결 끊김','badge off'); }
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
window.addEventListener('resize', fitAll);
// 화면 꺼짐 방지. https(바깥 망 터널 주소)에서만 된다 — 같은 망 http 주소면 조용히 건너뛰고,
// 앱 다이얼로그가 "휴대폰 자동 잠금을 꺼 두라"고 안내한다. 탭이 가려지면 풀리므로 돌아올 때 다시 건다.
function keepAwake(){
  if(navigator.wakeLock && document.visibilityState==='visible')
    navigator.wakeLock.request('screen').catch(function(){});
}
keepAwake();
document.addEventListener('visibilitychange', keepAwake);
</script></body></html>
''';
