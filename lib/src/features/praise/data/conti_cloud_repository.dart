import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/worship_conti.dart';
import 'sync_store.dart';
import 'worship_conti_repository.dart';

/// 클라우드에 올라가 있는 콘티 하나의 정보.
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

/// 저장 콘티를 클라우드에 **손으로** 올리고 내려받는다. 자동으로 맞추지 않는다.
///
/// 콘티 하나 = `conti_<콘티 uid>.wsconti`(이미지까지 담긴, '파일로 내보내기'와 같은 파일) +
/// 목록용 작은 정보 파일 `conti_<콘티 uid>.json`. 찬양 스냅샷과 같은 폴더에 두고 `conti_` 로 가른다.
/// 정보 파일을 나중에 쓰므로 목록에 보이면 콘티 파일도 다 올라간 것이다.
/// 같은 콘티를 다시 올리면 덮어쓰고, 받은 콘티를 다시 받으면 그 콘티를 바꾼다(uid 가 같다).
class ContiCloudRepository {
  ContiCloudRepository({WorshipContiRepository? contis})
    : _contis = contis ?? WorshipContiRepository();

  static const prefix = 'conti_';

  final WorshipContiRepository _contis;

  static String contiName(String uid) =>
      '$prefix$uid.${WorshipContiRepository.contiFileExtension}';

  static String infoName(String uid) => '$prefix$uid.json';

  /// 클라우드의 콘티 목록(올린 시각 늦은 순).
  Future<List<CloudConti>> list(SyncStore store) async {
    FileSystemException? readError;
    var read = 0;
    final infos = await Future.wait([
      for (final entry in await store.list())
        if (entry.name.startsWith(prefix) && entry.name.endsWith('.json'))
          () async {
            try {
              final text = await store.read(entry);
              read += 1;
              final info = CloudConti.fromJson(jsonDecode(text));
              // 정보 파일 이름과 안의 uid 가 다르면 믿지 않는다.
              return info != null && entry.name == infoName(info.uid)
                  ? info
                  : null;
            } on FormatException {
              return null; // 깨진 정보 파일은 건너뛴다.
            } on FileSystemException catch (error) {
              readError ??= error;
              return null; // 목록과 읽기 사이에 지워졌거나 잠깐 끊겼다 — 하나 때문에 목록 전체를 버리지 않는다.
            }
          }(),
    ]);
    // 하나도 못 읽었으면 인터넷이 끊긴 것이다 — 빈 목록("콘티 없음")으로 보이지 않게 오류로 낸다.
    if (readError != null && read == 0) throw readError!;
    final byUid = <String, CloudConti>{};
    for (final info in infos.nonNulls) {
      final seen = byUid[info.uid];
      if (seen == null || info.uploadedAt.isAfter(seen.uploadedAt)) {
        byUid[info.uid] = info;
      }
    }
    return byUid.values.toList()
      ..sort((a, b) => b.uploadedAt.compareTo(a.uploadedAt));
  }

  /// 이 PC 의 콘티를 올린다(같은 콘티가 이미 있으면 덮어쓴다).
  Future<void> upload(
    SyncStore store,
    WorshipConti conti, {
    required String deviceName,
  }) async {
    final uid = await _contis.contiUid(conti.id);
    await _withTemp((temp) async {
      await _contis.exportContiFile(conti.id, temp.path);
      await store.upload(contiName(uid), temp);
    });
    final info = CloudConti(
      uid: uid,
      name: conti.name,
      createdAt: conti.createdAt,
      itemCount: conti.itemCount,
      uploadedBy: deviceName,
      uploadedAt: DateTime.now(),
    );
    await store.write(infoName(uid), jsonEncode(info.toJson()));
  }

  /// 클라우드 콘티를 이 PC 로 받는다. 이미 받은 콘티면 바꾼다. 반환값은 콘티 id.
  /// 콘티 파일이 없으면 [FileSystemException].
  Future<int> download(SyncStore store, CloudConti conti) async {
    final name = contiName(conti.uid);
    final found = (await store.list()).where((e) => e.name == name).toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
    if (found.isEmpty) {
      throw const FileSystemException(
        '클라우드에서 콘티 파일을 찾지 못했습니다. 올린 PC 에서 다시 올려 주세요.',
      );
    }
    return _withTemp((temp) async {
      await store.download(found.first, temp);
      try {
        // 정보 파일(= 파일 이름)의 uid 로 넣는다 — 목록에서 고른 그 콘티를 바꾸게.
        return await _contis.importContiFile(temp.path, cloudUid: conti.uid);
      } on FormatException {
        throw const FileSystemException('콘티 파일을 다 읽지 못했습니다. 잠시 뒤에 다시 받아 주세요.');
      }
    });
  }

  /// 클라우드에서 지운다(이미 받은 PC 의 콘티는 그대로다).
  Future<void> delete(SyncStore store, CloudConti conti) async {
    // 정보 파일부터 지운다 — 목록에서 먼저 사라져 반쯤 지운 콘티를 받지 않게.
    await store.delete(infoName(conti.uid));
    await store.delete(contiName(conti.uid));
  }

  static Future<T> _withTemp<T>(Future<T> Function(File temp) job) async {
    final dir = await Directory.systemTemp.createTemp('ws_cloud_');
    try {
      return await job(
        File(
          p.join(dir.path, 'x.${WorshipContiRepository.contiFileExtension}'),
        ),
      );
    } finally {
      await dir.delete(recursive: true).catchError((_) => dir);
    }
  }
}
