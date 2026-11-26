import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/presenter_pin_store.dart';

/// 휴대폰 화면 창 '발표자 모드' 탭의 PIN 표시 + 바꾸기 버튼.
class PresenterPinRow extends StatelessWidget {
  const PresenterPinRow({super.key, required this.pin, required this.onChange});

  final String pin;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lock_outline,
            size: 20,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Text('발표자 PIN', style: TextStyle(color: scheme.onSecondaryContainer)),
          const SizedBox(width: 12),
          SelectableText(
            pin,
            semanticsLabel: '발표자 PIN ${pin.split('').join(' ')}',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: 6,
              color: scheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(onPressed: onChange, child: const Text('바꾸기')),
        ],
      ),
    );
  }
}

/// 발표자 PIN 바꾸기 창. 컨트롤러는 창이 다 닫힌 뒤(State.dispose) 버린다 —
/// showDialog 가 끝난 직후 버리면 닫히는 애니메이션 동안 TextField 가 아직 써서 오류가 났다.
class PresenterPinDialog extends StatefulWidget {
  const PresenterPinDialog({super.key, required this.initial});

  final String initial;

  @override
  State<PresenterPinDialog> createState() => _PresenterPinDialogState();
}

class _PresenterPinDialogState extends State<PresenterPinDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _controller.text.trim();
    if (PresenterPinStore.isValid(v)) {
      Navigator.pop(context, v);
    } else {
      setState(() => _error = '숫자 4자리를 넣어 주세요.');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('발표자 PIN 바꾸기'),
    content: SizedBox(
      width: 280,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: 4,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 28, letterSpacing: 8),
            decoration: InputDecoration(
              labelText: '새 PIN (숫자 4자리)',
              errorText: _error,
              counterText: '',
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          const Text('바꾸면 들어와 있던 발표자 휴대폰도 새 PIN 을 다시 넣어야 합니다.'),
          const SizedBox(height: 8),
          TextButton.icon(
            icon: const Icon(Icons.casino_outlined, size: 18),
            label: const Text('무작위로 정하기'),
            onPressed: () => setState(() {
              _controller.text = PresenterPinStore.random();
              _error = null;
            }),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(onPressed: _submit, child: const Text('바꾸기')),
    ],
  );
}
