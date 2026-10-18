import 'dart:io';

import 'praise_database.dart';

/// 임시 파일에 다 쓴 뒤 이름을 바꿔 [target] 에 넣는다. 쓰는 도중 꺼지거나 다른 PC 가
/// 읽어도 반쯤 쓴 파일이 보이지 않게. 임시 이름은 매번 달라서 두 쪽이 같은 파일을
/// 동시에 써도 서로의 임시 파일을 밟지 않는다.
///
/// 이름 바꾸기가 실패하면(Windows 에서 다른 프로그램이 [target] 을 잡고 있는 등)
/// [target] 이 이미 있고 [overwrite] 가 아니면 그대로 둔다 — 같은 이름이면 같은 내용인
/// 파일(헌금송 PNG 캐시)용. 아니면 다시 던진다.
Future<void> atomicWrite(
  File target,
  Future<void> Function(File temp) write, {
  bool overwrite = true,
}) async {
  await target.parent.create(recursive: true);
  final temp = File('${target.path}.${newSongUid()}.tmp');
  try {
    await write(temp);
    await temp.rename(target.path);
  } on FileSystemException {
    await temp.delete().catchError((_) => temp);
    if (overwrite || !await target.exists()) rethrow;
  }
}

Future<void> atomicWriteString(File target, String text) =>
    atomicWrite(target, (temp) => temp.writeAsString(text, flush: true));
