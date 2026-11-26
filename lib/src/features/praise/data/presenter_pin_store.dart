import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'atomic_file.dart';

/// 휴대폰 발표자 모드 PIN(숫자 4자리) → `Application Support/presenter_pin.txt`.
///
/// 처음 읽을 때 없거나 깨져 있으면 무작위로 하나 만들어 남긴다. 앱을 다시 켜도 그대로라
/// 발표자 휴대폰은 한 번 넣으면 다시 묻지 않는다(PC 에서 바꿀 때만 다시 묻는다).
class PresenterPinStore {
  PresenterPinStore({Directory? directory}) : _directory = directory;

  final Directory? _directory; // 테스트용. 없으면 Application Support

  static bool isValid(String pin) => RegExp(r'^\d{4}$').hasMatch(pin);

  static String random([Random? rnd]) =>
      (rnd ?? Random.secure()).nextInt(10000).toString().padLeft(4, '0');

  Future<File> _file() async => File(
    p.join(
      (_directory ?? await getApplicationSupportDirectory()).path,
      'presenter_pin.txt',
    ),
  );

  /// 저장된 PIN. 없으면 새로 만들어 저장하고 돌려준다(저장에 실패해도 이번 실행 동안은 그 값을 쓴다).
  Future<String> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final pin = (await file.readAsString()).trim();
        if (isValid(pin)) return pin;
      }
    } catch (_) {}
    final pin = random();
    await save(pin);
    return pin;
  }

  Future<void> save(String pin) async {
    if (!isValid(pin)) throw ArgumentError.value(pin, 'pin', '숫자 4자리');
    try {
      await atomicWriteString(await _file(), pin);
    } catch (_) {}
  }
}
