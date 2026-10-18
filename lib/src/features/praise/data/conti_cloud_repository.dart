import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/worship_conti.dart';
import 'atomic_file.dart';
import 'sync_snapshot.dart';
import 'worship_conti_repository.dart';

/// 클라우드(공유 폴더)에 올라가 있는 콘티 하나의 정보.
class CloudConti {
  const CloudConti({
    required this.uid,
    required this.name,
    required this.createdAt,
    required this.itemCount,
    required this.uploadedBy,
    required this.uploadedAt,
  });

  final String uid;
  final String name;
  final DateTime createdAt;
  final int itemCount;

  /// 올린 PC 이름.
  final String uploadedBy;
  final DateTime uploadedAt;

  Map<String, Object?> toJson() => {
    'uid': uid,
    'name': name,
    'created_at': createdAt.millisecondsSinceEpoch,
    'item_count': itemCount,
    'uploaded_by': uploadedBy,
    'uploaded_at': uploadedAt.millisecondsSinceEpoch,
  };

  /// 남이 쓴 파일이라 모양이 틀리면 null.
  static CloudConti? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final uid = raw['uid'];
    final name = raw['name'];
    if (uid is! String ||
        !WorshipContiRepository.isValidContiUid(uid) ||
        name is! String) {
      return null;
    }
    DateTime time(Object? v) =>
        DateTime.fromMillisecondsSinceEpoch(v is int ? v : 0);
    return CloudConti(
      uid: uid,
      name: name,
      createdAt: time(raw['created_at']),
      itemCount: raw['item_count'] is int ? raw['item_count'] as int : 0,
      uploadedBy: raw['uploaded_by'] is String
          ? raw['uploaded_by'] as String
          : '',
      uploadedAt: time(raw['uploaded_at']),
    );
  }
}

/// 저장 콘티를 클라우드(공유 폴더)에 **손으로** 올리고 내려받는다. 자동으로 맞추지 않는다.
///
/// 콘티 하나 = `<폴더>/worship_slides_sync/contis/<콘티 uid>.wsconti`(이미지까지 담긴, '파일로
/// 내보내기'와 같은 파일) + 목록용 작은 정보 파일 `<콘티 uid>.json`. 정보 파일을 나중에 쓰므로
/// 목록에 보이면 콘티 파일도 다 쓴 것이다(다른 PC 에서는 드라이브가 아직 내려받는 중일 수 있다).
/// 같은 콘티를 다시 올리면 덮어쓰고, 받은 콘티를 다시 받으면 그 콘티를 바꾼다(uid 가 같다).
class ContiCloudRepository {
  ContiCloudRepository({WorshipContiRepository? contis})
    : _contis = contis ?? WorshipContiRepository();

  static const dirName = 'contis';

  final WorshipContiRepository _contis;

  Directory _dir(String folder) =>
      Directory(p.join(folder, syncDirName, dirName));

  File _contiFile(String folder, String uid) => File(
    p.join(
      _dir(folder).path,
      '$uid.${WorshipContiRepository.contiFileExtension}',
    ),
  );

  File _infoFile(String folder, String uid) =>
      File(p.join(_dir(folder).path, '$uid.json'));

  /// 클라우드의 콘티 목록(올린 시각 늦은 순).
  Future<List<CloudConti>> list(String folder) async {
    final dir = _dir(folder);
    if (!await dir.exists()) return const [];
    final result = <CloudConti>[];
    await for (final entity in dir.list()) {
      if (entity is! File || p.extension(entity.path) != '.json') continue;
      try {
        final info = CloudConti.fromJson(
          jsonDecode(await entity.readAsString()),
        );
        // 정보 파일 이름과 안의 uid 가 다르면 믿지 않는다.
        if (info != null &&
            p.basenameWithoutExtension(entity.path) == info.uid) {
          result.add(info);
        }
      } on FormatException {
        // 드라이브가 아직 내려받는 중이면 다음에 다시 본다.
      } on FileSystemException {
        // 위와 같다.
      }
    }
    result.sort((a, b) => b.uploadedAt.compareTo(a.uploadedAt));
    return result;
  }

  /// 이 PC 의 콘티를 올린다(같은 콘티가 이미 있으면 덮어쓴다).
  Future<void> upload(
    String folder,
    WorshipConti conti, {
    required String deviceName,
  }) async {
    final uid = await _contis.contiUid(conti.id);
    await atomicWrite(
      _contiFile(folder, uid),
      (temp) => _contis.exportContiFile(conti.id, temp.path),
    );
    final info = CloudConti(
      uid: uid,
      name: conti.name,
      createdAt: conti.createdAt,
      itemCount: conti.itemCount,
      uploadedBy: deviceName,
      uploadedAt: DateTime.now(),
    );
    await atomicWriteString(_infoFile(folder, uid), jsonEncode(info.toJson()));
  }

  /// 클라우드 콘티를 이 PC 로 받는다. 이미 받은 콘티면 바꾼다. 반환값은 콘티 id.
  /// 드라이브가 아직 다 내려받지 않았으면 [FileSystemException].
  Future<int> download(String folder, CloudConti conti) async {
    final file = _contiFile(folder, conti.uid);
    if (!await file.exists()) {
      throw const FileSystemException(
        '콘티 파일이 아직 이 PC 로 내려오지 않았습니다. 잠시 뒤에 다시 받아 주세요.',
      );
    }
    try {
      // 정보 파일(= 파일 이름)의 uid 로 넣는다 — 목록에서 고른 그 콘티를 바꾸게.
      return await _contis.importContiFile(file.path, cloudUid: conti.uid);
    } on FormatException {
      throw const FileSystemException(
        '콘티 파일을 다 읽지 못했습니다(아직 내려받는 중일 수 있습니다). 잠시 뒤에 다시 받아 주세요.',
      );
    }
  }

  /// 클라우드에서 지운다(이미 받은 PC 의 콘티는 그대로다).
  Future<void> delete(String folder, CloudConti conti) async {
    // 정보 파일부터 지운다 — 목록에서 먼저 사라져 반쯤 지운 콘티를 받지 않게.
    for (final file in [
      _infoFile(folder, conti.uid),
      _contiFile(folder, conti.uid),
    ]) {
      if (await file.exists()) await file.delete();
    }
  }
}
