import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_colors.dart';
import '../domain/conti_text_parse.dart';
import '../domain/praise_song.dart';

/// 콘티 글을 붙여 넣으면 줄마다 곡을 찾아 한꺼번에 담는다.
///
/// 1단계: 글 붙여 넣기 → 2단계: 줄마다 찾은 곡 확인. 같은 제목 곡이 여럿이면
/// 고를 때까지 '담기'를 막는다. 못 찾은 줄은 직접 찾거나 건너뛴다.
/// 돌려주는 값은 담을 곡(줄 순서대로). 취소하면 null.
class ContiTextImportDialog extends StatefulWidget {
  const ContiTextImportDialog({super.key, required this.loadSongs});

  /// 보관함의 모든 곡. 다이얼로그를 열 때 한 번 읽는다.
  final Future<List<PraiseSong>> Function() loadSongs;

  static Future<List<PraiseSong>?> show(
    BuildContext context, {
    required Future<List<PraiseSong>> Function() loadSongs,
  }) => showDialog<List<PraiseSong>>(
    context: context,
    builder: (_) => ContiTextImportDialog(loadSongs: loadSongs),
  );

  @override
  State<ContiTextImportDialog> createState() => _ContiTextImportDialogState();
}

/// 콘티 한 줄과 그 줄에서 고른 곡.
class _Row {
  _Row(this.entry, ContiSongMatch match)
    : kind = match.kind,
      candidates = [...match.candidates],
      // 똑같은 제목 곡이 하나면 바로 고르고, 없으면 건너뛴다. 여럿이거나 비슷한 제목뿐이면
      // 사용자가 고른다 — 비슷한 제목을 미리 골라 두면 엉뚱한 곡이 확인 없이 담긴다.
      chosen =
          match.kind == ContiMatchKind.exact && match.candidates.length == 1
          ? match.candidates.first
          : null,
      skipped = match.candidates.isEmpty;

  final ContiTextEntry entry;
  final ContiMatchKind? kind;

  /// 찾은 곡 + 직접 찾아 고른 곡.
  final List<PraiseSong> candidates;
  PraiseSong? chosen;
  bool skipped;

  bool get decided => skipped || chosen != null;
}

class _ContiTextImportDialogState extends State<ContiTextImportDialog> {
  final _input = TextEditingController();
  ContiSongMatcher? _matcher;
  List<_Row>? _rows;
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _findSongs() async {
    final entries = parseContiText(_input.text);
    if (entries.isEmpty) {
      setState(() => _error = '곡 줄을 찾지 못했습니다. 한 줄에 곡 하나씩 적어 주세요.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _matcher ??= await ContiSongMatcher.build(await widget.loadSongs());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '곡 목록을 읽지 못했습니다: $e';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _rows = [for (final e in entries) _Row(e, _matcher!.match(e))];
    });
  }

  Future<void> _searchManually(_Row row) async {
    final picked = await showDialog<PraiseSong>(
      context: context,
      builder: (_) =>
          _SongSearchDialog(matcher: _matcher!, initialQuery: row.entry.titles.first),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (!row.candidates.contains(picked)) row.candidates.add(picked);
      row.chosen = picked;
      row.skipped = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.dialog),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: rows == null ? _buildInput(context) : _buildReview(context, rows),
        ),
      ),
    );
  }

  // ── 1단계: 붙여 넣기 ──────────────────────────────────────────────────

  Widget _buildInput(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(context, '콘티 한번에 넣기'),
        const SizedBox(height: 6),
        Text(
          '번호를 붙인 콘티 글을 붙여 넣으면 줄마다 곡을 찾아 순서대로 담습니다.\n'
          '끝의 조(F, G, Bb …)와 → 표시는 무시하고, (or 다른 곡)은 후보로 같이 찾습니다.',
          style: TextStyle(fontSize: 13, height: 1.5, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        Flexible(
          child: TextField(
            controller: _input,
            autofocus: true,
            minLines: 10,
            maxLines: 16,
            style: const TextStyle(fontSize: 14, height: 1.5),
            decoration: const InputDecoration(
              hintText:
                  '<11.01 (주일) 예배 콘티>\n\n'
                  '1. 아침에 주의 인자하심을 F\n'
                  '2. 갈길을 밝히 보이시니(or 죄에서 자유를 얻게 함은) G\n'
                  '3. 나의 반석이신 하나님 G',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(fontSize: 13, color: cs.error)),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _loading ? null : _findSongs,
              icon: _loading
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_rounded, size: 18),
              label: const Text('곡 찾기'),
            ),
          ],
        ),
      ],
    );
  }

  // ── 2단계: 찾은 곡 확인 ───────────────────────────────────────────────

  Widget _buildReview(BuildContext context, List<_Row> rows) {
    final cs = Theme.of(context).colorScheme;
    final pending = rows.where((r) => !r.decided).length;
    final chosen = [
      for (final r in rows)
        if (!r.skipped && r.chosen != null) r.chosen!,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(context, '찾은 곡 확인'),
        const SizedBox(height: 6),
        Text(
          pending > 0
              ? '골라야 할 줄이 $pending개 있습니다(같은 제목이 여럿이거나 비슷한 제목). 담을 곡을 골라 주세요.'
              : '확인했으면 담기를 누르세요. 콘티 맨 끝에 순서대로 담깁니다.',
          style: TextStyle(
            fontSize: 13,
            color: pending > 0 ? cs.error : cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) => _RowCard(
              row: rows[i],
              onChoose: (song) => setState(() {
                rows[i].chosen = song;
                rows[i].skipped = false;
              }),
              onSkip: () => setState(() => rows[i].skipped = true),
              onSearch: () => _searchManually(rows[i]),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            TextButton.icon(
              onPressed: () => setState(() => _rows = null),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('다시 입력'),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: pending > 0 || chosen.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(chosen),
              icon: const Icon(Icons.playlist_add_rounded, size: 18),
              label: Text('${chosen.length}곡 담기'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _title(BuildContext context, String text) => Text(
    text,
    style: TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w700,
      color: Theme.of(context).colorScheme.onSurface,
    ),
  );
}

/// 콘티 한 줄: 원래 글 + 상태 + 후보 곡들 + (직접 찾기 · 건너뛰기).
class _RowCard extends StatelessWidget {
  const _RowCard({
    required this.row,
    required this.onChoose,
    required this.onSkip,
    required this.onSearch,
  });

  final _Row row;
  final ValueChanged<PraiseSong> onChoose;
  final VoidCallback onSkip;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entry = row.entry;
    final needsChoice = !row.decided;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.panel),
        border: Border.all(
          color: needsChoice ? cs.error : cs.outlineVariant,
          width: needsChoice ? 1.5 : 1,
        ),
        color: row.skipped ? cs.surfaceContainerHighest.withValues(alpha: 0.4) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Badge(
                text: entry.number?.toString() ?? '•',
                background: cs.primaryContainer,
                foreground: cs.onPrimaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.titles.join('  /  '),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ),
              if (entry.key.isNotEmpty) ...[
                const SizedBox(width: 6),
                _Badge(
                  text: entry.key,
                  background: cs.secondaryContainer,
                  foreground: cs.onSecondaryContainer,
                ),
              ],
              const SizedBox(width: 6),
              _statusBadge(cs),
            ],
          ),
          const SizedBox(height: 6),
          if (row.candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '보관함에서 이 제목을 찾지 못했습니다. 직접 찾거나 건너뛰세요.',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ),
          for (final song in row.candidates)
            _CandidateTile(
              song: song,
              selected: !row.skipped && row.chosen == song,
              onTap: () => onChoose(song),
            ),
          Row(
            children: [
              TextButton.icon(
                onPressed: onSearch,
                icon: const Icon(Icons.manage_search_rounded, size: 18),
                label: const Text('직접 찾기'),
              ),
              TextButton.icon(
                onPressed: row.skipped ? null : onSkip,
                icon: const Icon(Icons.block_rounded, size: 16),
                label: const Text('건너뛰기'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(ColorScheme cs) {
    final (String text, Color bg, Color fg) = switch (row) {
      _Row(skipped: true) => ('담지 않음', cs.surfaceContainerHighest, cs.onSurfaceVariant),
      _Row(decided: false) => ('선택 필요', cs.errorContainer, cs.onErrorContainer),
      _Row(kind: ContiMatchKind.partial) => ('비슷한 제목', cs.tertiaryContainer, cs.onTertiaryContainer),
      _ => ('찾음', cs.primaryContainer, cs.onPrimaryContainer),
    };
    return _Badge(text: text, background: bg, foreground: fg);
  }
}

/// 후보 곡 하나. 같은 제목 곡을 가를 수 있게 첫 가사·쪽 수·파일 이름을 같이 보이고,
/// 마우스를 올리면 가사 앞부분을 띄운다.
class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.song,
    required this.selected,
    required this.onTap,
  });

  final PraiseSong song;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lines = song.lyrics
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final details = [
      if (lines.isNotEmpty) lines.first,
      '${song.pairedPages.length}쪽',
      if (song.fileName.isNotEmpty) song.fileName,
    ].join('  ·  ');
    return Tooltip(
      message: lines.take(8).join('\n'),
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.control),
            color: selected ? cs.primaryContainer.withValues(alpha: 0.6) : null,
            border: Border.all(color: selected ? cs.primary : cs.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 18,
                color: selected ? cs.primary : cs.outline,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.displayTitle,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: cs.onSurface),
                    ),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.text,
    required this.background,
    required this.foreground,
  });

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(AppRadius.control),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: foreground),
    ),
  );
}

/// 못 찾은 줄·다른 곡으로 바꿀 때: 제목(띄어쓰기 무시)이나 가사로 찾아 한 곡 고르기.
class _SongSearchDialog extends StatefulWidget {
  const _SongSearchDialog({required this.matcher, required this.initialQuery});

  final ContiSongMatcher matcher;
  final String initialQuery;

  @override
  State<_SongSearchDialog> createState() => _SongSearchDialogState();
}

class _SongSearchDialogState extends State<_SongSearchDialog> {
  late final _query = TextEditingController(text: widget.initialQuery);
  late List<PraiseSong> _results = widget.matcher.search(widget.initialQuery);
  Timer? _debounce;
  String _lastQuery = '';

  /// 결과가 너무 많으면 앞쪽만 그린다(한두 글자 검색).
  static const _maxShown = 100;

  @override
  void initState() {
    super.initState();
    _lastQuery = _query.text;
    // 한글 조합 중에도 결과가 따라오게 onChanged 대신 listener 로 받는다.
    // 곡이 수천 곡이면 가사까지 훑는 데 시간이 들어 입력이 멈출 때까지 잠깐 기다린다.
    _query.addListener(() {
      if (_query.text == _lastQuery) return; // 커서만 움직인 경우
      _lastQuery = _query.text;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 200), () {
        final results = widget.matcher.search(_query.text);
        if (mounted) setState(() => _results = results);
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shown = _results.take(_maxShown).toList();
    return AlertDialog(
      title: const Text('곡 직접 찾기'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: '제목이나 가사 일부',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        '찾은 곡이 없습니다',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) => _CandidateTile(
                        song: shown[i],
                        selected: false,
                        onTap: () => Navigator.of(context).pop(shown[i]),
                      ),
                    ),
            ),
            if (_results.length > _maxShown)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${_results.length}곡 중 앞 $_maxShown곡만 보입니다. 더 자세히 입력하세요.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
      ],
    );
  }
}
