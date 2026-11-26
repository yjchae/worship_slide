import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/presenter_pin_store.dart';

void main() {
  test('처음엔 4자리를 만들어 남기고, 다음엔 같은 값을 읽는다', () async {
    final dir = Directory.systemTemp.createTempSync('pin_store');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = PresenterPinStore(directory: dir);
    final first = await store.load();
    expect(PresenterPinStore.isValid(first), isTrue);
    expect(await PresenterPinStore(directory: dir).load(), first);

    await store.save('0042');
    expect(await store.load(), '0042');
    expect(() => store.save('12a4'), throwsArgumentError);
  });

  test('깨진 파일이면 새로 만든다', () async {
    final dir = Directory.systemTemp.createTempSync('pin_store');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/presenter_pin.txt').writeAsStringSync('abcdef');
    final pin = await PresenterPinStore(directory: dir).load();
    expect(PresenterPinStore.isValid(pin), isTrue);
    expect(File('${dir.path}/presenter_pin.txt').readAsStringSync(), pin);
  });

  test('숫자 4자리만 받고, 무작위 값은 앞자리 0 도 4자리', () {
    for (final ok in ['0000', '1234', '9999']) {
      expect(PresenterPinStore.isValid(ok), isTrue);
    }
    for (final bad in ['', '123', '12345', '12a4', ' 123']) {
      expect(PresenterPinStore.isValid(bad), isFalse);
    }
    expect(PresenterPinStore.random(Random(1)).length, 4);
  });
}
