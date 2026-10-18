import 'dart:io';

import 'package:path/path.dart' as p;

import 'atomic_file.dart';

/// 동기화 저장소에 있는 파일 하나.
class SyncEntry {
  const SyncEntry({
    required this.name,
    required this.id,
    required this.modified,
    required this.size,
  });

  final String name;

  /// 저장소 안 식별자(폴더면 경로, 드라이브면 파일 id).
  final String id;
  final DateTime modified;
  final int size;

  bool sameVersion(SyncEntry other) =>
      modified == other.modified && size == other.size;
}

/// 찬양 스냅샷·클라우드 콘티를 두는 곳. 폴더 하나에 이름으로 파일을 둔다(하위 폴더 없음).
/// 실패는 모두 [FileSystemException](메시지를 그대로 사용자에게 보인다).
abstract class SyncStore {
  /// 화면에 보일 이름.
  String get label;

  /// 쓸 수 있는지 확인한다. 못 쓰면 던진다.
  Future<void> check();

  Future<List<SyncEntry>> list();

  Future<String> read(SyncEntry entry);

  Future<void> download(SyncEntry entry, File to);

  /// 같은 이름이 있으면 바꾼다. 다른 PC 가 반쯤 쓴 파일을 읽지 않게 한 번에 바꾼다.
  Future<SyncEntry> write(String name, String text);

  Future<SyncEntry> upload(String name, File from);

  /// 그 이름 파일을 모두 지운다(없으면 그냥 둔다).
  Future<void> delete(String name);
}

/// 로컬 폴더 저장소 — 테스트(여러 PC 흉내)용. [dir] 의 부모가 없으면 쓰지 않는다
/// (없는 드라이브에 폴더를 만들어 올린 줄 알게 되지 않게).
class FolderSyncStore implements SyncStore {
  FolderSyncStore(this.dir);

  final String dir;

  @override
  String get label => dir;

  @override
  Future<void> check() async {
    if (!await Directory(p.dirname(dir)).exists()) {
      throw const FileSystemException('공유 폴더를 찾을 수 없습니다.');
    }
    await Directory(dir).create();
  }

  SyncEntry _entry(File file) {
    final stat = file.statSync();
    return SyncEntry(
      name: p.basename(file.path),
      id: file.path,
      modified: stat.modified,
      size: stat.size,
    );
  }

  @override
  Future<List<SyncEntry>> list() async {
    final d = Directory(dir);
    if (!await d.exists()) return const [];
    return [
      for (final f in d.listSync().whereType<File>())
        if (!f.path.endsWith('.tmp')) _entry(f),
    ];
  }

  @override
  Future<String> read(SyncEntry entry) => File(entry.id).readAsString();

  @override
  Future<void> download(SyncEntry entry, File to) async {
    if (!await File(entry.id).exists()) {
      throw const FileSystemException('클라우드에서 파일을 찾지 못했습니다.');
    }
    await File(entry.id).copy(to.path);
  }

  @override
  Future<SyncEntry> write(String name, String text) async {
    final file = File(p.join(dir, name));
    try {
      await atomicWriteString(file, text);
    } on FileSystemException {
      // 다른 프로그램이 파일을 잡고 있어 이름 바꾸기가 막히면 바로 덮어쓴다.
      await file.writeAsString(text, flush: true);
    }
    return _entry(file);
  }

  @override
  Future<SyncEntry> upload(String name, File from) async {
    final file = File(p.join(dir, name));
    await atomicWrite(file, (temp) => from.copy(temp.path));
    return _entry(file);
  }

  @override
  Future<void> delete(String name) async {
    final file = File(p.join(dir, name));
    if (await file.exists()) await file.delete();
  }
}
