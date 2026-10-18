import 'dart:convert';
import 'dart:io';

import '../domain/export_style.dart';
import '../domain/slide_background.dart';
import 'media_player_html.dart';

/// Windows 발표 창(WebView2)은 가사 PNG 폴더를 이 가상 호스트로 연결한다(`overlay_dir`).
/// macOS 는 file:// 로 바로 읽는다. 네이티브 `media_layer.cpp` 의 kOverlayHost 와 같아야 한다.
const kWindowsOverlayHost = 'overlay.worship';

/// 가사 뒤에서 반복 재생하는 배경 영상(항목 배경의 [SlideBackground.videoPath]).
///
/// 발표 창 미디어 레이어 하나에 "배경 색 → 영상 → 어둡게 → 가사 PNG" 를 겹쳐 띄운다.
/// Windows 는 슬라이드를 GDI 로 부모 창에 그리고 레이어는 그 위 자식 창이라, 가사를 영상
/// 위에 그리려면 가사도 레이어 안에 있어야 한다. 그래서 가사만 투명 PNG 로 구워
/// (`LyricsOverlayRenderer`) 레이어가 맨 위에 얹는다. 두 플랫폼이 같은 방식을 쓴다.
///
/// 페이지를 넘기면 레이어는 그대로 두고(key 가 영상 경로뿐이라 곡을 나눠도·같은 영상 곡이
/// 이어져도 끊기지 않는다) 가사 PNG 만 `setOverlay(url)` 로 바꾼다.
class SlideBackdrop {
  const SlideBackdrop({
    required this.videoPath,
    required this.dim,
    this.overlayPath,
  });

  final String videoPath;

  /// 영상 위에 까는 검정의 불투명도(0~[SlideBackground.maxVideoDim]). 밝은 영상에서 가사가 읽히게.
  final double dim;

  /// 이 페이지 가사만 그린 투명 PNG. 아직 굽지 않았으면(미리보기) null —
  /// null 이면 발표 창에 보내지 않고 평소 슬라이드로 낸다.
  final String? overlayPath;

  static const double fadeIn = 1.0;
  static const double fadeOut = 1.0;

  SlideBackdrop withOverlay(String path) =>
      SlideBackdrop(videoPath: videoPath, dim: dim, overlayPath: path);

  /// 레이어를 그대로 둘지 가리는 값. 페이지·항목과 상관없이 영상·어둡기만 본다.
  String get key => 'backdrop|$videoPath|${dim.toStringAsFixed(2)}';

  /// 가사 PNG 를 레이어 페이지가 읽을 주소로.
  static String overlayUrl(String path, {required bool windows}) => windows
      ? 'https://$kWindowsOverlayHost/'
            '${Uri.encodeComponent(path.split(RegExp(r'[\\/]')).last)}'
      : Uri.file(path).toString();

  /// 발표 창에 보내는 `media` 칸. 네이티브는 다른 미디어와 똑같이 다루고, key 가 같으면
  /// `overlay_js` 가 바뀌었을 때만 그걸 실행한다.
  Map<String, dynamic> toPageJson(ExportStyle style, {required bool windows}) {
    final url = overlayUrl(overlayPath!, windows: windows);
    return {
      'kind': 'video',
      'source': videoPath,
      'fade_in': fadeIn,
      'fade_out': fadeOut,
      'key': key,
      'backdrop': true,
      'overlay_dir': File(overlayPath!).parent.path,
      'overlay_js': 'window.setOverlay&&setOverlay(${_js(url)})',
      'html': backdropPlayerHtml(
        videoPath: videoPath,
        overlayUrl: url,
        color: colorToHex(style.backgroundColor),
        dim: dim,
        windows: windows,
      ),
    };
  }
}

// </script> 가 경로에 있어도 스크립트가 안 끊기게.
String _js(String value) => jsonEncode(value).replaceAll('<', r'<');

/// 배경 영상 레이어 페이지. 네이티브가 부르는 것은 [mediaPlayerHtml] 과 같다 —
/// `fadeOut()`(다른 미디어로 바뀜)·`setBlack(on)`·`toggle()`, 그리고 `setOverlay(url)`.
/// 소리는 늘 끄고 반복한다. 재생 위치는 보내지 않는다(발표 보기 재생바가 안 뜬다).
String backdropPlayerHtml({
  required String videoPath,
  required String overlayUrl,
  required String color,
  required double dim,
  required bool windows,
}) {
  final src = windows
      ? 'https://$kWindowsMediaHost/'
            '${Uri.encodeComponent(videoPath.split(RegExp(r'[\\/]')).last)}'
      : Uri.file(videoPath).toString();
  final config = _js(
    jsonEncode({
      'src': src,
      'overlay': overlayUrl,
      'color': color,
      'dim': dim.clamp(0, SlideBackground.maxVideoDim),
      'fadeIn': SlideBackdrop.fadeIn,
      'fadeOut': SlideBackdrop.fadeOut,
    }),
  );
  return _backdropTemplate.replaceFirst('/*CONFIG*/null', 'JSON.parse($config)');
}

const _backdropTemplate = r'''<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent;}
#root,#v,#dim,#t{position:absolute;left:0;top:0;width:100%;height:100%;}
#v{object-fit:cover;opacity:0;}
#dim{background:#000;}
/* 가사 PNG 는 16:9 로 굽는다. 화면 비율이 달라도 글자가 찌그러지지 않게 contain. */
#t{object-fit:contain;}
</style></head><body>
<div id="root"><video id="v" muted loop playsinline preload="auto"></video><div id="dim"></div><img id="t" alt=""></div>
<script>
var C=/*CONFIG*/null;
var root=document.getElementById('root'), v=document.getElementById('v'), t=document.getElementById('t');
root.style.background=C.color;
document.getElementById('dim').style.opacity=C.dim;
var timers={};
// el 의 투명도를 지금 값에서 to 까지 secs 초 동안. 같은 el 에 하던 페이드는 이어받는다.
function ramp(el,to,secs,done){
  var id=el.id; clearInterval(timers[id]);
  var from=parseFloat(el.style.opacity||'1'), t0=Date.now();
  if(!(secs>0)){ el.style.opacity=to; if(done) done(); return; }
  timers[id]=setInterval(function(){
    var k=Math.min(1,(Date.now()-t0)/(secs*1000));
    el.style.opacity=from+(to-from)*k;
    if(k>=1){ clearInterval(timers[id]); if(done) done(); }
  },40);
}
var black=false, paused=false;
// 다음 가사는 다 읽은 뒤에 바꾼다 — 바꾸는 사이 빈 화면이 깜빡이지 않게. 늦게 온 옛 요청은 버린다.
var want='';
window.setOverlay=function(url){
  want=url;
  var img=new Image();
  img.onload=function(){ if(want===url) t.src=url; };
  img.onerror=function(){ if(want===url) t.removeAttribute('src'); };
  img.src=url;
};
v.onplaying=function(){ if(!black) ramp(v,1,C.fadeIn); };
v.onerror=function(){ v.style.display='none'; }; // 영상을 못 열면 색 + 가사만
window.fadeOut=function(){ ramp(root,0,C.fadeOut,function(){ v.pause(); }); };
window.setBlack=function(on){
  black=on;
  if(on) ramp(root,0,0.4,function(){ if(black) v.pause(); });
  else { if(!paused) v.play().catch(function(){}); ramp(root,1,0.4); }
};
// 발표 보기 미디어 버튼(이 페이지엔 안 뜨지만 단축키 등으로 오면): 영상만 멈추고 다시.
window.toggle=function(){
  if(black) return;
  paused=!paused;
  if(paused) v.pause(); else v.play().catch(function(){});
};
window.seek=function(){};
t.src=C.overlay; want=C.overlay;
v.src=C.src;
v.play().catch(function(){});
</script></body></html>''';
