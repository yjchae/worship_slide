import 'package:flutter/material.dart';

import '../domain/chord_lyrics.dart';
import '../domain/praise_song.dart';
import 'chord_sheet_view.dart';

/// 콘티 항목 조 칩 글: 원래대로면 `G`, 바꿨으면 `G→A`. 원래 조를 모르면 `+2`·`코드`.
String chordKeyChipLabel(PraiseSong song) {
  final from = song.effectiveChordKey;
  final n = song.chordTranspose;
  if (from == null) return n == 0 ? '코드' : (n > 0 ? '+$n' : '$n');
  if (n == 0) return from;
  return '$from→${keyAfter(from, n, accidental: song.chordAccidental)}';
}

/// 콘티 항목 줄의 조 칩 (S5, 중립색 — 바꿨을 때만 굵게) + 어긋난 페이지 수 `코드 확인 N`.
class ChordKeyChip extends StatelessWidget {
  const ChordKeyChip({super.key, required this.song, required this.onTap});

  final PraiseSong song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final changed = song.chordTranspose != 0;
    final hidden = hiddenChordPageCount(song.chordLyrics, song.lyrics);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: '조 바꾸기 (싱어·휴대폰·코드 보기만, 관객 화면은 그대로)',
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: cs.outline),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                chordKeyChipLabel(song),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: changed ? FontWeight.w800 : FontWeight.w500,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        if (hidden > 0) ChordCheckChip(count: hidden),
      ],
    );
  }
}

/// 코드가 가사와 어긋나 숨긴 페이지가 있다는 표시(S7 — 이것만 주황 경고색).
class ChordCheckChip extends StatelessWidget {
  const ChordCheckChip({super.key, this.count});

  /// 숨긴 페이지 수. null 이면 수 없이 '코드 확인'.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message:
          '가사가 바뀌어 코드와 어긋난 페이지${count == null ? '가 있습니다' : ' $count곳은 코드가 숨겨집니다'}. '
          '가사 수정에서 코드 모드로 확인해 주세요.',
      child: Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: cs.tertiaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          count == null ? '코드 확인' : '코드 확인 $count',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: cs.onTertiaryContainer,
          ),
        ),
      ),
    );
  }
}

/// 검색 결과 곡 줄 `코드` 배지(중립). 어긋난 곡은 [ChordCheckChip].
class ChordSongBadge extends StatelessWidget {
  const ChordSongBadge({super.key, required this.song});

  final PraiseSong song;

  @override
  Widget build(BuildContext context) {
    if (!song.hasChords) return const SizedBox.shrink();
    if (!chordsMatchLyrics(song.chordLyrics, song.lyrics)) {
      return const ChordCheckChip();
    }
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '코드',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 조 바꾸기 팝오버 (S5). 바꿀 때마다 [onChanged] 를 부른다(바로 반영 — 닫기만 있다).
class ChordTransposeDialog extends StatefulWidget {
  const ChordTransposeDialog({
    super.key,
    required this.song,
    required this.onChanged,
    this.onEditKey,
  });

  final PraiseSong song;
  final void Function(int transpose, ChordAccidental accidental) onChanged;

  /// '가사 수정에서 정하기' — 원래 조를 추정으로 쓰고 있을 때.
  final VoidCallback? onEditKey;

  @override
  State<ChordTransposeDialog> createState() => _ChordTransposeDialogState();
}

class _ChordTransposeDialogState extends State<ChordTransposeDialog> {
  late int _n = widget.song.chordTranspose;
  late ChordAccidental _acc = widget.song.chordAccidental;

  void _set({int? n, ChordAccidental? acc}) {
    setState(() {
      if (n != null) _n = wrapTranspose(n);
      if (acc != null) _acc = acc;
    });
    widget.onChanged(_n, _acc);
  }

  /// 첫 코드 페이지 첫 코드 줄 미리보기.
  ChordLine? get _previewLine {
    final song = widget.song;
    for (final page in song.pairedPages) {
      if (page.chord.isEmpty) continue;
      final moved = transposeChordText(
        page.chord,
        _n,
        accidental: _acc,
        originalKey: song.effectiveChordKey,
      );
      for (final line in parseChordPage(moved)) {
        if (line.chords.isNotEmpty) return line;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final song = widget.song;
    final from = song.effectiveChordKey;
    final sign = _n > 0 ? '+$_n' : '$_n';
    final now = from == null ? sign : keyAfter(from, _n, accidental: _acc);
    final preview = _previewLine;
    return AlertDialog(
      title: Text(
        '조 바꾸기 · ${song.displayTitle}',
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  from == null
                      ? '원래 조  모름'
                      : '원래 조  $from${song.chordKeyEstimated ? ' (추정)' : ''}',
                ),
                const Spacer(),
                if (song.chordKeyEstimated && widget.onEditKey != null)
                  TextButton(
                    onPressed: widget.onEditKey,
                    child: const Text('가사 수정에서 정하기'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.outlined(
                  tooltip: '반음 내리기',
                  onPressed: () => _set(n: _n - 1),
                  icon: const Icon(Icons.remove_rounded),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 120,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: cs.outline),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _n == 0 ? now : '$now  $sign',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.outlined(
                  tooltip: '반음 올리기',
                  onPressed: () => _set(n: _n + 1),
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
            if (from != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (var d = -5; d <= 6; d++)
                    ChoiceChip(
                      label: Text(keyAfter(from, d, accidental: _acc)),
                      selected: (d - _n) % 12 == 0,
                      visualDensity: VisualDensity.compact,
                      showCheckmark: false,
                      onSelected: (_) => _set(n: d),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('♯/♭ 표기'),
                const SizedBox(width: 10),
                SegmentedButton<ChordAccidental>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: ChordAccidental.auto,
                      label: Text('자동'),
                    ),
                    ButtonSegment(
                      value: ChordAccidental.sharp,
                      label: Text('♯'),
                    ),
                    ButtonSegment(
                      value: ChordAccidental.flat,
                      label: Text('♭'),
                    ),
                  ],
                  selected: {_acc},
                  onSelectionChanged: (s) => _set(acc: s.first),
                ),
              ],
            ),
            if (preview != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 64,
                  width: double.infinity,
                  child: ChordSheetView(
                    lines: [preview],
                    fontSize: 22,
                    fit: BoxFit.scaleDown,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '이 콘티 항목만 바뀝니다. 라이브러리 곡·관객 화면은 그대로입니다.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _n == 0 ? null : () => _set(n: 0),
          child: const Text('원래대로'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
