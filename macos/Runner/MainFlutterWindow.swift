import Cocoa
import FlutterMacOS
import WebKit

// ── 발표 창 ──────────────────────────────────────────────────────────────────

class PresentationWindowController: NSWindowController {
  private var webView: WKWebView!
  private var keyMonitor: Any?

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
      if event.keyCode == 53 { // ESC
        self?.window?.close()
        return nil
      }
      return event
    }
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in
      if let monitor = self?.keyMonitor {
        NSEvent.removeMonitor(monitor)
        self?.keyMonitor = nil
      }
    }
  }

  private var _isBlackout = false
  private var _lastData: [String: Any]? = nil

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

  private func fontFaceCSS(family: String) -> String {
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

  private func buildHTML(data: [String: Any]) -> String {
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

    let bodyBoxTop = isBible
      ? ((style["bible_text_box_top"] as? Double) ?? 0.6)
      : ((style["text_box_top"] as? Double) ?? 0.6)
    let lyricsBoxBottom = 1.5
    let bodyBoxHeight = 7.5 - bodyBoxTop - lyricsBoxBottom
    let bodyBoxTopPct  = bodyBoxTop / 7.5 * 100
    let bodyBoxHeightPct = bodyBoxHeight / 7.5 * 100

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

    let titleHorizCSS: String
    switch titleHPos {
    case "left": titleHorizCSS = "left:1.5%;text-align:left;"
    case "center": titleHorizCSS = "left:50%;transform:translateX(-50%);text-align:center;"
    default: titleHorizCSS = "right:1.5%;text-align:right;"
    }
    let titleVertCSS: String
    switch titleVPos {
    case "top": titleVertCSS = "top:1.5%;"
    case "middle": titleVertCSS = "top:50%;transform:translateY(-50%);"
    default: titleVertCSS = "bottom:1.5%;"
    }

    let titlePositionCSS: String
    if titleHPos == "center" && titleVPos == "middle" {
      titlePositionCSS = "left:50%;top:50%;transform:translate(-50%,-50%);text-align:center;"
    } else if titleHPos == "center" {
      titlePositionCSS = "\(titleHorizCSS)\(titleVertCSS)"
    } else if titleVPos == "middle" {
      let h = "top:50%;transform:translateY(-50%);"
      titlePositionCSS = "\(titleHorizCSS)\(h)"
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
      \(fontFaceCSS(family: fontFamily))
      *{margin:0;padding:0;box-sizing:border-box;}
      body{width:100vw;height:100vh;background:\(bgColor);position:relative;
           overflow:hidden;font-family:'\(fontFamily)',sans-serif;\(bgImageCSS)}
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
    </style></head><body>
      <div class="body-box">
        <div class="main-text">\(mainText.replacingOccurrences(of: "\n", with: "<br>"))</div>
        \(englishSection)
      </div>
      \(titleSection)
    <script>
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

  private func escapeHtml(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}

// ── MainFlutterWindow ─────────────────────────────────────────────────────

class MainFlutterWindow: NSWindow {
  private var presentationController: PresentationWindowController?
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
      panel.nameFieldStringValue = arguments?["fileName"] as? String ?? "worship_slides.pptx"
      panel.allowedFileTypes = ["pptx"]
      panel.allowsOtherFileTypes = false
      panel.isExtensionHidden = false
      panel.canCreateDirectories = true
      let finish: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let url = panel.url else { result(nil); return }
        if url.pathExtension.lowercased() == "pptx" { result(url.path); return }
        result(url.deletingPathExtension().appendingPathExtension("pptx").path)
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
          self.presentationController = ctrl
          let screens = NSScreen.screens
          ctrl.show(on: screens.count > 1 ? screens[1] : nil)
          NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: ctrl.window, queue: .main
          ) { [weak self] _ in
            self?.presentationController = nil
            self?.mainPresentationChannel?.invokeMethod("presentationClosed", arguments: nil)
          }
        } else {
          self.presentationController?.window?.makeKeyAndOrderFront(nil)
        }
        if let d = data { self.presentationController?.updatePage(data: d) }
        result(nil)

      case "updatePage":
        if let d = data { self.presentationController?.updatePage(data: d) }
        result(nil)

      case "blackout":
        self.presentationController?.toggleBlackout()
        result(nil)

      case "closeWindow":
        self.presentationController?.window?.close()
        self.presentationController = nil
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
