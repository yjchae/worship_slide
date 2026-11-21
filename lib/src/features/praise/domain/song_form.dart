import 'dart:convert';

import 'page_format.dart' show pageKey;
import 'praise_song.dart';

/// 곡 송폼(페이지마다 "곡 구성의 어느 부분인가") 순수 함수. 기획 `.claude-office/work/20261121-1510-song-form/`.
///
/// 저장은 곡 단위 JSON 한 칸(`praise_songs.song_form`, 콘티 `worship_conti_items.song_form`):
/// `{"v":1,"pages":[{"k":"<pageKey>","l":["V2","PC"]}]}` — 페이지 번호 순서대로 한 항목씩.
/// 읽을 때 같은 번호 항목의 `k`(원본 글 해시)가 맞아야 보이고, 어긋나면 **숨길 뿐 지우지 않는다**.
/// 관객 화면·통역(B)·PPTX 로는 가지 않는다(`test/song_form_leak_test.dart`).

enum SectionKind {
  intro,
  verse,
  prechorus,
  chorus,
  bridge,
  interlude,
  tag,
  outro,
  custom,
}

/// 종류별 이름 표(한 곳). [numbered] = 번호를 붙일 수 있는 종류.
const kSectionKinds =
    <SectionKind, ({String abbr, String korean, bool numbered})>{
      SectionKind.intro: (abbr: 'Intro', korean: '인트로', numbered: false),
      SectionKind.verse: (abbr: 'V', korean: '벌스', numbered: true),
      SectionKind.prechorus: (abbr: 'PC', korean: '프리코러스', numbered: true),
      SectionKind.chorus: (abbr: 'C', korean: '코러스', numbered: true),
      SectionKind.bridge: (abbr: 'B', korean: '브릿지', numbered: true),
      SectionKind.interlude: (abbr: 'Inst', korean: '간주', numbered: false),
      SectionKind.tag: (abbr: 'Tag', korean: '태그', numbered: false),
      SectionKind.outro: (abbr: 'Outro', korean: '아웃트로', numbered: false),
      SectionKind.custom: (abbr: '', korean: '직접 입력', numbered: false),
    };

const kMaxCustomLabel = 12;
const kMaxLabelNumber = 99;
const _maxLabelsPerPage = 8;
const _maxFormPages = 1000;

/// 라벨 하나. 번호는 [kSectionKinds] 의 numbered 종류만(1..99), 직접 입력은 [custom] 글.
class SectionLabel {
  const SectionLabel._(this.kind, this.num, this.customText);

  /// 종류 라벨. 번호가 안 되는 종류·범위 밖 번호는 번호 없음으로 만든다.
  factory SectionLabel.of(SectionKind kind, {int? num}) {
    if (kind == SectionKind.custom) {
      throw ArgumentError('use SectionLabel.custom');
    }
    final ok =
        kSectionKinds[kind]!.numbered &&
        num != null &&
        num >= 1 &&
        num <= kMaxLabelNumber;
    return SectionLabel._(kind, ok ? num : null, '');
  }

  /// 직접 입력. 앞뒤 공백·쉼표를 정리하고 12자까지만. 빈 값이면 null.
  static SectionLabel? custom(String text) {
    final t = text.replaceAll(',', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return null;
    final cut = String.fromCharCodes(t.runes.take(kMaxCustomLabel)).trim();
    return SectionLabel._(SectionKind.custom, null, cut);
  }

  final SectionKind kind;
  final int? num;

  /// 직접 입력 글(다른 종류는 '').
  final String customText;

  bool get isCustom => kind == SectionKind.custom;

  /// 싱어·배지에 쓰는 약어: `V2`·`PC`·`Intro`. 직접 입력은 그 글.
  String get abbr =>
      isCustom ? customText : '${kSectionKinds[kind]!.abbr}${num ?? ''}';

  /// 툴팁·스크린리더용: `벌스 2`·`프리코러스`. 직접 입력은 그 글.
  String get korean => isCustom
      ? customText
      : '${kSectionKinds[kind]!.korean}${num == null ? '' : ' $num'}';

  /// 저장 글. 직접 입력은 `=글` (약어와 겹치지 않게).
  String get code => isCustom ? '=$customText' : abbr;

  SectionLabel withNum(int? n) =>
      isCustom ? this : SectionLabel.of(kind, num: n);

  /// 저장 글 → 라벨. 모르는 글·잘못된 번호는 null.
  static SectionLabel? parse(Object? code) {
    if (code is! String || code.isEmpty) return null;
    if (code.startsWith('=')) return custom(code.substring(1));
    final m = _codeRe.firstMatch(code);
    if (m == null) return null;
    for (final e in kSectionKinds.entries) {
      if (e.key == SectionKind.custom || e.value.abbr != m.group(1)) continue;
      final n = m.group(2);
      if (n != null && !e.value.numbered) return null;
      final num = n == null ? null : int.parse(n);
      if (num != null && (num < 1 || num > kMaxLabelNumber)) return null;
      return SectionLabel.of(e.key, num: num);
    }
    return null;
  }

  static final _codeRe = RegExp(r'^([A-Za-z]+)(\d{1,2})?$');

  @override
  bool operator ==(Object other) => other is SectionLabel && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => code;
}

/// 새 라벨. 벌스·브릿지는 [existing](곡 안 페이지들의 라벨) 중 그 종류 최대 번호 + 1,
/// 나머지는 번호 없음(코러스는 나중에 편집 메뉴에서 C1·C2).
SectionLabel autoLabel(
  SectionKind kind,
  Iterable<Iterable<SectionLabel>> existing,
) {
  if (kind != SectionKind.verse && kind != SectionKind.bridge) {
    return SectionLabel.of(kind);
  }
  var max = 0;
  for (final labels in existing) {
    for (final l in labels) {
      if (l.kind == kind && (l.num ?? 0) > max) max = l.num!;
    }
  }
  return SectionLabel.of(kind, num: max + 1);
}

/// 페이지 라벨 여러 개 ↔ `LyricsPage.form` 글(`V2,PC`). 같은 라벨은 한 번만.
String labelsToText(Iterable<SectionLabel> labels) {
  final seen = <SectionLabel>{};
  return [
    for (final l in labels)
      if (seen.add(l)) l.code,
  ].take(_maxLabelsPerPage).join(',');
}

List<SectionLabel> labelsFromText(String text) {
  final seen = <SectionLabel>{};
  return [
    for (final c in text.split(','))
      if (SectionLabel.parse(c) case final l?)
        if (seen.add(l)) l,
  ].take(_maxLabelsPerPage).toList();
}

extension SongFormLyricsPage on LyricsPage {
  /// 이 페이지의 송폼 라벨(순서 있음). 없으면 빈 목록.
  List<SectionLabel> get labels => labelsFromText(form);
}

/// 나누기·합치기: 나누면 두 쪽 모두 같은 라벨(복사), 합치면 [a] 뒤에 [b] 를 잇고 중복은 뺀다.
List<SectionLabel> mergeLabels(
  Iterable<SectionLabel> a,
  Iterable<SectionLabel> b,
) => labelsFromText(labelsToText([...a, ...b]));

typedef FormEntry = ({String key, List<SectionLabel> labels});

/// 저장된 송폼. [entries] 는 페이지 번호 순서(라벨 없는 페이지는 빈 목록, 빈 페이지의 키는 '').
class SongForm {
  const SongForm(this.entries);

  final List<FormEntry> entries;

  bool get isEmpty => entries.every((e) => e.labels.isEmpty);

  Map<String, Object?> toJson() {
    var end = entries.length;
    while (end > 0 && entries[end - 1].labels.isEmpty) {
      end--;
    }
    return {
      'v': 1,
      'pages': [
        for (final e in entries.take(end))
          {
            'k': e.key,
            'l': [for (final l in e.labels) l.code],
          },
      ],
    };
  }

  /// DB·파일에 쓸 글. 라벨이 하나도 없으면 null(칸을 비운다).
  static String? encode(SongForm? form) =>
      form == null || form.isEmpty ? null : jsonEncode(form.toJson());

  /// DB·파일의 글(또는 이미 풀린 Map) → 송폼. 깨졌거나 라벨이 없으면 null.
  /// 깨진 항목은 버리지 않고 빈 항목으로 둬 페이지 번호가 어긋나지 않게 한다.
  static SongForm? parse(Object? raw) {
    final entries = _entriesOf(raw);
    if (entries == null) return null;
    final form = SongForm(entries);
    return form.isEmpty ? null : form;
  }

  /// 글이 있는데 읽지 못했나(JSON 깨짐·모양 틀림). 비었거나 라벨 없는 정상 값은 false.
  static bool isBroken(Object? raw) =>
      raw is String && raw.isNotEmpty && _entriesOf(raw) == null;

  static List<FormEntry>? _entriesOf(Object? raw) {
    Object? json = raw;
    if (raw is String) {
      if (raw.isEmpty) return null;
      try {
        json = jsonDecode(raw);
      } on FormatException {
        return null;
      }
    }
    if (json is! Map) return null;
    final pages = json['pages'];
    if (pages is! List) return null;
    return [
      for (final p in pages.take(_maxFormPages))
        if (p is Map && p['k'] is String && p['l'] is List)
          (
            key: p['k'] as String,
            labels: labelsFromText(
              [
                for (final c in p['l'] as List)
                  if (c is String) c,
              ].join(','),
            ),
          )
        else
          (key: '', labels: const <SectionLabel>[]),
    ];
  }

  /// [index] 번 항목의 라벨을 지운다(숨은 라벨 '지우기').
  SongForm clearedAt(int index) => SongForm([
    for (var i = 0; i < entries.length; i++)
      i == index
          ? (key: entries[i].key, labels: const <SectionLabel>[])
          : entries[i],
  ]);

  @override
  bool operator ==(Object other) =>
      other is SongForm && encode(other) == encode(this);

  @override
  int get hashCode => encode(this).hashCode;
}

/// [matchedForm] 결과: 페이지마다 보이는 라벨 + 어긋나서 숨긴 항목(페이지 번호 → 숨긴 라벨).
typedef FormMatch = ({
  List<List<SectionLabel>> labels,
  Map<int, List<SectionLabel>> hidden,
});

/// 원본 가사 페이지들([mainPages])에 송폼을 짝짓는다.
/// 1) 같은 번호 항목의 키가 같으면 그 라벨  2) 아니면 아직 안 쓴 같은 키 항목  3) 아니면 숨김.
/// 같은 번호 항목에 라벨이 있는데 짝이 안 맞고 다른 페이지도 안 가져갔으면 [FormMatch.hidden] 에 담는다.
FormMatch matchedForm(SongForm? form, List<String> mainPages) {
  final none = const <SectionLabel>[];
  final labels = [for (final _ in mainPages) none];
  final hidden = <int, List<SectionLabel>>{};
  if (form == null) return (labels: labels, hidden: hidden);
  final entries = form.entries;
  final keys = [for (final t in mainPages) pageKey(t)];
  final used = <int>{};
  final done = <int>{};
  for (var i = 0; i < keys.length; i++) {
    if (keys[i] != null && i < entries.length && entries[i].key == keys[i]) {
      labels[i] = entries[i].labels;
      used.add(i);
      done.add(i);
    }
  }
  for (var i = 0; i < keys.length; i++) {
    if (done.contains(i) || keys[i] == null) continue;
    for (var j = 0; j < entries.length; j++) {
      if (!used.contains(j) && entries[j].key == keys[i]) {
        labels[i] = entries[j].labels;
        used.add(j);
        break;
      }
    }
  }
  for (var i = 0; i < keys.length && i < entries.length; i++) {
    if (!used.contains(i) && entries[i].labels.isNotEmpty) {
      hidden[i] = entries[i].labels;
    }
  }
  return (labels: labels, hidden: hidden);
}

/// 곡 페이지들의 라벨을 송폼으로 다시 모은다(저장·콘티 스냅샷·나누기). 라벨이 하나도 없으면 null.
/// [previous](지금 저장된 송폼)를 주면, 글이 바뀌어 숨은 항목은 그대로 이어 둔다(되돌리면 다시 보이게).
SongForm? songFormForPages(List<LyricsPage> pages, {SongForm? previous}) {
  final hidden = matchedForm(previous, [
    for (final p in pages) p.korean,
  ]).hidden;
  final entries = <FormEntry>[
    for (var i = 0; i < pages.length; i++)
      if (pages[i].labels.isEmpty && hidden.containsKey(i))
        previous!.entries[i]
      else
        (key: pageKey(pages[i].korean) ?? '', labels: pages[i].labels),
  ];
  final form = SongForm(entries);
  return form.isEmpty ? null : form;
}

typedef FormStep = ({SectionLabel label, int count, int firstPage});

/// 송폼 순서 줄: 페이지 순서대로 라벨을 펼치고 **연속**해서 같은 라벨은 하나로 묶는다(`C ×2`).
/// [firstPage] = 그 항목이 처음 나온 페이지 번호(0부터, 눌러 이동할 곳).
List<FormStep> formOrder(Iterable<Iterable<SectionLabel>> pages) {
  final steps = <FormStep>[];
  var page = 0;
  for (final labels in pages) {
    for (final l in labels) {
      if (steps.isNotEmpty && steps.last.label == l) {
        final s = steps.removeLast();
        steps.add((label: l, count: s.count + 1, firstPage: s.firstPage));
      } else {
        steps.add((label: l, count: 1, firstPage: page));
      }
    }
    page++;
  }
  return steps;
}

/// 순서 줄 글: `Intro·V1·C ×2·V2`. 콘티 목록(구분 `·`)·편집 창(구분 ` · `)이 같은 함수를 쓴다.
String formOrderText(
  Iterable<Iterable<SectionLabel>> pages, {
  String separator = '·',
}) => [
  for (final s in formOrder(pages))
    s.count > 1 ? '${s.label.abbr} ×${s.count}' : s.label.abbr,
].join(separator);
