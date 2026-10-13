import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers
import WebKit

// ── 발표 창 ──────────────────────────────────────────────────────────────────

class PresentationWindowController: NSWindowController, NSWindowDelegate {
  private var webView: WKWebView!
  private var keyMonitor: Any?
  /// 창이 닫힐 때 한 번 호출된다. NotificationCenter 옵저버를 쓰면 창마다 하나씩
  /// 쌓이고(제거를 안 함) 해제된 창 주소로 남아 다음 발표에서 오작동한다.
  var onClose: (() -> Void)?

  convenience init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
      styleMask: [.titled, .resizable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.backgroundColor = .black
    window.collectionBehavior = [.fullScreenAuxiliary]
    self.init(window: window)

    let config = WKWebViewConfiguration()
    config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
    webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
    webView.autoresizingMask = [.width, .height]
    window.contentView!.addSubview(webView)
    window.delegate = self
  }

  func windowWillClose(_ notification: Notification) {
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
    }
    onClose?()
  }

  func show(on screen: NSScreen? = nil) {
    guard let window = self.window else { return }
    if let screen = screen {
      // 보조 모니터: 전체화면
      window.styleMask = [.borderless]
      window.level = .screenSaver
      window.setFrame(screen.frame, display: true)
    } else {
      // 기본 모니터만 있을 때: 1280x720 중앙 창
      window.styleMask = [.titled, .resizable]
      window.level = .normal
      let mainScreen = NSScreen.main ?? NSScreen.screens[0]
      let sw = mainScreen.visibleFrame.width
      let sh = mainScreen.visibleFrame.height
      let x = mainScreen.visibleFrame.minX + (sw - 1280) / 2
      let y = mainScreen.visibleFrame.minY + (sh - 720) / 2
      window.setFrame(NSRect(x: x, y: y, width: 1280, height: 720), display: true)
    }
    window.makeKeyAndOrderFront(nil)

    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      // ESC 는 발표 창이 키 윈도우일 때만 여기서 처리한다.
      // 메인 창(검색창 입력 등)의 ESC 는 Flutter 로 그대로 넘긴다.
      if event.keyCode == 53, event.window === self?.window {
        self?.window?.close()
        return nil
      }
      return event
    }
  }

  private var _isBlackout = false
  private var _lastData: [String: Any]? = nil
  // 발표자 보기에서 보내온 포인터. 슬라이드를 다시 그릴 때도 유지해야 해서 들고 있는다.
  private var _ptrMode = "off"
  private var _ptrX = 0.0
  private var _ptrY = 0.0
  private var _ptrSize = 100.0

  // 발표자 보기에서 지정한 확대 영역(슬라이드 기준 0~1). 슬라이드와 같은 비율이라
  // 크기 하나면 되고, 배율은 1/size 다.
  private var _zoomOn = false
  private var _zoomX = 0.0
  private var _zoomY = 0.0
  private var _zoomSize = 1.0

  func setZoom(on: Bool, x: Double, y: Double, size: Double) {
    _zoomOn = on; _zoomX = x; _zoomY = y; _zoomSize = max(size, 0.01)
    webView.evaluateJavaScript(zoomCall(), completionHandler: nil)
  }

  private func zoomCall() -> String {
    return "window.setZoom&&setZoom(\(_zoomOn),\(_zoomX),\(_zoomY),\(_zoomSize))"
  }

  func setPointer(mode: String, x: Double, y: Double, size: Double) {
    _ptrMode = mode; _ptrX = x; _ptrY = y; _ptrSize = size
    // 마우스가 움직일 때마다 페이지를 다시 로드하면 깜빡이므로 JS 로만 옮긴다.
    let js = "window.setPtr&&setPtr('\(mode)',\(x),\(y),\(size))"
    webView.evaluateJavaScript(js, completionHandler: nil)
  }

  // data: Dart의 SlidePageData.toJson() 결과 ([String:Any])
  func updatePage(data: [String: Any]) {
    _lastData = data
    if _isBlackout { return }
    let html = buildHTML(data: data)
    webView.loadHTMLString(html, baseURL: nil)
  }

  func toggleBlackout() {
    _isBlackout = !_isBlackout
    if _isBlackout {
      let style = (_lastData?["style"] as? [String: Any]) ?? [:]
      let bgColor = style["background_color"] as? String ?? "#1b1b1b"
      let html = """
      <!DOCTYPE html><html><head><meta charset="utf-8">
      <style>*{margin:0;padding:0;}body{width:100vw;height:100vh;background:\(bgColor);}</style>
      </head><body></body></html>
      """
      webView.loadHTMLString(html, baseURL: nil)
    } else {
      if let d = _lastData {
        webView.loadHTMLString(buildHTML(data: d), baseURL: nil)
      }
    }
  }

  // ── HTML 슬라이드 렌더링 ────────────────────────────────────────────────
  // Flutter _PreviewBox 좌표계: slideH=7.5, fontScale = h/(slideH*72) = h/540
  // CSS: font-size: calc(N / 540 * 100vh)

  private var customFontKey = ""
  private var customFontCSS = ""

  private func fontFaceCSS(family: String, files: [[String: Any]]) -> String {
    // 사용자가 추가한 폰트(FontLibrary): Dart 가 파일 경로와 굵기를 같이 보낸다.
    // 배경 이미지처럼 data URI 로 박는다 — WebKit 은 사용자 설치 폰트를 안 보여 줄 수 있다.
    if !files.isEmpty {
      // 페이지마다 HTML 을 새로 굽으므로 인코딩한 CSS 를 한 벌 기억해 둔다.
      // ponytail: 슬라이드 넘길 때마다 수 MB 를 WebKit 이 다시 파싱한다. 느리면 HTML 을 파일로 쓰고 loadFileURL 로.
      let key = family + files.map { ($0["path"] as? String) ?? "" }.joined(separator: "|")
      if key == customFontKey { return customFontCSS }
      customFontKey = key
      customFontCSS = files.compactMap { f -> String? in
        guard let path = f["path"] as? String,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let weight = (f["weight"] as? Int) ?? 400
        let format = path.lowercased().hasSuffix(".otf") ? "opentype" : "truetype"
        return "@font-face{font-family:'\(family)';src:url('data:font/\(format);base64,\(data.base64EncodedString())') format('\(format)');font-weight:\(weight);}\n"
      }.joined()
      return customFontCSS
    }
    let map: [String: [String]] = [
      "Pretendard":    ["Pretendard-Regular.ttf", "Pretendard-Bold.ttf"],
      "NanumGothic":   ["NanumGothic-Regular.ttf", "NanumGothic-Bold.ttf"],
      "NanumMyeongjo": ["NanumMyeongjo-Regular.ttf", "NanumMyeongjo-Bold.ttf"],
    ]
    guard let files = map[family],
          let resourceURL = Bundle.main.resourceURL else { return "" }
    let fontsURL = resourceURL
      .appendingPathComponent("flutter_assets")
      .appendingPathComponent("assets")
      .appendingPathComponent("fonts")
    var css = ""
    let weights = [400, 700]
    for (i, file) in files.enumerated() {
      let fileURL = fontsURL.appendingPathComponent(file)
      css += "@font-face{font-family:'\(family)';src:url('\(fileURL.absoluteString)');font-weight:\(weights[i]);}\n"
    }
    return css
  }

  private func backgroundImageCSS(path: String?) -> String {
    guard let path = path, !path.isEmpty,
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "" }
    let ext = (path as NSString).pathExtension.lowercased()
    let mime = ext == "png" ? "image/png" : "image/jpeg"
    let b64 = data.base64EncodedString()
    return "background-image:url('data:\(mime);base64,\(b64)');background-size:cover;background-position:center;"
  }

  // 외부 PPT에서 구운 페이지 이미지 한 장을 화면에 꽉 채워 보여준다.
  // 관객 화면 포인터 (발표자 보기에서 마우스를 움직이면 여기에 표시된다)
  static let pointerCSS = """
      html{overflow:hidden;}
      /* 슬라이드 내용은 이 안에. body 배경은 캔버스로 전파돼 transform 이 안 먹으므로
         배경 이미지도 여기에 둔다. #ptr 은 이 밖에 있어야 확대해도 커지지 않는다. */
      #stage{position:absolute;left:0;top:0;width:100%;height:100%;
             transform-origin:0 0;overflow:hidden;}
      #ptr{position:absolute;display:none;pointer-events:none;z-index:99;
           transform:translate(-50%,-50%);line-height:1;text-align:center;}
      #ptr.dot{border-radius:50%;
        background:radial-gradient(circle,rgba(255,64,64,.95) 0%,rgba(255,0,0,.55) 45%,rgba(255,0,0,0) 72%);}
  """
  static let pointerHTML = "<div id=\"ptr\"></div>"

  private func pointerScript() -> String {
    return """
    window.__z={on:false,x:0,y:0,s:1};
    // 이미지 슬라이드는 object-fit:contain 이라 창 안에서 레터박스가 생긴다.
    // 슬라이드 좌표(0~1)를 창 좌표(0~1)로 옮기려면 이 사각형이 필요하다.
    function __rect(){
      var img=document.querySelector('#stage img'), r={l:0,t:0,w:1,h:1};
      if(img && img.naturalWidth && img.naturalHeight){
        var cw=window.innerWidth, ch=window.innerHeight;
        var k=Math.min(cw/img.naturalWidth, ch/img.naturalHeight);
        r.w=img.naturalWidth*k/cw; r.h=img.naturalHeight*k/ch;
        r.l=(1-r.w)/2; r.t=(1-r.h)/2;
      }
      return r;
    }
    // 확대 영역을 창 가운데에 비율 그대로 채운다. 확대가 꺼져 있으면 항등 변환.
    function __zoomFit(){
      var r=__rect(), z=window.__z;
      if(!z.on) return {k:1,cx:0.5,cy:0.5};
      var k=Math.min(1/(z.s*r.w), 1/(z.s*r.h));
      return {k:k, cx:r.l+(z.x+z.s/2)*r.w, cy:r.t+(z.y+z.s/2)*r.h};
    }
    window.setZoom=function(on,x,y,size){
      window.__z={on:on,x:x,y:y,s:size};
      var st=document.getElementById('stage');
      if(st){
        if(!on){ st.style.transform='none'; }
        else {
          var f=__zoomFit();
          st.style.transform='translate('+((0.5-f.k*f.cx)*100)+'vw,'
                            +((0.5-f.k*f.cy)*100)+'vh) scale('+f.k+')';
        }
      }
      if(window.__p) setPtr(window.__p[0],window.__p[1],window.__p[2],window.__p[3]);
    };
    window.setPtr=function(mode,x,y,size){
      window.__p=[mode,x,y,size];
      var e=document.getElementById('ptr'); if(!e) return;
      if(mode==='off'){ e.style.display='none'; return; }
      var r=__rect(), f=__zoomFit();
      // 위치만 확대를 따라가고 크기는 그대로 둔다(확대 배율만큼 커지면 화면을 덮는다).
      var px=r.l+x*r.w, py=r.t+y*r.h;
      px=0.5+f.k*(px-f.cx); py=0.5+f.k*(py-f.cy);
      e.className = mode;
      e.style.display='block';
      e.style.left=(px*100)+'%'; e.style.top=(py*100)+'%';
      if(mode==='hand'){
        e.style.width='auto'; e.style.height='auto';
        e.style.fontSize=size+'px'; e.textContent='\u{1F446}';
      } else {
        e.textContent=''; e.style.fontSize='0';
        e.style.width=size+'px'; e.style.height=size+'px';
      }
    };
    setPtr('\(_ptrMode)',\(_ptrX),\(_ptrY),\(_ptrSize));
    \(zoomCall());
    // data: URI 이미지는 이 스크립트가 도는 시점엔 아직 디코딩 전이라 naturalWidth 가 0 이다.
    // 레터박스 계산이 어긋나므로 로드가 끝나면 확대·포인터를 다시 적용한다.
    (function(){
      var im=document.querySelector('#stage img');
      if(im && !im.complete){
        im.addEventListener('load', function(){
          var z=window.__z; setZoom(z.on,z.x,z.y,z.s);
        });
      }
    })();
    """
  }

  // bgImageCSS: 원본 이미지가 슬라이드를 꽉 채우지 못할 때 남는 여백에 깔리는 배경.
  // PPTX 내보내기·미리보기와 같게 보이도록 여기서도 배경 이미지를 깐다.
  private func buildImageHTML(imagePath: String, bgColor: String, bgImageCSS: String) -> String {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
      return """
      <!DOCTYPE html><html><head><meta charset="utf-8">
      <style>*{margin:0;padding:0;}
      body{width:100vw;height:100vh;background:\(bgColor);\(bgImageCSS)}</style>
      </head><body></body></html>
      """
    }
    let ext = (imagePath as NSString).pathExtension.lowercased()
    let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/png"
    let b64 = data.base64EncodedString()
    return """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <style>
      *{margin:0;padding:0;}
      body{width:100vw;height:100vh;background:\(bgColor);overflow:hidden;position:relative;}
      #stage{\(bgImageCSS)}
      img{width:100%;height:100%;object-fit:contain;display:block;}
      \(Self.pointerCSS)
    </style></head><body>
      <div id="stage"><img src="data:\(mime);base64,\(b64)"></div>
      \(Self.pointerHTML)
      <script>\(pointerScript())</script>
    </body></html>
    """
  }

  private func buildHTML(data: [String: Any]) -> String {
    let styleForImage = (data["style"] as? [String: Any]) ?? [:]
    if let imagePath = data["image_path"] as? String, !imagePath.isEmpty {
      return buildImageHTML(
        imagePath: imagePath,
        bgColor: styleForImage["background_color"] as? String ?? "#1b1b1b",
        bgImageCSS: backgroundImageCSS(path: styleForImage["background_image_path"] as? String)
      )
    }

    let mainText = escapeHtml((data["main_text"] as? String) ?? "")
    let englishText = escapeHtml((data["english_text"] as? String) ?? "")
    let titleText = escapeHtml((data["title"] as? String) ?? "")
    let isBible = (data["is_bible"] as? Bool) ?? false
    let style = (data["style"] as? [String: Any]) ?? [:]

    let bgColor = style["background_color"] as? String ?? "#1b1b1b"
    let fontFamily = style["font_family"] as? String ?? "Pretendard"
    let bgImageCSS = backgroundImageCSS(path: style["background_image_path"] as? String)

    let fontSize = isBible
      ? ((style["bible_font_size"] as? Double) ?? 30)
      : ((style["font_size"] as? Double) ?? 30)

    let textColor = isBible
      ? (style["bible_text_color"] as? String ?? "#ffffff")
      : (style["text_color"] as? String ?? "#ffffff")

    let includeEnglish = (style["include_english_lyrics"] as? Bool) ?? true
    let englishColor = style["english_text_color"] as? String ?? "#fff176"
    let englishFontSize = ((style["font_size"] as? Double) ?? 30) * 0.8

    // 본문 상자는 크기가 고정이고, 미세 조정(text_offset_y)이 그 상자를 통째로
    // 위아래로 민다. 미리보기(Dart)·PPTX 와 같은 규칙이다.
    let rawOffsetY = isBible
      ? ((style["bible_text_offset_y"] as? Double) ?? 0)
      : ((style["text_offset_y"] as? Double) ?? 0)
    let bodyOffsetY = rawOffsetY.isNaN ? 0 : min(max(rawOffsetY, -2.0), 2.0)
    let bodyBoxTopPct  = (0.6 + bodyOffsetY) / 7.5 * 100
    let bodyBoxHeightPct = 5.4 / 7.5 * 100

    let textPositionKey = isBible ? "bible_text_position" : "text_position"
    let justifyContent: String
    switch style[textPositionKey] as? String ?? "middle" {
    case "top": justifyContent = "flex-start"
    case "bottom": justifyContent = "flex-end"
    default: justifyContent = "center"
    }

    let textAlignKey = isBible ? "bible_text_align" : "lyrics_text_align"
    let textAlign: String
    switch style[textAlignKey] as? String ?? "center" {
    case "left": textAlign = "left"
    case "right": textAlign = "right"
    default: textAlign = "center"
    }

    let showTitleKey = isBible ? "show_bible_title" : "show_song_title"
    let showTitle = (style[showTitleKey] as? Bool ?? false) && !titleText.isEmpty
    let titleFontSizeKey = isBible ? "bible_title_font_size" : "title_font_size"
    let titleFontSize = (style[titleFontSizeKey] as? Double) ?? 14
    let titleColorKey = isBible ? "bible_title_text_color" : "title_text_color"
    let titleColor = style[titleColorKey] as? String ?? "#b3ffffff"

    let titleHPosKey = isBible ? "bible_title_horizontal_position" : "title_horizontal_position"
    let titleVPosKey = isBible ? "bible_title_vertical_position" : "title_vertical_position"
    let titleHPos = style[titleHPosKey] as? String ?? "right"
    let titleVPos = style[titleVPosKey] as? String ?? "bottom"

    // 제목도 본문과 같다. 기준선(상단/중단/하단)에서 미세 조정만큼 더 민다.
    // 화면 높이 = 슬라이드 7.5인치이므로 인치를 vh 로 바꿔 calc() 에 끼워 넣는다.
    // 부호는 연산자로 내보낸다("+ -3vh" 같은 모양을 피한다).
    let titleOffsetKey = isBible ? "bible_title_offset_y" : "title_offset_y"
    let rawTitleOffsetY = (style[titleOffsetKey] as? Double) ?? 0
    let titleOffsetY = rawTitleOffsetY.isNaN
      ? 0 : min(max(rawTitleOffsetY, -2.0), 2.0)
    let titleOffsetVh = String(format: "%.4fvh", abs(titleOffsetY / 7.5 * 100))
    let down = titleOffsetY >= 0
    // 아래로 밀면 top 은 커지고 bottom 은 작아진다.
    let titleShiftTop = "\(down ? "+" : "-") \(titleOffsetVh)"
    let titleShiftBottom = "\(down ? "-" : "+") \(titleOffsetVh)"

    let titleHorizCSS: String
    switch titleHPos {
    case "left": titleHorizCSS = "left:1.5%;text-align:left;"
    case "center": titleHorizCSS = "left:50%;transform:translateX(-50%);text-align:center;"
    default: titleHorizCSS = "right:1.5%;text-align:right;"
    }
    let titleVertCSS: String
    switch titleVPos {
    case "top": titleVertCSS = "top:calc(1.5% \(titleShiftTop));"
    case "middle":
      titleVertCSS = "top:50%;transform:translateY(calc(-50% \(titleShiftTop)));"
    default: titleVertCSS = "bottom:calc(1.5% \(titleShiftBottom));"
    }

    // 가운데+중단은 transform 이 겹친다(뒤에 오는 쪽이 앞을 덮는다). 한 번에 쓴다.
    let titlePositionCSS: String
    if titleHPos == "center" && titleVPos == "middle" {
      titlePositionCSS = "left:50%;top:50%;text-align:center;"
        + "transform:translate(-50%,calc(-50% \(titleShiftTop)));"
    } else {
      titlePositionCSS = "\(titleHorizCSS)\(titleVertCSS)"
    }

    let englishSection = (includeEnglish && !englishText.isEmpty) ? """
      <div class="english-text">\(englishText.replacingOccurrences(of: "\n", with: "<br>"))</div>
    """ : ""

    let titleSection = showTitle ? """
      <div style="position:absolute;\(titlePositionCSS)
        color:\(titleColor);font-size:calc(\(titleFontSize)/540*100vh);
        max-width:96%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
        \(titleText)
      </div>
    """ : ""

    return """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <style>
      \(fontFaceCSS(family: fontFamily, files: (style["font_files"] as? [[String: Any]]) ?? []))
      *{margin:0;padding:0;box-sizing:border-box;}
      body{width:100vw;height:100vh;background:\(bgColor);position:relative;
           overflow:hidden;font-family:'\(fontFamily)',sans-serif;}
      #stage{\(bgImageCSS)}
      .body-box{position:absolute;left:5%;width:90%;
        top:\(String(format:"%.4f",bodyBoxTopPct))%;
        height:\(String(format:"%.4f",bodyBoxHeightPct))%;
        display:flex;flex-direction:column;
        justify-content:\(justifyContent);align-items:center;overflow:visible;}
      .main-text{color:\(textColor);font-size:calc(\(fontSize)/540*100vh);
        font-weight:700;line-height:1.25;text-align:\(textAlign);
        white-space:pre-wrap;width:100%;}
      .english-text{color:\(englishColor);font-size:calc(\(englishFontSize)/540*100vh);
        font-weight:700;line-height:1.3;text-align:\(textAlign);
        margin-top:0.4em;white-space:pre-wrap;width:100%;}
      \(Self.pointerCSS)
    </style></head><body>
      <div id="stage">
        <div class="body-box">
          <div class="main-text">\(mainText.replacingOccurrences(of: "\n", with: "<br>"))</div>
          \(englishSection)
        </div>
        \(titleSection)
      </div>
      \(Self.pointerHTML)
    <script>
    \(pointerScript())
    requestAnimationFrame(function(){
      var box = document.querySelector('.body-box');
      if (!box) return;
      var boxH = box.offsetHeight;
      var totalH = 0;
      for (var i = 0; i < box.children.length; i++) {
        totalH += box.children[i].offsetHeight;
      }
      if (totalH <= boxH * 1.01) return;
      var scale = boxH / totalH * 0.97;
      box.style.transform = 'scale(' + scale + ')';
      box.style.transformOrigin = '\(justifyContent == "flex-end" ? "bottom" : "top") center';
    });
    </script>
    </body></html>
    """
  }

  private func escapeHtml(_ text: String) -> String { htmlEscape(text) }
}

// ── 싱어 화면 ────────────────────────────────────────────────────────────────
// 관객용 발표 창과 별도로 뜨는 두 번째 창. 싱어가 보기 쉽게 디자인(배경·폰트·위치)은
// 무시하고 "현재 페이지(크게) + 다음 페이지(작게)"를 고정 레이아웃으로 그린다.
// 일반 창으로 열리므로 원하는 모니터로 끌어 놓고 더블클릭(또는 F)으로 전체화면을 켠다.

class SingerWindowController: NSWindowController, NSWindowDelegate {
  private var webView: WKWebView!
  private var keyMonitor: Any?
  private var isFullScreen = false
  private var windowedFrame: NSRect?
  private var lastData: [String: Any] = [:]

  /// 사용자가 창을 닫았을 때 한 번 호출된다.
  var onClose: (() -> Void)?
  /// 싱어 화면에 포커스가 있을 때 누른 넘기기 키("next"/"prev")를 Dart 로 넘긴다.
  var onNavigate: ((String) -> Void)?

  convenience init() {
    let window = SingerWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "싱어 화면"
    window.isReleasedWhenClosed = false
    window.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1)
    window.collectionBehavior = [.fullScreenAuxiliary]
    self.init(window: window)

    // 더블클릭은 페이지 JS 가 알려 준다(WKWebView 는 마우스 이벤트를 내부에서 먼저 먹는다).
    let config = WKWebViewConfiguration()
    config.userContentController.add(
      SingerMessageProxy { [weak self] in self?.toggleFullScreen() }, name: "singer")
    webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
    webView.autoresizingMask = [.width, .height]
    window.contentView!.addSubview(webView)
    window.delegate = self
  }

  func windowWillClose(_ notification: Notification) {
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
    }
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "singer")
    onClose?()
  }

  /// screen 이 있으면 그 모니터 전체화면, 없으면 기준 모니터 가운데 일반 창.
  /// 키 포커스는 가져가지 않는다 — 메인 창에서 넘기기 단축키가 계속 먹어야 한다.
  func show(fullScreenOn screen: NSScreen?, near reference: NSScreen?) {
    guard let window = self.window else { return }
    let base = (reference ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    let w = min(960, base.width), h = min(600, base.height)
    window.setFrame(
      NSRect(x: base.midX - w / 2, y: base.midY - h / 2, width: w, height: h),
      display: true)
    window.orderFrontRegardless()
    if let screen = screen { enterFullScreen(on: screen) }

    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self = self, event.window === self.window else { return event }
      switch event.keyCode {
      case 53:  // ESC: 전체화면이면 풀기만, 아니면 창 닫기
        if self.isFullScreen { self.exitFullScreen() } else { self.window?.close() }
      case 3:   // F
        self.toggleFullScreen()
      case 124, 125, 49, 121:  // → ↓ Space PageDown
        self.onNavigate?("next")
      case 123, 126, 116:      // ← ↑ PageUp
        self.onNavigate?("prev")
      default:
        return event
      }
      return nil
    }
  }

  func toggleFullScreen() {
    if isFullScreen { exitFullScreen() }
    else if let screen = window?.screen ?? NSScreen.main { enterFullScreen(on: screen) }
  }

  private func enterFullScreen(on screen: NSScreen) {
    guard let window = window, !isFullScreen else { return }
    windowedFrame = window.frame
    isFullScreen = true
    window.styleMask = [.borderless]
    window.level = .screenSaver
    window.setFrame(screen.frame, display: true)
  }

  private func exitFullScreen() {
    guard let window = window, isFullScreen else { return }
    isFullScreen = false
    window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
    window.title = "싱어 화면"
    window.level = .normal
    if let frame = windowedFrame { window.setFrame(frame, display: true) }
  }

  func update(data: [String: Any]) {
    lastData = data
    webView.loadHTMLString(buildHTML(), baseURL: nil)
  }

  // ── HTML ──────────────────────────────────────────────────────────────

  private func pageHTML(_ page: [String: Any]?, emptyLabel: String) -> String {
    guard let page = page else {
      return "<div class=\"placeholder\">\(emptyLabel)</div>"
    }
    if let path = page["image_path"] as? String, !path.isEmpty,
       let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
      let ext = (path as NSString).pathExtension.lowercased()
      let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/png"
      return "<img src=\"data:\(mime);base64,\(data.base64EncodedString())\">"
    }
    if (page["is_blank"] as? Bool) ?? false {
      return "<div class=\"placeholder\">빈 화면</div>"
    }
    let main = htmlEscape((page["main_text"] as? String) ?? "")
    let sub = htmlEscape((page["english_text"] as? String) ?? "")
    let subHTML = sub.isEmpty ? "" : "<div class=\"sub\">\(sub)</div>"
    return "<div class=\"fit\"><div class=\"main\">\(main)</div>\(subHTML)</div>"
  }

  private func buildHTML() -> String {
    let current = lastData["current"] as? [String: Any]
    let next = lastData["next"] as? [String: Any]
    let pageNumber = (lastData["page_number"] as? Int) ?? 0
    let totalPages = (lastData["total_pages"] as? Int) ?? 0
    let blackout = (lastData["blackout"] as? Bool) ?? false
    let title = htmlEscape((current?["title"] as? String) ?? "")
    let nextTitle = htmlEscape((next?["title"] as? String) ?? "")
    // 다음 페이지가 다른 곡·말씀이면 그 제목을 같이 알려 준다.
    let nextLabel = (!nextTitle.isEmpty && nextTitle != title) ? "다음 · \(nextTitle)" : "다음"
    let badge = blackout ? "<span class=\"badge\">관객 화면 꺼짐</span>" : ""

    return """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <style>
      *{margin:0;padding:0;box-sizing:border-box;}
      html,body{width:100vw;height:100vh;overflow:hidden;background:#0d0f12;color:#fff;
        font-family:-apple-system,'Apple SD Gothic Neo','Pretendard',sans-serif;}
      body{display:flex;flex-direction:column;padding:2.2vh 2.4vw;gap:1.6vh;}
      header{display:flex;align-items:center;gap:1.2vw;font-size:2.6vh;color:#9aa4b1;flex:none;}
      header .title{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-weight:600;}
      header .page{font-variant-numeric:tabular-nums;font-weight:700;color:#e6e9ee;}
      .badge{background:#e5484d;color:#fff;border-radius:999px;padding:.2em .8em;font-size:2.2vh;font-weight:700;}
      .label{font-size:2.3vh;color:#7d8794;font-weight:600;flex:none;
        white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
      .box{position:relative;border-radius:1.4vh;overflow:hidden;display:flex;
        align-items:center;justify-content:center;padding:2vh 3vw;min-height:0;}
      .current{flex:63;background:#171b21;border:1px solid #2a313b;}
      .next{flex:37;background:#111419;border:1px solid #1f252d;}
      .fit{width:100%;max-height:100%;text-align:center;line-height:1.3;font-weight:700;}
      .main{white-space:pre-wrap;word-break:keep-all;}
      .sub{white-space:pre-wrap;color:#ffd54f;font-size:.78em;margin-top:.45em;}
      .next .main{color:#c3cad4;}
      .next .sub{color:#b8a25a;}
      .placeholder{color:#59626e;font-size:3.4vh;font-weight:600;}
      img{max-width:100%;max-height:100%;object-fit:contain;display:block;}
    </style></head><body>
      <header><span class="title">\(title)</span>\(badge)<span class="page">\(pageNumber) / \(totalPages)</span></header>
      <div class="box current">\(pageHTML(current, emptyLabel: "빈 화면"))</div>
      <div class="label">\(nextLabel)</div>
      <div class="box next">\(pageHTML(next, emptyLabel: "마지막 페이지"))</div>
    <script>
    // 상자에 꼭 맞는 가장 큰 글자 크기를 찾는다(이분 탐색). 창 크기가 바뀌면 다시 맞춘다.
    function fitAll(){
      document.querySelectorAll('.box').forEach(function(box){
        var el=box.querySelector('.fit'); if(!el) return;
        var cs=getComputedStyle(box);
        var w=box.clientWidth-parseFloat(cs.paddingLeft)-parseFloat(cs.paddingRight);
        var h=box.clientHeight-parseFloat(cs.paddingTop)-parseFloat(cs.paddingBottom);
        var lo=8, hi=Math.max(12, h*0.45);
        for(var i=0;i<18;i++){
          var mid=(lo+hi)/2; el.style.fontSize=mid+'px';
          if(el.scrollHeight<=h && el.scrollWidth<=w) lo=mid; else hi=mid;
        }
        el.style.fontSize=lo+'px';
      });
    }
    fitAll(); window.addEventListener('resize', fitAll);
    document.addEventListener('dblclick', function(){
      window.webkit.messageHandlers.singer.postMessage('toggleFullScreen');
    });
    </script>
    </body></html>
    """
  }
}

/// borderless 창은 기본으로 키 윈도우가 못 되어 전체화면에서 ESC·화살표가 안 들어온다.
private class SingerWindow: NSWindow {
  override var canBecomeKey: Bool { true }
}

/// userContentController 는 핸들러를 강하게 잡으므로 컨트롤러를 직접 넣지 않고
/// 클로저만 든 얇은 객체를 넣는다(컨트롤러 ↔ 웹뷰 순환 참조 방지).
private class SingerMessageProxy: NSObject, WKScriptMessageHandler {
  private let onToggle: () -> Void

  init(onToggle: @escaping () -> Void) { self.onToggle = onToggle }

  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    onToggle()
  }
}

private func htmlEscape(_ text: String) -> String {
  text
    .replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
    .replacingOccurrences(of: "\"", with: "&quot;")
}

// ── MainFlutterWindow ─────────────────────────────────────────────────────

class MainFlutterWindow: NSWindow {
  private var presentationController: PresentationWindowController?
  private var singerController: SingerWindowController?
  private var mainPresentationChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // 1180x700 미만에서는 예배 콘티/검색 패널 내부 콘텐츠가 RenderFlex overflow를 일으켜
    // 버튼이 경고 줄무늬에 가려짐 (실측 확인: 1180x560 깨짐, 1180x650 정상).
    self.minSize = NSSize(width: 1180, height: 700)
    if self.frame.size.width < self.minSize.width || self.frame.size.height < self.minSize.height {
      self.setContentSize(self.minSize)
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    // ── 저장 다이얼로그 채널 ──────────────────────────────────────────────
    let savePanelChannel = FlutterMethodChannel(
      name: "worship_slides/save_panel",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    savePanelChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "showPptxSavePanel" else { result(FlutterMethodNotImplemented); return }
      let arguments = call.arguments as? [String: Any]
      let panel = NSSavePanel()
      panel.title = arguments?["title"] as? String ?? "Save PPTX"
      let ext = arguments?["extension"] as? String ?? "pptx"
      panel.nameFieldStringValue = arguments?["fileName"] as? String ?? "worship_slides.\(ext)"
      panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
      panel.allowsOtherFileTypes = false
      panel.isExtensionHidden = false
      panel.canCreateDirectories = true
      let finish: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let url = panel.url else { result(nil); return }
        if url.pathExtension.lowercased() == ext { result(url.path); return }
        result(url.deletingPathExtension().appendingPathExtension(ext).path)
      }
      if let window = self { panel.beginSheetModal(for: window, completionHandler: finish) }
      else { finish(panel.runModal()) }
    }

    // ── 발표 채널 ─────────────────────────────────────────────────────────
    let messenger = flutterViewController.engine.binaryMessenger
    mainPresentationChannel = FlutterMethodChannel(
      name: "worship_slides/presentation_main", binaryMessenger: messenger)

    let presentationChannel = FlutterMethodChannel(
      name: "worship_slides/presentation", binaryMessenger: messenger)

    presentationChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      // Dart 가 Map 으로 보냄 (FlutterStandardMessageCodec)
      let data = call.arguments as? [String: Any]

      switch call.method {
      case "openWindow":
        if self.presentationController == nil {
          let ctrl = PresentationWindowController()
          ctrl.onClose = { [weak self] in
            self?.presentationController = nil
            self?.mainPresentationChannel?.invokeMethod("presentationClosed", arguments: nil)
          }
          self.presentationController = ctrl
          let screens = NSScreen.screens
          ctrl.show(on: screens.count > 1 ? screens[1] : nil)
        } else {
          self.presentationController?.window?.makeKeyAndOrderFront(nil)
        }
        if let d = data { self.presentationController?.updatePage(data: d) }
        result(nil)

      case "updatePage":
        if let d = data { self.presentationController?.updatePage(data: d) }
        result(nil)

      case "zoom":
        if let d = data {
          self.presentationController?.setZoom(
            on: d["on"] as? Bool ?? false,
            x: d["x"] as? Double ?? 0,
            y: d["y"] as? Double ?? 0,
            size: d["size"] as? Double ?? 1)
        }
        result(nil)

      case "pointer":
        if let d = data {
          self.presentationController?.setPointer(
            mode: d["mode"] as? String ?? "off",
            x: d["x"] as? Double ?? 0,
            y: d["y"] as? Double ?? 0,
            size: d["size"] as? Double ?? 100)
        }
        result(nil)

      case "blackout":
        self.presentationController?.toggleBlackout()
        result(nil)

      case "closeWindow":
        self.presentationController?.window?.close()
        self.presentationController = nil
        result(nil)

      case "openSingerWindow":
        if self.singerController == nil {
          let ctrl = SingerWindowController()
          ctrl.onClose = { [weak self] in
            self?.singerController = nil
            self?.mainPresentationChannel?.invokeMethod("singerClosed", arguments: nil)
          }
          ctrl.onNavigate = { [weak self] direction in
            self?.mainPresentationChannel?.invokeMethod("singerKey", arguments: direction)
          }
          self.singerController = ctrl
          // 관객 화면이 screens[1] 을 쓰므로, 모니터가 셋 이상이면 세 번째에 전체화면으로.
          // 아니면 메인 창 옆에 일반 창으로 띄우고 사용자가 원하는 모니터로 옮긴다.
          let screens = NSScreen.screens
          ctrl.show(fullScreenOn: screens.count > 2 ? screens[2] : nil, near: self.screen)
        } else {
          self.singerController?.window?.orderFrontRegardless()
        }
        if let d = data { self.singerController?.update(data: d) }
        result(nil)

      case "updateSinger":
        if let d = data { self.singerController?.update(data: d) }
        result(nil)

      case "closeSingerWindow":
        // close() 가 windowWillClose → onClose 를 부르면 Dart 에 singerClosed 가 한 번
        // 더 가지만, Dart 쪽은 이미 닫힌 상태라 아무 일도 안 한다.
        self.singerController?.window?.close()
        self.singerController = nil
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
