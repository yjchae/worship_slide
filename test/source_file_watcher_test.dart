import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:worship_slides/src/features/praise/data/source_file_watcher.dart';

void main() {
  late Directory dir;
  late File file;
  late List<String> changed;
  late SourceFileWatcher watcher;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('source_watch_');
    file = File(p.join(dir.path, 'notice.pptx'))..writeAsStringSync('v1');
    changed = [];
    // 타이머가 돌지 않도록 아주 긴 간격 — check() 를 직접 부른다.
    watcher = SourceFileWatcher(
      onChanged: changed.add,
      interval: const Duration(hours: 1),
    )..watch(file.path);
  });

  tearDown(() {
    watcher.dispose();
    dir.deleteSync(recursive: true);
  });

  test('바뀌지 않으면 부르지 않는다', () {
    watcher
      ..check()
      ..check();
    expect(changed, isEmpty);
  });

  test('저장이 끝나 같은 값이 한 번 더 나와야 부른다', () {
    file.writeAsStringSync('v2 longer');
    watcher.check();
    expect(changed, isEmpty, reason: '저장 도중일 수 있다');
    watcher.check();
    expect(changed, [file.path]);
    watcher.check();
    expect(changed, [file.path], reason: '같은 저장을 두 번 알리지 않는다');
  });

  test('저장 중 파일이 잠깐 사라져도 넘어가지 않는다', () {
    file.deleteSync();
    watcher
      ..check()
      ..check();
    expect(changed, isEmpty);
    file.writeAsStringSync('v2 saved');
    watcher
      ..check()
      ..check();
    expect(changed, [file.path]);
  });

  test('unwatch 하면 더 보지 않는다', () {
    watcher.unwatch(file.path);
    file.writeAsStringSync('v2 longer');
    watcher
      ..check()
      ..check();
    expect(changed, isEmpty);
    expect(watcher.isWatching(file.path), isFalse);
  });
}
