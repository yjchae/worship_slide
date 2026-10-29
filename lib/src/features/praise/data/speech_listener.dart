import 'package:flutter/services.dart';

/// OS 내장 음성 인식(macOS Speech, Windows.Media.SpeechRecognition)을 켜고 끈다.
/// 켜 두는 동안 계속 듣고, 말이 끊길 때마다 한 마디씩 [onFinal] 로 준다.
/// 채널 `worship_slides/speech`: Dart → 네이티브 `start {grammar}` / `stop`,
/// 네이티브 → Dart `partial {text}` / `final {text}` / `error {message}`.
class SpeechListener {
  SpeechListener() {
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      final text = args['text'] as String? ?? '';
      switch (call.method) {
        case 'partial':
          onPartial?.call(text);
        case 'final':
          onFinal?.call(text);
        case 'error':
          onError?.call(_describe(args['message'] as String? ?? ''));
      }
    });
  }

  static const _channel = MethodChannel('worship_slides/speech');

  void Function(String text)? onPartial;
  void Function(String text)? onFinal;

  /// 듣기가 멈췄다(권한 거부·장치 없음 등). 다시 켜려면 [start].
  void Function(String message)? onError;

  /// 켰으면 null, 못 켰으면 이유. [grammar] 는 Windows 용 SRGS(macOS 는 무시).
  Future<String?> start({
    required String grammar,
    required List<String> hints,
  }) async {
    try {
      await _channel.invokeMethod('start', {
        'grammar': grammar,
        'hints': hints,
      });
      return null;
    } on PlatformException catch (e) {
      return _describe(e.message ?? e.code);
    } on MissingPluginException {
      return '이 운영체제에서는 음성 인식을 쓸 수 없습니다.';
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } on MissingPluginException {
      // 채널이 없으면 켜진 적도 없다.
    } on PlatformException {
      // 끄다 실패해도 할 수 있는 게 없다.
    }
  }

  /// Windows 채널은 코드만 보낸다(C++ 소스에 한글을 안 쓴다). macOS 는 이미 한글 문장이다.
  static String _describe(String message) => switch (message) {
    'no_korean' =>
      '한국어 음성 인식이 없습니다. 설정 > 시간 및 언어 > 언어 > 한국어 > 언어 옵션에서 '
          "'음성 인식'을 설치해 주세요.",
    'mic_denied' =>
      "마이크 권한이 없습니다. 설정 > 개인 정보 > 마이크에서 '데스크톱 앱이 마이크에 "
          "액세스하도록 허용'을 켜 주세요.",
    'grammar' => '음성 인식 문법을 읽지 못했습니다.',
    'failed' => '음성 인식을 켜지 못했습니다.',
    _ when message.startsWith('stopped') => '음성 인식이 멈췄습니다 ($message)',
    '' => '음성 인식 오류',
    _ => message,
  };
}
