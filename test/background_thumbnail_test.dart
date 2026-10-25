import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/background_image_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('배경 영상 썸네일 만들기가 끝난다(같은 영상 동시 호출·다시 호출 포함)', () async {
    final dir = await Directory.systemTemp.createTemp('thumb_test');
    addTearDown(() => dir.delete(recursive: true));
    final video = '${dir.path}/a.mp4';
    await File(video).writeAsBytes([0]);
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('worship_slides/presentation'),
          (call) async {
            calls++;
            await File(call.arguments['out'] as String).writeAsBytes([1]);
            return true;
          },
        );

    final both = Future.wait([
      BackgroundImageLibrary.thumbnail(video),
      BackgroundImageLibrary.thumbnail(video),
    ]).timeout(const Duration(seconds: 5));
    expect(await both, [
      BackgroundImageLibrary.thumbnailPath(video),
      BackgroundImageLibrary.thumbnailPath(video),
    ]);
    expect(calls, 1);
    // 예전엔 끝나지 않은 작업이 남아 다음 호출도 영영 멈췄다.
    expect(
      await BackgroundImageLibrary.thumbnail(
        video,
      ).timeout(const Duration(seconds: 5)),
      BackgroundImageLibrary.thumbnailPath(video),
    );
  });
}
