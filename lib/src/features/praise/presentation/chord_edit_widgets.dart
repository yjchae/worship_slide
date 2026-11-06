import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/chord_lyrics.dart';
import 'chord_sheet_view.dart';

/// 가사 수정 창 코드 모드 입력칸: 코드 토큰은 주황 굵게, `\[` 는 회색, 코드로 못 읽는 대괄호는 빨간 물결 밑줄.
/// 한글 조합 중에는 칠하지 않는다(조합 밑줄이 우선 — 조합이 끊기지 않게).
class ChordTextController extends TextEditingController {
  ChordTextController({super.text});

  /// 끄면 평범한 입력칸(통째로 보기 원본 칸을 평소 모드로 쓸 때).
  bool highlight = true;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!highlight || (withComposing && value.composing.isValid)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final t = text;
    final marks = <({int start, int end, TextStyle style})>[
      for (final m in chordMarksIn(t))
        (
          start: m.start,
          end: m.end,
          style: m.kind == ChordMarkKind.chord
              ? const TextStyle(color: chordColor, fontWeight: FontWeight.w800)
              : const TextStyle(color: Color(0xFF8B95A2)),
        ),
      for (final r in chordIssueRanges(t))
        (
          start: r.start,
          end: r.end,
          style: const TextStyle(
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.wavy,
            decorationColor: Color(0xFFE5484D),
          ),
        ),
    ]..sort((a, b) => a.start.compareTo(b.start));
    final children = <TextSpan>[];
    var at = 0;
    for (final m in marks) {
      if (m.start < at) continue; // 겹치면 앞 것만
      if (m.start > at) children.add(TextSpan(text: t.substring(at, m.start)));
      children.add(TextSpan(text: t.substring(m.start, m.end), style: m.style));
      at = m.end;
    }
    if (at < t.length) children.add(TextSpan(text: t.substring(at)));
    return TextSpan(style: style, children: children);
  }
}

/// 칸 글(한 페이지) 안 경고 범위. [validateChordText] 의 위치는 trim 한 페이지 기준이라 앞 공백만큼 민다.
List<({int start, int end, ChordIssue issue})> chordIssueRanges(String cell) {
  final lead = cell.length - cell.trimLeft().length;
  return [
    for (final issue in validateChordText(cell))
      if (issue.kind != ChordIssueKind.trailingChordOnlyPage)
        (
          start: (issue.start + lead).clamp(0, cell.length),
          end: (issue.end + lead).clamp(0, cell.length),
          issue: issue,
        ),
  ];
}

/// S1b 결과. [name] null = 지우기. [next] = Tab 으로 넣고 다음 글자로.
typedef ChordPick = ({String? name, bool next});

/// 글자를 눌러 코드 넣기 (S1b). 입력하는 동안 문법을 검사하고, 이 곡에서 쓴 코드·원래 조의
/// 다이어토닉 코드를 빠른 버튼으로 준다.
class ChordPickDialog extends StatefulWidget {
  const ChordPickDialog({
    super.key,
    this.current,
    this.songChords = const [],
    this.songKey,
    this.charLabel = '',
  });

  /// 이 글자에 이미 있는 코드(있으면 바꾸기·지우기).
  final String? current;
  final List<String> songChords;
  final String? songKey;

  /// 어느 글자 위인지 보여 줄 글.
  final String charLabel;

  @override
  State<ChordPickDialog> createState() => _ChordPickDialogState();
}

class _ChordPickDialogState extends State<ChordPickDialog> {
  late final _input = TextEditingController(text: widget.current ?? '');

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  bool get _valid => isChordName(_input.text.trim());

  void _put(String name) {
    _input.text = name;
    _input.selection = TextSelection.collapsed(offset: name.length);
    setState(() {});
  }

  void _append(String part) => _put(_input.text + part);

  void _submit({bool next = false}) {
    if (!_valid) return;
    Navigator.of(context).pop((name: _input.text.trim(), next: next));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final diatonic = widget.songKey == null
        ? const <String>[]
        : diatonicChords(widget.songKey!);
    final text = _input.text.trim();
    Widget quick(String name) => ActionChip(
      label: Text(name),
      visualDensity: VisualDensity.compact,
      onPressed: () => _put(name),
    );
    Widget part(String label, [String? value]) => OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(36, 30),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: () => _append(value ?? label),
      child: Text(label),
    );
    return AlertDialog(
      title: Text(
        widget.current == null
            ? '코드 넣기${widget.charLabel.isEmpty ? '' : ' · ‘${widget.charLabel}’ 위'}'
            : '코드 바꾸기${widget.charLabel.isEmpty ? '' : ' · ‘${widget.charLabel}’ 위'}',
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.tab): () =>
                    _submit(next: true),
              },
              child: TextField(
                controller: _input,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: '코드 (예: G, D/F#, Em7, Cadd9)',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  errorText: text.isEmpty || _valid ? null : '코드로 읽을 수 없습니다',
                ),
              ),
            ),
            if (widget.songChords.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '이 곡에서 쓴 코드',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final c in widget.songChords.take(12)) quick(c),
                ],
              ),
            ],
            if (diatonic.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '${widget.songKey} 조 코드',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [for (final c in diatonic) quick(c)],
              ),
            ],
            const SizedBox(height: 10),
            Text(
              '조립',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final r in const ['C', 'D', 'E', 'F', 'G', 'A', 'B'])
                  part(r),
                part('♯', '#'),
                part('♭', 'b'),
                for (final q in const ['m', '7', 'maj7', 'sus4', 'add9', 'dim'])
                  part(q),
                part('/베이스', '/'),
                TextButton(onPressed: () => _put(''), child: const Text('비우기')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Enter 넣기 · Tab 넣고 다음 글자로 · Esc 닫기',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop((name: null, next: false)),
            child: Text('지우기', style: TextStyle(color: cs.error)),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _valid ? _submit : null,
          child: Text(widget.current == null ? '넣기' : '바꾸기'),
        ),
      ],
    );
  }
}
