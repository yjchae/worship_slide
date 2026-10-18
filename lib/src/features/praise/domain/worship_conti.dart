class WorshipConti {
  const WorshipConti({
    required this.id,
    required this.name,
    required this.createdAt,
    this.itemCount = 0,
    this.uid,
  });

  final int id;
  final String name;
  final DateTime createdAt;
  final int itemCount;

  /// 클라우드 파일 이름으로 쓰는 콘티 uid(DB version 17). 예전 행이면 null 일 수 있다.
  final String? uid;

  static WorshipConti fromMap(Map<String, Object?> map, {int itemCount = 0}) {
    return WorshipConti(
      id: map['id'] as int,
      name: map['name'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      itemCount: itemCount,
      uid: map['uid'] as String?,
    );
  }
}

class WorshipContiItem {
  const WorshipContiItem({
    required this.position,
    required this.itemType,
    this.songId,
    this.bibleReference,
    this.bibleText,
  });

  final int position;
  final String itemType; // 'song' | 'bible' | 'blank'
  final int? songId;
  final String? bibleReference;
  final String? bibleText;

  Map<String, Object?> toMap(int contiId) => {
    'conti_id': contiId,
    'position': position,
    'item_type': itemType,
    'song_id': songId,
    'bible_reference': bibleReference,
    'bible_text': bibleText,
  };

  static WorshipContiItem fromMap(Map<String, Object?> map) {
    return WorshipContiItem(
      position: map['position'] as int,
      itemType: map['item_type'] as String,
      songId: map['song_id'] as int?,
      bibleReference: map['bible_reference'] as String?,
      bibleText: map['bible_text'] as String?,
    );
  }
}
