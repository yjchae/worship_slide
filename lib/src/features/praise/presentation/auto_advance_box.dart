import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auto_advance_timer.dart';

/// 발표 보기 오른쪽 칸의 '자동 넘기기' 묶음: 간격(분·초) · 반복 · 시작/멈춤 + 남은 시간.
///
/// 남은 시간만 1초마다 다시 그린다(콘솔 전체를 매초 그리지 않게 — 경과 시간 시계와 같은 이유).
/// 값은 [AutoAdvanceTimer] 가 들고 있어서 탭을 옮겨도 계속 돈다.
class AutoAdvanceBox extends StatefulWidget {
  const AutoAdvanceBox({
    super.key,
    required this.timer,
    required this.presenting,
  });

  final AutoAdvanceTimer timer;

  /// 발표 중일 때만 시작할 수 있다(관객 화면이 없으면 넘길 대상이 없다).
  final bool presenting;

  @override
  State<AutoAdvanceBox> createState() => _AutoAdvanceBoxState();
}

class _AutoAdvanceBoxState extends State<AutoAdvanceBox> {
  Timer? _ticker;
  late final _minutes = TextEditingController(
    text: widget.timer.interval.inMinutes.toString(),
  );
  late final _seconds = TextEditingController(
    text: (widget.timer.interval.inSeconds % 60).toString().padLeft(2, '0'),
  );

  AutoAdvanceTimer get _timer => widget.timer;

  @override
  void initState() {
    super.initState();
    _timer.addListener(_onTimerChanged);
    _syncTicker();
  }

  @override
  void dispose() {
    _timer.removeListener(_onTimerChanged);
    _ticker?.cancel();
    _minutes.dispose();
    _seconds.dispose();
    super.dispose();
  }

  void _onTimerChanged() {
    if (!mounted) return;
    _syncTicker();
    setState(() {});
  }

  // 도는 동안만 1초마다 남은 시간을 다시 그린다.
  void _syncTicker() {
    if (_timer.isRunning) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  // 입력하는 즉시 반영한다(엔터를 안 쳐도 시작 버튼이 새 값으로 돈다).
  Duration get _typed => Duration(
    minutes: int.tryParse(_minutes.text) ?? 0,
    seconds: int.tryParse(_seconds.text) ?? 0,
  );

  bool get _inputValid => _typed >= AutoAdvanceTimer.minInterval;

  static String _fmt(Duration d) {
    // 0.4초 남았을 때 00:00 이 보이지 않게 올림한다.
    final secs = (d.inMilliseconds / 1000).ceil();
    final m = (secs ~/ 60).toString().padLeft(2, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final running = _timer.isRunning;
    final canStart = widget.presenting && _inputValid;
    Widget unit(String s) => Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        s,
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '자동 넘기기',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: cs.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            if (running)
              Text(
                '다음 넘김 ${_fmt(_timer.remaining)}',
                key: const ValueKey('auto-advance-remaining'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: cs.primary,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _numberField(_minutes, key: const ValueKey('auto-advance-min')),
            unit('분'),
            const SizedBox(width: 4),
            _numberField(_seconds, key: const ValueKey('auto-advance-sec')),
            unit('초'),
            const Spacer(),
            FilterChip(
              key: const ValueKey('auto-advance-repeat'),
              tooltip: '켜면 시간이 찰 때마다 계속 넘깁니다. 끄면 한 번만 넘기고 멈춥니다.',
              avatar: const Icon(Icons.repeat_rounded, size: 16),
              label: Text(_timer.repeat ? '반복' : '한 번'),
              labelStyle: const TextStyle(fontSize: 11),
              visualDensity: VisualDensity.compact,
              showCheckmark: false,
              selected: _timer.repeat,
              onSelected: _timer.setRepeat,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: running
              ? OutlinedButton.icon(
                  key: const ValueKey('auto-advance-stop'),
                  onPressed: _timer.stop,
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('자동 넘기기 멈춤'),
                )
              : Tooltip(
                  message: widget.presenting
                      ? (_inputValid ? '' : '1초 이상으로 정해 주세요')
                      : '발표를 시작해야 쓸 수 있습니다',
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('auto-advance-start'),
                    onPressed: canStart ? _timer.start : null,
                    icon: const Icon(Icons.timer_outlined, size: 18),
                    label: const Text('자동 넘기기 시작'),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _numberField(TextEditingController controller, {Key? key}) {
    return SizedBox(
      width: 44,
      height: 32,
      child: TextField(
        key: key,
        controller: controller,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 13),
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(3),
        ],
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 6),
          border: OutlineInputBorder(),
        ),
        onChanged: (_) => setState(() => _timer.setInterval(_typed)),
      ),
    );
  }
}
