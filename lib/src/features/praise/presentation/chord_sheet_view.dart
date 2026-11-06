import 'package:flutter/material.dart';

import '../domain/chord_lyrics.dart';
import '../domain/praise_song.dart';

/// 코드 악보 색·크기 (기획 §3-11 — 휴대폰 HTML·macOS 싱어 HTML 과 같은 값).
const chordColor = Color(0xFFFFA94D);
const chordColorDim = Color(0xFFB07A40);
const chordSubColor = Color(0xFFFFD54F);
const chordSubColorDim = Color(0xFFB8A25A);

/// 조 배지(중립색). 주황 경고색과 헷갈리지 않게 회색이다.
const chordKeyBadgeColor = Color(0xFF8B95A2);

/// 코드 글자 = 가사 글자 × 0.55, 코드 줄 높이 = 코드 글자 × 1.15, 코드 뒤 최소 틈 = 코드 글자 × 0.4.
const chordFontRatio = 0.55;
const chordLineHeight = 1.15;
const chordGapRatio = 0.4;

/// 코드 줄 한 줄을 그릴 조각. [chord] 는 그 조각 첫 글자 위 코드(같은 자리 여럿이면 공백으로 이음),
/// null 이면 코드 없는 조각. [offset] = 줄 안 시작 위치(UTF-16).
typedef ChordPiece = ({int offset, String text, String? chord});

/// 줄을 코드 자리에서 조각으로 자른다. 렌더러 셋이 같은 규칙이다 — 조각 폭 = max(가사 폭, 코드 폭 + 틈).
/// 코드만 있는 줄은 글 없는 조각 하나, 줄 끝 코드는 글 없는 마지막 조각이 된다.
List<ChordPiece> chordPieces(ChordLine line) {
  final text = line.text;
  final at = <int, List<String>>{};
  for (final c in line.chords) {
    at.putIfAbsent(c.offset.clamp(0, text.length), () => []).add(c.name);
  }
  if (at.isEmpty) return [(offset: 0, text: text, chord: null)];
  final offsets = at.keys.toList()..sort();
  final pieces = <ChordPiece>[
    if (offsets.first > 0)
      (offset: 0, text: text.substring(0, offsets.first), chord: null),
  ];
  for (var i = 0; i < offsets.length; i++) {
    final start = offsets[i];
    final end = i + 1 < offsets.length ? offsets[i + 1] : text.length;
    pieces.add((
      offset: start,
      text: text.substring(start, end),
      chord: at[start]!.join(' '),
    ));
  }
  return pieces;
}

/// 싱어·발표 보기 머리줄 조 배지 글. 코드 없는 곡이거나 조가 그대로면 ''.
String chordKeyLabelOf(PraiseSong? song) {
  if (song == null || !song.hasChords) return '';
  return keyLabel(
    originalKey: song.effectiveChordKey,
    estimated: song.chordKeyEstimated,
    semitones: song.chordTranspose,
    accidental: song.chordAccidental,
  );
}

/// 코드 악보 한 페이지: 원본 줄마다 위에 코드 줄, 그 아래 보조 덩어리. 어두운 바탕에 상자에 맞춰
/// 크게 그린다(가장 긴 줄의 폭과 코드 줄까지 든 높이가 들어가는 크기 — FittedBox).
///
/// 관객 화면(SlideRenderView)과 따로 만든 위젯이다. 관객 미리보기·썸네일·PNG 굽기는 이걸 안 쓴다.
/// [onTapChar] 를 주면(가사 수정 창 미리보기) 글자마다 눌러 그 글자 위에 코드를 넣는다.
class ChordSheetView extends StatelessWidget {
  const ChordSheetView({
    super.key,
    required this.lines,
    this.subTexts = const [],
    this.dim = false,
    this.fontSize = 40,
    this.fit = BoxFit.contain,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
    this.background = const Color(0xFF1B2028),
    this.onTapChar,
  });

  final List<ChordLine> lines;

  /// 보조·추가 보조 가사(빈 글은 건너뛴다).
  final List<String> subTexts;

  /// 다음 페이지처럼 흐리게.
  final bool dim;

  /// 맞추기 전 기준 크기. [fit] 이 키우거나 줄인다.
  final double fontSize;
  final BoxFit fit;
  final EdgeInsets padding;
  final Color background;

  /// (줄 번호, 그 줄 strip 글 안 위치) — 코드만 있는 줄은 위치 0.
  final void Function(int line, int offset)? onTapChar;

  @override
  Widget build(BuildContext context) {
    final lyricColor = dim ? const Color(0xFFC3CAD4) : Colors.white;
    final lyric = TextStyle(
      fontSize: fontSize,
      height: 1.3,
      fontWeight: FontWeight.w700,
      color: lyricColor,
    );
    final chord = TextStyle(
      fontSize: fontSize * chordFontRatio,
      height: chordLineHeight,
      fontWeight: FontWeight.w700,
      color: dim ? chordColorDim : chordColor,
    );
    final subs = [
      for (final t in subTexts)
        if (t.trim().isNotEmpty) t.trim(),
    ];
    return Container(
      color: background,
      padding: padding,
      alignment: Alignment.center,
      child: FittedBox(
        fit: fit,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < lines.length; i++)
              onTapChar == null
                  ? _line(lines[i], lyric, chord)
                  : _tapLine(i, lines[i], lyric, chord),
            for (final sub in subs)
              Padding(
                padding: EdgeInsets.only(top: fontSize * 0.78 * 0.45),
                child: Text(
                  sub,
                  textAlign: TextAlign.center,
                  softWrap: false,
                  style: lyric.copyWith(
                    fontSize: fontSize * 0.78,
                    color: dim ? chordSubColorDim : chordSubColor,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _line(ChordLine line, TextStyle lyric, TextStyle chord) {
    if (line.chords.isEmpty) {
      return Text(line.text, softWrap: false, style: lyric);
    }
    if (line.text.isEmpty) {
      return Text(
        line.chords.map((c) => c.name).join('  '),
        softWrap: false,
        style: chord,
      );
    }
    final gap = chord.fontSize! * chordGapRatio;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final p in chordPieces(line))
          p.chord == null
              ? Text(p.text, softWrap: false, style: lyric)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(right: gap),
                      child: Text(p.chord!, softWrap: false, style: chord),
                    ),
                    Text(p.text, softWrap: false, style: lyric),
                  ],
                ),
      ],
    );
  }

  /// 글자마다 칸을 둔 줄(편집 창). 코드 칸 높이는 늘 둬서 코드 없는 줄에도 넣을 수 있다.
  Widget _tapLine(int index, ChordLine line, TextStyle lyric, TextStyle chord) {
    final at = <int, List<String>>{};
    for (final c in line.chords) {
      at.putIfAbsent(c.offset.clamp(0, line.text.length), () => []).add(c.name);
    }
    final cells = <Widget>[
      for (var o = 0; o < line.text.length; o++)
        _CharCell(
          chord: at[o]?.join(' '),
          text: line.text[o],
          lyric: lyric,
          chordStyle: chord,
          onTap: () => onTapChar!(index, o),
        ),
      // 줄 끝 자리(마지막 글자 오른쪽). 코드만 있는 줄은 이 칸 하나뿐이다.
      _CharCell(
        chord: at[line.text.length]?.join(' '),
        text: line.text.isEmpty ? '  ' : ' ',
        lyric: lyric,
        chordStyle: chord,
        onTap: () => onTapChar!(index, line.text.length),
      ),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: cells,
    );
  }
}

class _CharCell extends StatefulWidget {
  const _CharCell({
    required this.chord,
    required this.text,
    required this.lyric,
    required this.chordStyle,
    required this.onTap,
  });

  final String? chord;
  final String text;
  final TextStyle lyric;
  final TextStyle chordStyle;
  final VoidCallback onTap;

  @override
  State<_CharCell> createState() => _CharCellState();
}

class _CharCellState extends State<_CharCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final chordHeight = widget.chordStyle.fontSize! * chordLineHeight;
    final gap = widget.chordStyle.fontSize! * chordGapRatio;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        // 칸 폭 = max(글자, 코드 + 틈). 코드 자리 테두리가 그 폭을 다 채우게 IntrinsicWidth + stretch.
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: chordHeight,
                padding: EdgeInsets.only(right: widget.chord == null ? 0 : gap),
                decoration: _hover
                    ? BoxDecoration(
                        border: Border.all(
                          color: chordColor.withValues(alpha: 0.7),
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(3),
                      )
                    : null,
                child: widget.chord == null
                    ? null
                    : Text(
                        widget.chord!,
                        softWrap: false,
                        style: widget.chordStyle,
                      ),
              ),
              Text(widget.text, softWrap: false, style: widget.lyric),
            ],
          ),
        ),
      ),
    );
  }
}

/// 조 배지 `A (원래 G, +2)` — 중립색(테두리·글자 회색, 바탕 없음). 조를 바꿨을 때만 띄운다.
class ChordKeyBadge extends StatelessWidget {
  const ChordKeyBadge(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: chordKeyBadgeColor),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: chordKeyBadgeColor,
        ),
      ),
    );
  }
}
