import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../domain/obs_caption.dart';
import 'app_logger.dart';
import 'fnv_hash.dart';
import 'font_library.dart';
import 'obs_overlay_store.dart';

/// OBS 자막 서버 상태. [portInUse] 면 다른 포트로 몰래 옮기지 않는다 — 주소가 바뀌면
/// OBS 에 넣어 둔 브라우저 소스가 조용히 깨지므로 사용자에게 알리고 설정에서 바꾸게 한다.
enum ObsServerStatus { off, running, portInUse, failed }

/// OBS 페이지가 `@font-face` 로 읽을 글꼴 파일 하나. 앱 내장 3종은 에셋, 무료 글꼴은 파일.
/// 이 PC 글꼴(라이선스)은 내보내지 않고 이름만 쓴다 — 방송 PC 에 같은 글꼴이 있으면 그걸로 그린다.
class ObsFontSource {
  const ObsFontSource({this.asset, this.path, this.weight = 400});
  final String? asset;
  final String? path;
  final int weight;

  String get id => asset ?? path ?? '';
}

// pubspec `fonts:` 와 같은 목록(내장 3종은 디스크에 파일이 없어 에셋으로 읽는다).
const _bundledFontAssets = <String, List<(String, int)>>{
  'Pretendard': [
    ('assets/fonts/Pretendard-Regular.ttf', 400),
    ('assets/fonts/Pretendard-Medium.ttf', 500),
    ('assets/fonts/Pretendard-SemiBold.ttf', 600),
    ('assets/fonts/Pretendard-Bold.ttf', 700),
  ],
  'NanumGothic': [
    ('assets/fonts/NanumGothic-Regular.ttf', 400),
    ('assets/fonts/NanumGothic-Bold.ttf', 700),
  ],
  'NanumMyeongjo': [
    ('assets/fonts/NanumMyeongjo-Regular.ttf', 400),
    ('assets/fonts/NanumMyeongjo-Bold.ttf', 700),
  ],
};

/// [family] 를 OBS 페이지로 보낼 글꼴 파일들. 앱 글꼴이 아니면 빈 목록(이름만 쓴다).
List<ObsFontSource> obsFontSources(String family) {
  final bundled = _bundledFontAssets[family];
  if (bundled != null) {
    return [for (final (a, w) in bundled) ObsFontSource(asset: a, weight: w)];
  }
  return [
    for (final f in FontLibrary.filesFor(family))
      ObsFontSource(
        path: f['path'] as String,
        weight: (f['weight'] as int?) ?? 400,
      ),
  ];
}

/// OBS '브라우저' 소스가 여는 자막 페이지를 주는 작은 HTTP 서버.
///
/// - `GET /obs?k=<키>`         자막 페이지(HTML 하나, 바탕 투명). `&preview=1` 이면 바둑판 바탕 + 상태 글
/// - `GET /obs/events?k=`      Server-Sent Events. 페이지가 바뀔 때마다 자막 JSON 을 민다
/// - `GET /obs/state?k=`       지금 JSON 한 번(SSE 가 안 될 때)
/// - `GET /obs/font/<n>?k=`    지금 디자인 글꼴 파일 n번(앱 글꼴만)
///
/// 휴대폰 싱어 서버([SingerWebServer])와 따로다. 싱어는 발표마다 켜고 끄고 토큰·포트가 바뀌지만,
/// OBS 는 한 번 넣은 주소를 계속 써야 해서 **포트·키 고정, 앱이 켜져 있는 동안 상시**다.
/// 읽기 전용이라 제어 경로가 없고, 로컬 경로·코드·메모·메시지는 싣지 않는다([ObsCaption]).
class ObsOverlayServer {
  HttpServer? _server;
  final _clients = <HttpResponse>{};
  Timer? _ping;
  String _key = '';
  bool _allowLan = false;
  String? _lastJson;
  List<ObsFontSource> _fonts = const [];
  final _fontCache = <String, List<int>>{};
  Future<void> _queue = Future.value();

  final status = ValueNotifier(ObsServerStatus.off);

  /// 지금 붙어 있는 OBS(브라우저) 수. 앱 바 상태 점·설정 창이 듣는다.
  final clients = ValueNotifier(0);

  bool get isRunning => _server != null;
  int? get port => _server?.port;
  bool get allowLan => _allowLan;

  /// 마지막으로 보낸 자막(설정 창 상태 글용).
  ObsHideReason lastReason = ObsHideReason.beforePresent;

  String urlFor(String host, {bool preview = false}) =>
      'http://$host:$port/obs?k=$_key${preview ? '&preview=1' : ''}';

  Future<void> start({
    required int port,
    required String key,
    required bool allowLan,
  }) => _enqueue(() => _start(port, key, allowLan));

  Future<void> stop() => _enqueue(_stop);

  Future<void> _enqueue(Future<void> Function() job) {
    final f = _queue.catchError((_) {}).then((_) => job());
    _queue = f;
    return f;
  }

  Future<void> _start(int port, String key, bool allowLan) async {
    if (_server != null) await _stop();
    _key = key;
    _allowLan = allowLan;
    try {
      // 다른 프로그램이 127.0.0.1 로만 잡고 있어도 0.0.0.0 bind 는 성공한다(macOS) — 그러면
      // 이 PC 의 OBS 는 그 프로그램으로 간다. 127.0.0.1 이 비었는지 먼저 본다.
      await (await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      )).close();
      _server = await HttpServer.bind(
        allowLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
        port,
      );
    } on SocketException catch (error) {
      status.value = ObsServerStatus.portInUse;
      await AppLogger.instance.info('[obs] 포트 $port 사용 중: ${error.message}');
      return;
    } catch (error) {
      status.value = ObsServerStatus.failed;
      await AppLogger.instance.info('[obs] 서버 켜기 실패: $error');
      return;
    }
    _server!.listen(_handle, onError: (_) {});
    // 잠깐 끊긴 것을 알아채게 주기적으로 빈 줄을 보낸다.
    _ping = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _broadcast(': ping\n\n'),
    );
    status.value = ObsServerStatus.running;
    await AppLogger.instance.info(
      '[obs] 서버 켬 — 포트 $port, ${allowLan ? '같은 망 허용' : '이 PC 만'}',
    );
  }

  Future<void> _stop() async {
    _ping?.cancel();
    _ping = null;
    final server = _server;
    _server = null;
    if (server != null) {
      // 마지막 가사가 방송에 남지 않게 끄기 전에 '투명'을 한 번 보낸다.
      _broadcast(
        'data: ${jsonEncode({'caption': const ObsCaption.hidden(ObsHideReason.beforePresent).toJson()})}\n\n',
      );
      await server.close(force: true);
      await AppLogger.instance.info('[obs] 서버 끔');
    }
    for (final c in _clients) {
      c.close().catchError((_) {});
    }
    _clients.clear();
    clients.value = 0;
    _lastJson = null;
    status.value = ObsServerStatus.off;
  }

  /// 디자인 글꼴 파일. 바뀌면 다음 [update] 의 `fonts` 주소도 바뀐다(OBS 가 옛 글꼴을 기억하지 않게).
  void setFonts(List<ObsFontSource> fonts) => _fonts = fonts;

  /// 자막 + 디자인을 보낸다. 같은 내용이면 다시 보내지 않는다.
  void update(ObsCaption caption, ObsOverlayConfig config, String family) {
    lastReason = caption.reason;
    final fontsVersion = fnvHex(
      utf8.encode(_fonts.map((f) => '${f.id}:${f.weight}').join('|')),
    );
    final json = jsonEncode({
      'caption': caption.toJson(),
      'design': {...config.designJson(), 'font_family': family},
      'fonts': [
        for (var i = 0; i < _fonts.length; i++)
          {
            'url': '/obs/font/$i?k=$_key&v=$fontsVersion',
            'weight': _fonts[i].weight,
          },
      ],
    });
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
    clients.value = _clients.length;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    if (req.method != 'GET' || req.uri.queryParameters['k'] != _key) {
      res.statusCode = HttpStatus.forbidden;
      res.headers.contentType = ContentType.text;
      res.write('앱의 OBS 자막 창에 나온 주소로 다시 열어 주세요.');
      await res.close();
      return;
    }
    try {
      final path = req.uri.path;
      if (path == '/obs') {
        res.headers
          ..contentType = ContentType.html
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        res.write(obsOverlayHtml);
        await res.close();
      } else if (path == '/obs/events') {
        res.bufferOutput = false;
        res.headers
          ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
          ..set(HttpHeaders.cacheControlHeader, 'no-cache');
        _clients.add(res);
        clients.value = _clients.length;
        unawaited(
          res.done.catchError((_) {}).whenComplete(() {
            _clients.remove(res);
            clients.value = _clients.length;
          }),
        );
        res.write(_lastJson == null ? ': hello\n\n' : 'data: $_lastJson\n\n');
      } else if (path == '/obs/state') {
        res.headers
          ..contentType = ContentType.json
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        res.write(_lastJson ?? '{}');
        await res.close();
      } else if (path.startsWith('/obs/font/')) {
        final i = int.tryParse(path.substring('/obs/font/'.length));
        final bytes = i == null || i < 0 || i >= _fonts.length
            ? null
            : await _fontBytes(_fonts[i]);
        if (bytes == null) {
          res.statusCode = HttpStatus.notFound;
        } else {
          res.headers
            ..contentType = ContentType('font', 'ttf')
            ..set(HttpHeaders.cacheControlHeader, 'max-age=86400');
          res.add(bytes);
        }
        await res.close();
      } else {
        res.statusCode = HttpStatus.notFound;
        await res.close();
      }
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<List<int>?> _fontBytes(ObsFontSource font) async {
    final cached = _fontCache[font.id];
    if (cached != null) return cached;
    try {
      final List<int> bytes;
      if (font.asset != null) {
        bytes = (await rootBundle.load(font.asset!)).buffer.asUint8List();
      } else {
        bytes = await File(font.path!).readAsBytes();
      }
      return _fontCache[font.id] = bytes;
    } catch (_) {
      return null;
    }
  }
}

/// OBS 자막 페이지. 바탕은 완전 투명이고, 단위는 페이지 높이 1080 기준(창 높이 비율로 바꿔 그린다).
/// 글자는 textContent 로만 넣는다(HTML 주입 없음). 연결이 끊기면 바로 감춘다 —
/// 앱이 꺼졌을 때 마지막 가사가 방송에 멈춰 있지 않게.
const obsOverlayHtml = r'''<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>OBS 자막</title>
<style>
html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:transparent}
body.preview{background-color:#ccc;background-image:linear-gradient(45deg,#999 25%,transparent 25%),linear-gradient(-45deg,#999 25%,transparent 25%),linear-gradient(45deg,transparent 75%,#999 75%),linear-gradient(-45deg,transparent 75%,#999 75%);background-size:40px 40px;background-position:0 0,0 20px,20px -20px,-20px 0}
.layer{position:absolute;left:0;right:0;display:flex;opacity:0;transition:opacity .25s ease}
.layer.on{opacity:1}
.nofade .layer{transition:none}
.box{box-sizing:border-box;max-width:100%}
.line{white-space:pre-wrap;word-break:keep-all;overflow-wrap:break-word;line-height:1.3}
.gap{height:.25em}
#status{position:fixed;top:12px;right:12px;font:600 14px/1.4 sans-serif;color:#fff;background:rgba(0,0,0,.65);padding:6px 10px;border-radius:6px;display:none}
body.preview #status{display:block}
</style></head>
<body>
<div id="a" class="layer"></div><div id="b" class="layer"></div>
<div id="status">연결 중…</div>
<script>
(function(){
var q=new URLSearchParams(location.search),key=q.get('k')||'';
if(q.get('preview')==='1')document.body.classList.add('preview');
var layers=[document.getElementById('a'),document.getElementById('b')],front=0;
var statusEl=document.getElementById('status');
var last=null,lastKey='',fontKey='',connected=false,dropTimer=null;
function rgba(hex,a){var n=parseInt(hex.slice(1),16);return 'rgba('+(n>>16&255)+','+(n>>8&255)+','+(n&255)+','+a+')';}
function shadowCss(d,s){
  var out=[],w=d.outline_width*s;
  if(w>0){var steps=16;for(var i=0;i<steps;i++){var t=i/steps*Math.PI*2;out.push((Math.cos(t)*w).toFixed(2)+'px '+(Math.sin(t)*w).toFixed(2)+'px 0 '+d.outline_color);}}
  if(d.shadow)out.push('0 '+(4*s).toFixed(2)+'px '+(12*s).toFixed(2)+'px rgba(0,0,0,.75)');
  return out.length?out.join(','):'none';
}
function line(text,size,color,weight){
  var el=document.createElement('div');el.className='line';el.textContent=text;
  el.style.fontSize=size+'px';el.style.color=color;el.style.fontWeight=weight;return el;
}
function build(layer,data,k){
  var c=data.caption,d=data.design,s=window.innerHeight/1080*k;
  layer.innerHTML='';
  var full=d.band==='full',anchorTop=d.anchor==='top';
  layer.style.top=anchorTop?(d.offset*window.innerHeight/1080)+'px':'auto';
  layer.style.bottom=anchorTop?'auto':(d.offset*window.innerHeight/1080)+'px';
  var side=d.side_margin*window.innerHeight/1080;
  layer.style.padding=full?'0':'0 '+side+'px';
  layer.style.justifyContent=d.align==='left'?'flex-start':d.align==='right'?'flex-end':'center';
  var box=document.createElement('div');box.className='box';
  box.style.textAlign=d.align;
  box.style.fontFamily='ObsFont,"'+(d.font_family||'').replace(/"/g,'')+'",sans-serif';
  box.style.textShadow=shadowCss(d,s);
  if(d.band!=='none'){
    box.style.background=rgba(d.band_color,d.band_opacity);
    var pad=Math.round(d.font_size*0.35*s);
    box.style.padding=full?(pad+'px '+side+'px'):(pad+'px '+Math.round(pad*1.6)+'px');
    box.style.borderRadius=full?'0':Math.round(10*s)+'px';
  }
  if(full)box.style.width='100%';
  var size=d.font_size*s,weight=d.bold?700:400;
  if(c.heading){box.appendChild(line(c.heading,size*0.6,d.reference_color,600));box.appendChild(document.createElement('div')).className='gap';}
  if(c.main)box.appendChild(line(c.main,size,d.main_color,weight));
  if(c.sub){if(c.main){var g=document.createElement('div');g.className='gap';box.appendChild(g);}box.appendChild(line(c.sub,size*(c.kind==='sermon'?0.6:d.sub_ratio),d.sub_color,weight));}
  if(c.extra){var g2=document.createElement('div');g2.className='gap';box.appendChild(g2);box.appendChild(line(c.extra,size*d.extra_ratio,d.extra_color,weight));}
  layer.appendChild(box);
  return box;
}
// 덩어리가 최대 높이를 넘으면 글자를 같은 비율로 줄인다(잘리는 것보다 작은 게 낫다).
function render(layer,data){
  var limit=data.design.max_height*window.innerHeight,lo=0.2,hi=1,box=build(layer,data,1);
  if(box.offsetHeight<=limit)return;
  for(var i=0;i<8;i++){var mid=(lo+hi)/2;box=build(layer,data,mid);if(box.offsetHeight<=limit)lo=mid;else hi=mid;}
  build(layer,data,lo);
}
function loadFonts(data){
  var key=JSON.stringify(data.fonts||[]);if(key===fontKey||!document.fonts||!window.FontFace)return;
  fontKey=key;
  (data.fonts||[]).forEach(function(f){
    var face=new FontFace('ObsFont','url('+f.url+')',{weight:String(f.weight)});
    face.load().then(function(ff){document.fonts.add(ff);if(last)show(last,true);}).catch(function(){});
  });
}
function show(data,force){
  last=data;
  document.body.classList.toggle('nofade',!data.design||!data.design.fade);
  var c=data.caption||{show:false};
  statusEl.textContent=connected?(c.show?'보이는 중':(c.reason||'숨김')):'앱과 연결 안 됨';
  if(!data.design){layers.forEach(function(l){l.classList.remove('on');});return;}
  loadFonts(data);
  var k=JSON.stringify([c,data.design]);
  if(k===lastKey&&!force)return;
  var same=k===lastKey;lastKey=k;
  if(!c.show){layers.forEach(function(l){l.classList.remove('on');});return;}
  if(same){render(layers[front],data);return;}
  // 두 층을 번갈아 써서 옛 자막이 사라지는 동안 새 자막이 나타난다.
  var next=1-front;render(layers[next],data);
  layers[next].classList.add('on');layers[front].classList.remove('on');front=next;
}
function hideAll(){connected=false;last=last?{caption:{show:false},design:last.design,fonts:last.fonts}:null;lastKey='';layers.forEach(function(l){l.classList.remove('on');});statusEl.textContent='앱과 연결 안 됨';}
function onData(text){try{var data=JSON.parse(text);if(data&&data.caption){connected=true;show(data);}}catch(e){}}
window.addEventListener('resize',function(){if(last)show(last,true);});
function poll(){fetch('/obs/state?k='+encodeURIComponent(key),{cache:'no-store'}).then(function(r){return r.text();}).then(function(t){onData(t);setTimeout(poll,500);}).catch(function(){hideAll();setTimeout(poll,2000);});}
if(!window.EventSource){poll();return;}
var es=new EventSource('/obs/events?k='+encodeURIComponent(key));
es.onmessage=function(e){if(dropTimer){clearTimeout(dropTimer);dropTimer=null;}onData(e.data);};
es.onopen=function(){if(dropTimer){clearTimeout(dropTimer);dropTimer=null;}connected=true;};
// 끊기면(앱 종료·네트워크) 1초 안에 감춘다. EventSource 는 알아서 다시 붙는다.
es.onerror=function(){if(!dropTimer)dropTimer=setTimeout(hideAll,1000);};
})();
</script></body></html>
''';
