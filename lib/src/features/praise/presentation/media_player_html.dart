import 'dart:convert';

import '../domain/slide_media.dart';

/// Windows 발표 창(WebView2)은 미디어 파일 폴더를 이 가상 호스트로 연결한다
/// (`SetVirtualHostNameToFolderMapping`). macOS 는 file:// 로 바로 읽는다.
const kWindowsMediaHost = 'media.worship';

/// 발표 창 미디어 레이어가 띄우는 페이지. 두 플랫폼이 같은 HTML 을 쓰고, 네이티브는
/// 페이지를 띄운 뒤 `fadeOut()`·`toggle()`·`setBlack(on)`·`seek(초)` 만 부른다.
/// 재생 위치는 0.25초마다 `{"t":초,"d":길이,"p":재생 중}` JSON 문자열로 올려 보낸다
/// (macOS `webkit.messageHandlers.media`, Windows `chrome.webview.postMessage`) → 발표 보기 재생바.
///
/// 페이드는 이 안에서 한다 — 동영상은 투명도(+소리), 음악은 소리만. 소리는 0~1 값을
/// 제곱해 넣는다(사람 귀는 선형 볼륨을 끝에서 뚝 끊기듯 듣는다).
String mediaPlayerHtml(SlideMedia media, {required bool windows}) {
  final String? src = switch (media.kind) {
    MediaKind.youtube => null,
    _ when windows =>
      'https://$kWindowsMediaHost/'
          '${Uri.encodeComponent(media.source.split(RegExp(r'[\\/]')).last)}',
    _ => Uri.file(media.source).toString(),
  };
  final config = jsonEncode({
    'kind': media.kind.name,
    'src': src,
    'yt': media.kind == MediaKind.youtube ? youtubeId(media.source) : null,
    'start': media.kind == MediaKind.youtube
        ? youtubeStartSeconds(media.source)
        : 0,
    'fadeIn': media.fadeIn,
    'fadeOut': media.fadeOut,
  }).replaceAll('<', r'\u003c'); // 경로에 </script> 가 있어도 스크립트가 안 끊기게
  return _template.replaceFirst('/*CONFIG*/null', config);
}

const _template = r'''<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent;}
#m,#m iframe{position:absolute;left:0;top:0;width:100%;height:100%;border:0;}
#m{opacity:0;background:#000;object-fit:contain;}
#msg{position:absolute;left:0;right:0;top:45%;text-align:center;color:#ccc;
     font:600 2.4vh sans-serif;display:none;}
</style></head><body>
<div id="host"></div><div id="msg"></div>
<script>
var C=/*CONFIG*/null;
var el=null, yt=null, level=0, timer=null, paused=false, ending=false, black=false, wantIn=false;

function vol(v){
  var g=v*v;
  if(yt&&yt.setVolume) yt.setVolume(Math.round(g*100));
  else if(el&&el.volume!==undefined) el.volume=g;
}
function apply(v){
  level=v;
  if(el&&C.kind!=='audio') el.style.opacity=v;
  vol(v);
}
// 지금 값에서 to 까지 secs 초 동안. 하던 페이드는 지금 값에서 이어받는다(끊김 없음).
function ramp(to,secs,done){
  clearInterval(timer); timer=null;
  if(!(secs>0)){ apply(to); if(done) done(); return; }
  var from=level, t0=Date.now();
  timer=setInterval(function(){
    var k=Math.min(1,(Date.now()-t0)/(secs*1000));
    apply(from+(to-from)*k);
    if(k>=1){ clearInterval(timer); timer=null; if(done) done(); }
  },40);
}
function playing(){
  if(yt) return yt.getPlayerState&&yt.getPlayerState()===1;
  return !!el&&!el.paused&&el.readyState>2;
}
function play(){ paused=false; if(yt) yt.playVideo(); else if(el) el.play().catch(fail); }
function pause(){ paused=true; if(yt) yt.pauseVideo(); else if(el) el.pause(); }
function fail(e){
  var m=document.getElementById('msg');
  m.textContent=typeof e==='string'?e:'미디어를 재생할 수 없습니다';
  m.style.display='block';
}
// 페이드 인은 소리가 실제로 나기 시작할 때부터 센다. 유튜브는 버퍼링에 1~2초 걸려서
// 바로 세면 페이드가 다 지나간 뒤에 소리가 확 들어온다. 이미 재생 중(페이드 아웃 도중)이면 바로.
function fadeIn(){ if(playing()){ paused=false; ramp(1,C.fadeIn); } else { wantIn=true; play(); } }
function started(){ if(wantIn){ wantIn=false; ramp(1,C.fadeIn); } }

// 네이티브가 부르는 것들
window.fadeOut=function(){ ramp(0,C.fadeOut,pause); };
window.toggle=function(){
  if(black) return;
  if(paused||level<0.01){ ending=false; fadeIn(); } else ramp(0,C.fadeOut,pause);
};
window.setBlack=function(on){
  black=on;
  if(on) ramp(0,Math.min(C.fadeOut,1),pause); else fadeIn();
};

// 발표 보기 재생바로 옮긴다. 재생 중이었으면 (끝나기 전 페이드로 줄어들었어도) 다시 올린다.
window.seek=function(t){
  ending=false;
  if(yt){ if(yt.seekTo) yt.seekTo(t,true); }
  else if(el&&C.kind!=='youtube') el.currentTime=t;
  if(!paused&&!black) fadeIn();
  post();
};
function state(){
  if(yt){
    if(!yt.getCurrentTime) return null;
    return {t:yt.getCurrentTime()||0,d:yt.getDuration()||0,p:!paused&&yt.getPlayerState()===1};
  }
  if(!el||C.kind==='youtube') return null;
  return {t:el.currentTime||0,d:isFinite(el.duration)?el.duration:0,p:!paused&&!el.paused};
}
function post(){
  var s=state(); if(!s) return;
  var msg=JSON.stringify(s);
  if(window.webkit&&webkit.messageHandlers&&webkit.messageHandlers.media)
    webkit.messageHandlers.media.postMessage(msg);
  else if(window.chrome&&chrome.webview) chrome.webview.postMessage(msg);
}
setInterval(post,250);

// 끝나기 fadeOut 초 전부터 줄인다. 손으로 멈춘 뒤엔 다시 켤 때까지 건드리지 않는다.
function watchEnd(now,dur){
  if(ending||paused||!(dur>0)||C.fadeOut<=0) return;
  if(now>=dur-C.fadeOut){ ending=true; ramp(0,Math.max(dur-now,0.1)); }
}

if(C.kind==='youtube'){
  if(!C.yt){ fail('유튜브 주소를 읽지 못했습니다'); }
  else {
    var d=document.createElement('div'); d.id='m'; d.innerHTML='<div id="p"></div>';
    document.getElementById('host').appendChild(d); el=d;
    var ready=false;
    setTimeout(function(){ if(!ready) fail('유튜브에 연결하지 못했습니다 (인터넷 연결 확인)'); },10000);
    window.onYouTubeIframeAPIReady=function(){
      yt=new YT.Player('p',{videoId:C.yt,
        playerVars:{autoplay:1,controls:0,disablekb:1,fs:0,rel:0,iv_load_policy:3,
                    playsinline:1,start:C.start,origin:location.origin},
        events:{
          onReady:function(){ ready=true; vol(0); fadeIn(); },
          onStateChange:function(e){ if(e.data===1) started(); },
          onError:function(e){
            ready=true;
            fail(e.data===101||e.data===150||e.data===153
              ?'이 영상은 소유자가 다른 곳에서 재생하지 못하게 막아 두었습니다'
              :'유튜브 영상을 재생할 수 없습니다 ('+e.data+')');
          }
        }});
      setInterval(function(){
        if(yt.getCurrentTime) watchEnd(yt.getCurrentTime(),yt.getDuration());
      },250);
    };
    var s=document.createElement('script');
    s.src='https://www.youtube.com/iframe_api'; s.onerror=function(){ fail('유튜브에 연결하지 못했습니다 (인터넷 연결 확인)'); };
    document.head.appendChild(s);
  }
} else {
  el=document.createElement(C.kind==='audio'?'audio':'video');
  el.id='m'; el.preload='auto'; el.playsInline=true; el.volume=0;
  el.onerror=function(){ fail('미디어 파일을 열지 못했습니다 (파일이 없거나 지원하지 않는 형식)'); };
  el.ontimeupdate=function(){ watchEnd(el.currentTime,el.duration); };
  el.onplaying=started;
  el.src=C.src;
  document.getElementById('host').appendChild(el);
  fadeIn();
}
</script></body></html>''';
