import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_colors.dart';
import '../data/obs_overlay_server.dart';
import '../data/obs_overlay_store.dart';
import '../data/singer_web_server.dart';
import '../domain/export_style.dart';
import '../domain/obs_caption.dart';
import 'style_fields.dart';

/// 'OBS 자막' 설정 창. 값을 바꾸면 바로 [onChanged] 로 넘긴다(저장·서버 다시 켜기는 부르는 쪽) —
/// 미리보기와 OBS 가 같이 움직이게 확인 버튼이 없다.
class ObsOverlayDialog extends StatefulWidget {
  const ObsOverlayDialog({
    super.key,
    required this.config,
    required this.server,
    required this.hidden,
    required this.audienceFont,
    required this.currentSlide,
    required this.onChanged,
  });

  final ObsOverlayConfig config;
  final ObsOverlayServer server;

  /// 'OBS 자막 잠시 숨기기'(실행 동안만).
  final ValueNotifier<bool> hidden;

  /// 글꼴을 '관객 화면 글꼴 따라가기'로 둔 경우 쓰는 글꼴.
  final String audienceFont;

  /// 미리보기 '지금 페이지'. 없으면 예시.
  final ObsSlide? currentSlide;
  final ValueChanged<ObsOverlayConfig> onChanged;

  @override
  State<ObsOverlayDialog> createState() => _ObsOverlayDialogState();
}

enum _PreviewSample { current, song, bible }

enum _PreviewBack { checker, camera, bright }

class _ObsOverlayDialogState extends State<ObsOverlayDialog> {
  late ObsOverlayConfig _config = widget.config;
  List<String> _lanAddresses = const [];
  late final _portController = TextEditingController(
    text: '${widget.config.port}',
  );
  late _PreviewSample _sample = widget.currentSlide == null
      ? _PreviewSample.song
      : _PreviewSample.current;
  _PreviewBack _back = _PreviewBack.camera;

  @override
  void initState() {
    super.initState();
    SingerWebServer.lanAddresses().then((list) {
      if (mounted) setState(() => _lanAddresses = list);
    });
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  void _set(ObsOverlayConfig next) {
    setState(() => _config = next);
    widget.onChanged(next);
  }

  String get _host => _config.allowLan && _lanAddresses.isNotEmpty
      ? _lanAddresses.first
      : '127.0.0.1';

  String _url(String host, {bool preview = false}) =>
      'http://$host:${_config.port}/obs?k=${_config.key}${preview ? '&preview=1' : ''}';

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('주소를 복사했습니다.')));
  }

  Future<void> _openInBrowser() async {
    final url = _url('127.0.0.1', preview: true);
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isWindows) {
        // cmd /c start 는 & 를 명령 구분자로 읽는다 — URL 처리기에 바로 넘긴다.
        await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (_) {}
  }

  Future<void> _renewKey() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('키 새로 만들기'),
        content: const Text(
          '지금 OBS 에 넣어 둔 주소는 더 이상 열리지 않습니다.\n'
          '새 주소를 OBS 브라우저 소스에 다시 넣어야 합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('새로 만들기'),
          ),
        ],
      ),
    );
    if (ok == true) _set(_config.copyWith(key: newObsKey()));
  }

  void _applyPort() {
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < minObsPort || port > maxObsPort) {
      _portController.text = '${_config.port}';
      return;
    }
    if (port != _config.port) _set(_config.copyWith(port: port));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 760),
        child: DefaultTabController(
          length: 2,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 12, 0),
                child: Row(
                  children: [
                    Icon(Icons.cast_connected_rounded, color: cs.primary),
                    const SizedBox(width: 10),
                    const Text(
                      'OBS 자막',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 24),
                    const SizedBox(
                      width: 200,
                      child: TabBar(
                        tabs: [
                          Tab(text: '연결'),
                          Tab(text: '디자인'),
                        ],
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '닫기',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: TabBarView(
                  children: [_connectionTab(cs), _designTab(cs)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 연결 ──────────────────────────────────────────────────────────────

  Widget _statusText(ColorScheme cs) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.server.status,
        widget.server.clients,
      ]),
      builder: (context, _) {
        final (text, color) = obsStatusText(
          enabled: _config.enabled,
          status: widget.server.status.value,
          clients: widget.server.clients.value,
          port: _config.port,
          cs: cs,
        );
        return Text(
          text,
          style: TextStyle(
            fontSize: 13,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        );
      },
    );
  }

  Widget _connectionTab(ColorScheme cs) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Switch(
                value: _config.enabled,
                onChanged: (v) => _set(_config.copyWith(enabled: v)),
              ),
              const SizedBox(width: 10),
              const Text(
                'OBS 자막 켜기',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 16),
              Expanded(child: _statusText(cs)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '켜 두면 앱을 켤 때마다 자동으로 켜집니다. 주소는 바뀌지 않으니 OBS 에 한 번만 넣으면 됩니다.',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          _section('OBS 에 넣을 주소'),
          _addressRow(cs, _url(_host)),
          if (_config.allowLan && _lanAddresses.length > 1)
            for (final ip in _lanAddresses.skip(1))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _addressRow(cs, _url(ip), secondary: true),
              ),
          const SizedBox(height: 6),
          Row(
            children: [
              TextButton.icon(
                onPressed: _config.enabled ? _openInBrowser : null,
                icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                label: const Text('이 PC 브라우저에서 열어 보기 (바둑판 = 투명)'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _config.allowLan,
            onChanged: (v) => _set(_config.copyWith(allowLan: v)),
            title: const Text('다른 PC 의 OBS 에서 받기 (같은 망)'),
            subtitle: Text(
              _config.allowLan
                  ? '방송 PC 의 OBS 에 위 주소를 넣습니다. 처음엔 이 PC 방화벽이 들어오는 연결을 물으면 허용해 주세요. '
                        '이 PC 의 IP 가 바뀌면(공유기 재시작 등) 주소도 바뀝니다 — 공유기에서 IP 를 고정해 두면 좋습니다.'
                  : '이 PC 에서 돌리는 OBS 만 받습니다(127.0.0.1).',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 14),
          _section('예배 중'),
          ValueListenableBuilder(
            valueListenable: widget.hidden,
            builder: (context, hidden, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: hidden,
              onChanged: (v) => widget.hidden.value = v,
              title: const Text('OBS 자막 잠시 숨기기'),
              subtitle: const Text(
                '관객 화면은 그대로 두고 방송 자막만 감춥니다. 앱을 다시 켜면 풀립니다.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
          Text(
            '발표 전·발표 종료 후·블랙아웃 중에는 관객 화면처럼 OBS 자막도 투명합니다. '
            'PPT 그림·편집 페이지·동영상 페이지도 이번 단계에서는 OBS 에 나가지 않습니다.',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('고급 — 포트·키', style: TextStyle(fontSize: 14)),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: [
              Row(
                children: [
                  const Text('포트'),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      controller: _portController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(isDense: true),
                      onSubmitted: (_) => _applyPort(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _applyPort,
                    child: const Text('적용'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '바꾸면 OBS 에 넣은 주소도 바꿔야 합니다. (기본 $defaultObsPort)',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _renewKey,
                    icon: const Icon(Icons.key_rounded, size: 17),
                    label: const Text('키 새로 만들기'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '주소가 다른 사람에게 퍼졌을 때만 쓰세요.',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('OBS 에 넣는 법', style: TextStyle(fontSize: 14)),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            expandedAlignment: Alignment.topLeft,
            children: [
              Text(
                '1. OBS 의 장면에서 소스 추가(+) → 브라우저\n'
                '2. URL 에 위 주소를 붙여 넣고, 너비 1920 · 높이 1080 으로 둡니다\n'
                '3. 사용자 지정 CSS 는 비워 두거나 지워도 됩니다(바탕은 이미 투명)\n'
                '4. 확인 후 소스를 화면에 맞추고, 자막 위치·크기는 이 창의 디자인 탭에서 맞춥니다\n'
                '   (OBS 에서 소스를 옮기거나 잘라도 됩니다)\n'
                '※ 메뉴 이름은 OBS 판마다 조금 다를 수 있습니다. 앱보다 OBS 를 먼저 켰다면 소스의 '
                "'새로 고침'을 한 번 눌러 주세요.",
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _addressRow(ColorScheme cs, String url, {bool secondary = false}) {
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: SelectableText(
              url,
              maxLines: 1,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: secondary ? 12 : 13,
                color: secondary ? cs.onSurfaceVariant : cs.onSurface,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.tonalIcon(
          onPressed: () => _copy(url),
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: const Text('주소 복사'),
        ),
      ],
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      title,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
    ),
  );

  // ── 디자인 ────────────────────────────────────────────────────────────

  ObsSlide get _previewSlide => switch (_sample) {
    _PreviewSample.current => widget.currentSlide ?? _songSample,
    _PreviewSample.song => _songSample,
    _PreviewSample.bible => _bibleSample,
  };

  static const _songSample = ObsSlide(
    mainText: '주의 사랑이 나를 감싸네\n어둠 속에도 빛이 되시네',
    subText: 'Your love surrounds me\nYou are my light in the dark',
    extraText: '主の愛がわたしを包む',
    title: '예시 찬양',
  );

  static const _bibleSample = ObsSlide(
    mainText: '1 여호와는 나의 목자시니 내게 부족함이 없으리로다',
    subText: '1 The LORD is my shepherd; I shall not want.',
    title: '시편 23:1',
    isBible: true,
  );

  Widget _designTab(ColorScheme cs) {
    final caption = obsCaptionFor(
      slide: _previewSlide,
      presenting: true,
      blackout: false,
      hidden: false,
      config: _config,
    );
    final preview = Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 12, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.control),
              child: _PreviewStage(
                back: _back,
                caption: caption,
                config: _config,
                family: _config.fontFamily.isEmpty
                    ? widget.audienceFont
                    : _config.fontFamily,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SegmentedButton<_PreviewSample>(
                showSelectedIcon: false,
                segments: [
                  if (widget.currentSlide != null)
                    const ButtonSegment(
                      value: _PreviewSample.current,
                      label: Text('지금 페이지'),
                    ),
                  const ButtonSegment(
                    value: _PreviewSample.song,
                    label: Text('찬양 예시'),
                  ),
                  const ButtonSegment(
                    value: _PreviewSample.bible,
                    label: Text('성경 예시'),
                  ),
                ],
                selected: {_sample},
                onSelectionChanged: (s) => setState(() => _sample = s.first),
              ),
              SegmentedButton<_PreviewBack>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: _PreviewBack.camera,
                    label: Text('어두운 화면'),
                  ),
                  ButtonSegment(
                    value: _PreviewBack.bright,
                    label: Text('밝은 화면'),
                  ),
                  ButtonSegment(
                    value: _PreviewBack.checker,
                    label: Text('바둑판'),
                  ),
                ],
                selected: {_back},
                onSelectionChanged: (s) => setState(() => _back = s.first),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '미리보기는 앱이 비슷하게 그린 것입니다. 실제 모양은 OBS 또는 \'브라우저에서 열어 보기\'로 확인하세요.',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                preview,
                const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _designForm(cs),
                ),
              ],
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: SingleChildScrollView(child: preview)),
            Expanded(
              flex: 2,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 16, 24, 24),
                child: _designForm(cs),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _designForm(ColorScheme cs) {
    final c = _config;
    const swatches = [
      Colors.white,
      Color(0xFFFFE082),
      Color(0xFFFFD54F),
      Color(0xFFB3E5FC),
      Color(0xFFC5E1A5),
      Colors.black,
    ];
    Widget color(String title, String hex, ValueChanged<String> onPick) =>
        ColorField(
          dialogTitle: title,
          caption: title,
          color: parseHexColor(hex, Colors.white),
          colors: swatches,
          onSelected: (v) => onPick(colorToHex(v)),
        );
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      String text,
      ValueChanged<double> onChanged, {
      int? divisions,
    }) => Row(
      children: [
        SizedBox(
          width: 82,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
    Widget check(String label, bool value, ValueChanged<bool> onChanged) =>
        FilterChip(label: Text(label), selected: value, onSelected: onChanged);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section('빠른 스타일'),
        Wrap(
          spacing: 8,
          children: [
            ActionChip(
              label: const Text('외곽선'),
              onPressed: () => _set(
                c.copyWith(band: ObsBand.none, outlineWidth: 3, shadow: true),
              ),
            ),
            ActionChip(
              label: const Text('반투명 띠'),
              onPressed: () => _set(
                c.copyWith(
                  band: ObsBand.text,
                  outlineWidth: 0,
                  shadow: false,
                  bandOpacity: 0.55,
                ),
              ),
            ),
            ActionChip(
              label: const Text('화면 폭 띠'),
              onPressed: () => _set(
                c.copyWith(
                  band: ObsBand.full,
                  outlineWidth: 0,
                  shadow: false,
                  bandOpacity: 0.6,
                  offset: 0,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _section('글꼴'),
        Row(
          children: [
            Expanded(
              child: FontFamilyPicker(
                selected: c.fontFamily.isEmpty
                    ? widget.audienceFont
                    : c.fontFamily,
                onChanged: (v) => _set(c.copyWith(fontFamily: v)),
              ),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: const Text('관객 화면 따라가기'),
              selected: c.fontFamily.isEmpty,
              onSelected: (v) =>
                  _set(c.copyWith(fontFamily: v ? '' : widget.audienceFont)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        slider(
          '크기',
          c.fontSize,
          24,
          120,
          '${c.fontSize.round()}',
          (v) => _set(c.copyWith(fontSize: v.roundToDouble())),
        ),
        slider(
          '보조 크기',
          c.subRatio,
          0.4,
          1.2,
          '${(c.subRatio * 100).round()}%',
          (v) => _set(c.copyWith(subRatio: (v * 20).round() / 20)),
        ),
        slider(
          '추가 크기',
          c.extraRatio,
          0.4,
          1.2,
          '${(c.extraRatio * 100).round()}%',
          (v) => _set(c.copyWith(extraRatio: (v * 20).round() / 20)),
        ),
        Wrap(
          spacing: 8,
          children: [check('굵게', c.bold, (v) => _set(c.copyWith(bold: v)))],
        ),
        const SizedBox(height: 16),
        _section('보일 줄'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            check('보조 언어', c.showSub, (v) => _set(c.copyWith(showSub: v))),
            check('추가 보조', c.showExtra, (v) => _set(c.copyWith(showExtra: v))),
            check(
              '성경 참조',
              c.showReference,
              (v) => _set(c.copyWith(showReference: v)),
            ),
            check(
              '곡 제목',
              c.showSongTitle,
              (v) => _set(c.copyWith(showSongTitle: v)),
            ),
            check(
              '설교 제목 페이지',
              c.showSermon,
              (v) => _set(c.copyWith(showSermon: v)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _section('색'),
        Row(
          children: [
            Expanded(
              child: color(
                '원본',
                c.mainColor,
                (v) => _set(c.copyWith(mainColor: v)),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: color(
                '보조',
                c.subColor,
                (v) => _set(c.copyWith(subColor: v)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: color(
                '추가',
                c.extraColor,
                (v) => _set(c.copyWith(extraColor: v)),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: color(
                '참조',
                c.referenceColor,
                (v) => _set(c.copyWith(referenceColor: v)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _section('외곽선·그림자'),
        slider(
          '외곽선',
          c.outlineWidth,
          0,
          8,
          c.outlineWidth == 0 ? '없음' : c.outlineWidth.toStringAsFixed(1),
          (v) => _set(c.copyWith(outlineWidth: (v * 2).round() / 2)),
        ),
        Row(
          children: [
            Expanded(
              child: color(
                '외곽선 색',
                c.outlineColor,
                (v) => _set(c.copyWith(outlineColor: v)),
              ),
            ),
            const SizedBox(width: 8),
            check('그림자', c.shadow, (v) => _set(c.copyWith(shadow: v))),
          ],
        ),
        const SizedBox(height: 16),
        _section('띠'),
        SegmentedButton<ObsBand>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ObsBand.none, label: Text('없음')),
            ButtonSegment(value: ObsBand.text, label: Text('글 폭')),
            ButtonSegment(value: ObsBand.full, label: Text('화면 폭')),
          ],
          selected: {c.band},
          onSelectionChanged: (s) => _set(c.copyWith(band: s.first)),
        ),
        if (c.band != ObsBand.none) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: color(
                  '띠 색',
                  c.bandColor,
                  (v) => _set(c.copyWith(bandColor: v)),
                ),
              ),
            ],
          ),
          slider(
            '불투명도',
            c.bandOpacity,
            0,
            1,
            '${(c.bandOpacity * 100).round()}%',
            (v) => _set(c.copyWith(bandOpacity: (v * 20).round() / 20)),
          ),
        ],
        const SizedBox(height: 16),
        _section('위치'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SegmentedButton<ObsAlign>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: ObsAlign.left,
                  icon: Icon(Icons.format_align_left_rounded, size: 18),
                ),
                ButtonSegment(
                  value: ObsAlign.center,
                  icon: Icon(Icons.format_align_center_rounded, size: 18),
                ),
                ButtonSegment(
                  value: ObsAlign.right,
                  icon: Icon(Icons.format_align_right_rounded, size: 18),
                ),
              ],
              selected: {c.align},
              onSelectionChanged: (s) => _set(c.copyWith(align: s.first)),
            ),
            SegmentedButton<ObsAnchor>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ObsAnchor.bottom, label: Text('아래')),
                ButtonSegment(value: ObsAnchor.top, label: Text('위')),
              ],
              selected: {c.anchor},
              onSelectionChanged: (s) => _set(c.copyWith(anchor: s.first)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        slider(
          '거리',
          c.offset,
          0,
          400,
          '${c.offset.round()}',
          (v) => _set(c.copyWith(offset: (v / 5).round() * 5.0)),
        ),
        slider(
          '좌우 여백',
          c.sideMargin,
          0,
          500,
          '${c.sideMargin.round()}',
          (v) => _set(c.copyWith(sideMargin: (v / 5).round() * 5.0)),
        ),
        slider(
          '최대 높이',
          c.maxHeight,
          0.15,
          1,
          '${(c.maxHeight * 100).round()}%',
          (v) => _set(c.copyWith(maxHeight: (v * 20).round() / 20)),
        ),
        Wrap(
          spacing: 8,
          children: [
            check('페이지 바뀔 때 페이드', c.fade, (v) => _set(c.copyWith(fade: v))),
          ],
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: () => _set(c.resetDesign()),
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: const Text('디자인 기본값으로'),
        ),
        Text(
          '크기·거리는 OBS 화면 높이 1080 기준입니다.',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 상태 글과 색. 앱 바 버튼 툴팁·설정 창이 같이 쓴다.
(String, Color) obsStatusText({
  required bool enabled,
  required ObsServerStatus status,
  required int clients,
  required int port,
  required ColorScheme cs,
}) {
  if (!enabled) return ('꺼짐', cs.onSurfaceVariant);
  return switch (status) {
    ObsServerStatus.portInUse => (
      '포트 $port 를 다른 프로그램이 쓰고 있습니다 — 고급에서 포트를 바꿔 주세요',
      cs.error,
    ),
    ObsServerStatus.failed => ('서버를 켜지 못했습니다', cs.error),
    ObsServerStatus.off => ('켜는 중…', cs.onSurfaceVariant),
    ObsServerStatus.running when clients == 0 => (
      '켜짐 · 연결된 OBS 없음',
      cs.onSurfaceVariant,
    ),
    ObsServerStatus.running => ('켜짐 · OBS $clients곳 연결됨', AppColors.live),
  };
}

/// 설정 창 미리보기. OBS 페이지(HTML)와 같은 규칙을 Flutter 로 비슷하게 그린다.
class _PreviewStage extends StatelessWidget {
  const _PreviewStage({
    required this.back,
    required this.caption,
    required this.config,
    required this.family,
  });

  final _PreviewBack back;
  final ObsCaption caption;
  final ObsOverlayConfig config;
  final String family;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final s = box.maxHeight / 1080;
        return Stack(
          fit: StackFit.expand,
          children: [
            switch (back) {
              _PreviewBack.checker => CustomPaint(painter: _CheckerPainter()),
              _PreviewBack.camera => const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF2A3346),
                      Color(0xFF151A24),
                      Color(0xFF3B2F2A),
                    ],
                  ),
                ),
              ),
              _PreviewBack.bright => const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFFDDE7F0),
                      Color(0xFFF6EFE2),
                      Color(0xFFE9E2D3),
                    ],
                  ),
                ),
              ),
            },
            if (caption.show) _caption(s, box.maxHeight),
            if (!caption.show)
              Center(
                child: Text(
                  obsHideLabel(caption.reason),
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _caption(double s, double height) {
    final c = config;
    final full = c.band == ObsBand.full;
    final shadows = <Shadow>[
      if (c.outlineWidth > 0)
        for (var i = 0; i < 16; i++)
          Shadow(
            color: parseHexColor(c.outlineColor, Colors.black),
            offset: Offset(
              math.cos(i / 16 * math.pi * 2) * c.outlineWidth * s,
              math.sin(i / 16 * math.pi * 2) * c.outlineWidth * s,
            ),
          ),
      if (c.shadow)
        Shadow(
          color: Colors.black.withValues(alpha: 0.75),
          offset: Offset(0, 4 * s),
          blurRadius: 12 * s,
        ),
    ];
    final align = switch (c.align) {
      ObsAlign.left => TextAlign.left,
      ObsAlign.center => TextAlign.center,
      ObsAlign.right => TextAlign.right,
    };
    Widget line(String text, double size, String color, FontWeight weight) =>
        Text(
          text,
          textAlign: align,
          style: TextStyle(
            fontFamily: family,
            fontSize: size,
            height: 1.3,
            color: parseHexColor(color, Colors.white),
            fontWeight: weight,
            shadows: shadows,
          ),
        );
    final size = c.fontSize * s;
    final weight = c.bold ? FontWeight.w700 : FontWeight.w400;
    final gap = SizedBox(height: size * 0.25);
    final cross = switch (c.align) {
      ObsAlign.left => CrossAxisAlignment.start,
      ObsAlign.center => CrossAxisAlignment.center,
      ObsAlign.right => CrossAxisAlignment.end,
    };
    Widget block = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: full ? CrossAxisAlignment.stretch : cross,
      children: [
        if (caption.heading.isNotEmpty) ...[
          line(caption.heading, size * 0.6, c.referenceColor, FontWeight.w600),
          gap,
        ],
        if (caption.main.isNotEmpty)
          line(caption.main, size, c.mainColor, weight),
        if (caption.sub.isNotEmpty) ...[
          if (caption.main.isNotEmpty) gap,
          line(
            caption.sub,
            size * (caption.kind == 'sermon' ? 0.6 : c.subRatio),
            c.subColor,
            weight,
          ),
        ],
        if (caption.extra.isNotEmpty) ...[
          gap,
          line(caption.extra, size * c.extraRatio, c.extraColor, weight),
        ],
      ],
    );
    final side = c.sideMargin * s;
    if (c.band != ObsBand.none) {
      final pad = c.fontSize * 0.35 * s;
      block = Container(
        padding: full
            ? EdgeInsets.symmetric(vertical: pad, horizontal: side)
            : EdgeInsets.symmetric(vertical: pad, horizontal: pad * 1.6),
        decoration: BoxDecoration(
          color: parseHexColor(
            c.bandColor,
            Colors.black,
          ).withValues(alpha: c.bandOpacity),
          borderRadius: full ? null : BorderRadius.circular(10 * s),
        ),
        child: block,
      );
    }
    final offset = c.offset * s;
    return Positioned(
      left: full ? 0 : side,
      right: full ? 0 : side,
      top: c.anchor == ObsAnchor.top ? offset : null,
      bottom: c.anchor == ObsAnchor.bottom ? offset : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height * c.maxHeight),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: c.anchor == ObsAnchor.top
              ? Alignment.topCenter
              : Alignment.bottomCenter,
          child: SizedBox(
            width: full ? (height * 16 / 9) : (height * 16 / 9) - side * 2,
            child: Align(
              alignment: switch (c.align) {
                ObsAlign.left => Alignment.centerLeft,
                ObsAlign.center => Alignment.center,
                ObsAlign.right => Alignment.centerRight,
              },
              child: block,
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final light = Paint()..color = const Color(0xFFCCCCCC);
    final dark = Paint()..color = const Color(0xFF999999);
    canvas.drawRect(Offset.zero & size, light);
    const cell = 12.0;
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        if (((x / cell).floor() + (y / cell).floor()).isEven) continue;
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), dark);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 앱 바 OBS 버튼(켜 두었을 때만 보인다). 상태 점: 꺼짐 = 없음 / 연결 없음 = 회색 / 연결됨 = 초록 / 오류 = 빨강 / 숨김 = 주황.
class ObsAppBarButton extends StatelessWidget {
  const ObsAppBarButton({
    super.key,
    required this.enabled,
    required this.port,
    required this.server,
    required this.hidden,
    required this.onPressed,
  });

  final bool enabled;
  final int port;
  final ObsOverlayServer server;
  final ValueNotifier<bool> hidden;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([server.status, server.clients, hidden]),
      builder: (context, _) {
        final status = server.status.value;
        final (text, _) = obsStatusText(
          enabled: enabled,
          status: status,
          clients: server.clients.value,
          port: port,
          cs: cs,
        );
        final error =
            status == ObsServerStatus.portInUse ||
            status == ObsServerStatus.failed;
        final Color? dot = !enabled
            ? null
            : error
            ? cs.error
            : hidden.value
            ? Colors.orange
            : server.clients.value > 0
            ? AppColors.live
            : cs.outline;
        return Tooltip(
          message: 'OBS 자막 — $text${enabled && hidden.value ? ' (숨김)' : ''}',
          child: IconButton(
            onPressed: onPressed,
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.cast_connected_rounded, size: 19),
                if (dot != null)
                  Positioned(
                    right: -3,
                    top: -3,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: dot,
                        shape: BoxShape.circle,
                        border: Border.all(color: cs.surface, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
