import Cocoa
import FlutterMacOS
import WebKit

// ── 발표 창 ──────────────────────────────────────────────────────────────────

class PresentationWindowController: NSWindowController {
  private var webView: WKWebView!
  private var currentData: [String: Any] = [:]

  convenience init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "발표 화면"
    window.isReleasedWhenClosed = false
    window.backgroundColor = .black

    self.init(window: window)

    let config = WKWebViewConfiguration()
    webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
    webView.autoresizingMask = [.width, .height]
    webView.layer?.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    window.contentView!.addSubview(webView)
  }

  func show(centeredOn screen: NSScreen? = nil) {
    guard let window = self.window else { return }
    if let screen = screen {
      let sf = screen.frame
      let wf = window.frame
      let x = sf.minX + (sf.width - wf.width) / 2
      let y = sf.minY + (sf.height - wf.height) / 2
      window.setFrameOrigin(NSPoint(x: x, y: y))
    } else {
      window.center()
    }
    window.makeKeyAndOrderFront(nil)
  }

  func updatePage(json: String) {
    guard let data = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
      return
    }
    currentData = data
    let html = buildHTML(data: data)
    webView.loadHTMLString(html, baseURL: nil)
  }

  // ── HTML 슬라이드 렌더링 ────────────────────────────────────────────────
  // Flutter _PreviewBox 와 동일한 좌표계를 재현한다.
  // slideW=13.333, slideH=7.5 인치 → fontScale = h/(slideH*72)
  // CSS 에서는 font-size: calc(N / 540 * 100vh) 로 동일하게 스케일링한다.

  private func buildHTML(data: [String: Any]) -> String {
    let mainText = escapeHtml((data["main_text"] as? String) ?? "")
    let englishText = escapeHtml((data["english_text"] as? String) ?? "")
    let titleText = escapeHtml((data["title"] as? String) ?? "")
    let isBible = (data["is_bible"] as? Bool) ?? false
    let style = (data["style"] as? [String: Any]) ?? [:]

    let bgColor = style["background_color"] as? String ?? "#1b1b1b"

    let fontSize = isBible
      ? (style["bible_font_size"] as? Double ?? 30)
      : (style["font_size"] as? Double ?? 30)

    let textColor = isBible
      ? (style["bible_text_color"] as? String ?? "#ffffff")
      : (style["text_color"] as? String ?? "#ffffff")

    let showEnglish = !(style["include_english_lyrics"] as? Bool ?? true) == false
    let englishColor = style["english_text_color"] as? String ?? "#fff176"
    let englishFontSize = (style["font_size"] as? Double ?? 30) * 0.8

    let bodyBoxTop = isBible
      ? (style["bible_text_box_top"] as? Double ?? 0.6)
      : (style["text_box_top"] as? Double ?? 0.6)

    // slideH=7.5, lyricsBoxBottom=1.5 (7.5-0.6-5.4)
    let lyricsBoxBottom = 1.5
    let bodyBoxHeight = 7.5 - bodyBoxTop - lyricsBoxBottom
    let bodyBoxTopPct = bodyBoxTop / 7.5 * 100
    let bodyBoxHeightPct = bodyBoxHeight / 7.5 * 100

    let textPositionKey = isBible ? "bible_text_position" : "text_position"
    let textPositionVal = style[textPositionKey] as? String ?? "middle"
    let justifyContent: String
    switch textPositionVal {
    case "top": justifyContent = "flex-start"
    case "bottom": justifyContent = "flex-end"
    default: justifyContent = "center"
    }

    let textAlignKey = isBible ? "bible_text_align" : "lyrics_text_align"
    let textAlignVal = style[textAlignKey] as? String ?? "center"
    let textAlign: String
    switch textAlignVal {
    case "left": textAlign = "left"
    case "right": textAlign = "right"
    default: textAlign = "center"
    }

    // 제목 표시
    let showTitleKey = isBible ? "show_bible_title" : "show_song_title"
    let showTitle = (style[showTitleKey] as? Bool ?? false) && !titleText.isEmpty

    let titleFontSizeKey = isBible ? "bible_title_font_size" : "title_font_size"
    let titleFontSize = style[titleFontSizeKey] as? Double ?? 14
    let titleColorKey = isBible ? "bible_title_text_color" : "title_text_color"
    let titleColor = style[titleColorKey] as? String ?? "#b3ffffff"

    let titleHPosKey = isBible ? "bible_title_horizontal_position" : "title_horizontal_position"
    let titleHPos = style[titleHPosKey] as? String ?? "right"
    let titleVPosKey = isBible ? "bible_title_vertical_position" : "title_vertical_position"
    let titleVPos = style[titleVPosKey] as? String ?? "bottom"

    let titleHorizCSS: String
    switch titleHPos {
    case "left": titleHorizCSS = "left: 1.5%; text-align: left;"
    case "center": titleHorizCSS = "left: 50%; transform: translateX(-50%); text-align: center;"
    default: titleHorizCSS = "right: 1.5%; text-align: right;"
    }
    let titleVertCSS: String
    switch titleVPos {
    case "top": titleVertCSS = "top: 1.5%;"
    case "middle": titleVertCSS = "top: 50%; transform: translateY(-50%);"
    default: titleVertCSS = "bottom: 1.5%;"
    }
    // center 위치는 transform 두 개 합치기
    let titlePositionCSS: String
    if titleHPos == "center" && titleVPos == "middle" {
      titlePositionCSS = "left: 50%; top: 50%; transform: translate(-50%, -50%); text-align: center;"
    } else if titleHPos == "center" {
      titlePositionCSS = "left: 50%; transform: translateX(-50%); text-align: center; \(titleVertCSS)"
    } else if titleVPos == "middle" {
      titlePositionCSS = "\(titleHorizCSS) top: 50%; transform: translateY(-50%);"
    } else {
      titlePositionCSS = "\(titleHorizCSS) \(titleVertCSS)"
    }

    let englishSection = (showEnglish && !englishText.isEmpty) ? """
      <div class="english-text">\(englishText.replacingOccurrences(of: "\n", with: "<br>"))</div>
    """ : ""

    let titleSection = showTitle ? """
      <div class="title-text" style="position:absolute;\(titlePositionCSS)
        color:\(titleColor);font-size:calc(\(titleFontSize)/540*100vh);
        max-width:96%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
        \(titleText)
      </div>
    """ : ""

    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
      * { margin:0; padding:0; box-sizing:border-box; }
      body {
        width:100vw; height:100vh;
        background:\(bgColor);
        position:relative;
        overflow:hidden;
        font-family:-apple-system, 'Apple SD Gothic Neo', 'Noto Sans KR', sans-serif;
      }
      .body-box {
        position:absolute;
        left:5%; width:90%;
        top:\(String(format:"%.4f", bodyBoxTopPct))%;
        height:\(String(format:"%.4f", bodyBoxHeightPct))%;
        display:flex;
        flex-direction:column;
        justify-content:\(justifyContent);
        align-items:center;
      }
      .main-text {
        color:\(textColor);
        font-size:calc(\(fontSize)/540*100vh);
        font-weight:700;
        line-height:1.25;
        text-align:\(textAlign);
        white-space:pre-wrap;
        width:100%;
      }
      .english-text {
        color:\(englishColor);
        font-size:calc(\(englishFontSize)/540*100vh);
        font-weight:700;
        line-height:1.3;
        text-align:\(textAlign);
        margin-top:0.4em;
        white-space:pre-wrap;
        width:100%;
      }
    </style>
    </head>
    <body>
      <div class="body-box">
        <div class="main-text">\(mainText.replacingOccurrences(of: "\n", with: "<br>"))</div>
        \(englishSection)
      </div>
      \(titleSection)
    </body>
    </html>
    """
  }

  private func escapeHtml(_ text: String) -> String {
    return text
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
    self.minSize = NSSize(width: 1360, height: 900)
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
      guard call.method == "showPptxSavePanel" else {
        result(FlutterMethodNotImplemented)
        return
      }

      let arguments = call.arguments as? [String: Any]
      let panel = NSSavePanel()
      panel.title = arguments?["title"] as? String ?? "Save PPTX"
      panel.nameFieldStringValue = arguments?["fileName"] as? String ?? "worship_slides.pptx"
      panel.allowedFileTypes = ["pptx"]
      panel.allowsOtherFileTypes = false
      panel.isExtensionHidden = false
      panel.canCreateDirectories = true

      let finish: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        if url.pathExtension.lowercased() == "pptx" {
          result(url.path)
          return
        }
        result(url.deletingPathExtension().appendingPathExtension("pptx").path)
      }

      if let window = self {
        panel.beginSheetModal(for: window, completionHandler: finish)
      } else {
        finish(panel.runModal())
      }
    }

    // ── 발표 채널 ─────────────────────────────────────────────────────────
    let messenger = flutterViewController.engine.binaryMessenger

    mainPresentationChannel = FlutterMethodChannel(
      name: "worship_slides/presentation_main",
      binaryMessenger: messenger
    )

    let presentationChannel = FlutterMethodChannel(
      name: "worship_slides/presentation",
      binaryMessenger: messenger
    )

    presentationChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {

      case "openWindow":
        if self.presentationController == nil {
          let ctrl = PresentationWindowController()
          self.presentationController = ctrl

          // 두 번째 스크린이 있으면 거기에 표시
          let screens = NSScreen.screens
          let targetScreen = screens.count > 1 ? screens[1] : nil
          ctrl.show(centeredOn: targetScreen)

          // 창 닫힘 감지
          NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: ctrl.window,
            queue: .main
          ) { [weak self] _ in
            self?.presentationController = nil
            self?.mainPresentationChannel?.invokeMethod("presentationClosed", arguments: nil)
          }
        } else {
          self.presentationController?.window?.makeKeyAndOrderFront(nil)
        }
        if let json = call.arguments as? String {
          self.presentationController?.updatePage(json: json)
        }
        result(nil)

      case "updatePage":
        if let json = call.arguments as? String {
          self.presentationController?.updatePage(json: json)
        }
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
