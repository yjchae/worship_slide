import 'package:flutter/material.dart';

import '../data/worship_conti_repository.dart' show normalizeItemGroup;

/// 그룹 이름 제안 칩.
const presetGroupNames = ['시작곡', '말씀', '헌신송', '광고', '찬양', '기타'];

/// 그룹 이름 입력 결과. [withSelected] = 고른 항목을 이 그룹에 넣을지('그룹 만들기'에서만 뜻이 있다).
typedef GroupNameResult = ({String name, bool withSelected});

/// 이름을 이미 쓰고 있는지([taken] 은 이 콘티의 다른 그룹 이름). 같으면 오류 문구, 아니면 null.
String? groupNameError(String? normalized, Iterable<String> taken) {
  if (normalized == null) return null;
  return taken.contains(normalized) ? '이미 있는 그룹 이름입니다.' : null;
}

/// 그룹 이름을 묻는다(만들기·이름 바꾸기 공용). 취소하면 null.
/// [selectedTitle] 이 있으면 '고른 항목 넣기' 체크가 뜬다(기본 켬).
Future<GroupNameResult?> showGroupNameDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required Iterable<String> takenNames,
  String initial = '',
  String? selectedTitle,
}) => showDialog<GroupNameResult>(
  context: context,
  builder: (_) => _GroupNameDialog(
    title: title,
    confirmLabel: confirmLabel,
    takenNames: takenNames.toSet(),
    initial: initial,
    selectedTitle: selectedTitle,
  ),
);

class _GroupNameDialog extends StatefulWidget {
  const _GroupNameDialog({
    required this.title,
    required this.confirmLabel,
    required this.takenNames,
    required this.initial,
    required this.selectedTitle,
  });

  final String title;
  final String confirmLabel;
  final Set<String> takenNames;
  final String initial;
  final String? selectedTitle;

  @override
  State<_GroupNameDialog> createState() => _GroupNameDialogState();
}

class _GroupNameDialogState extends State<_GroupNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  bool _withSelected = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? get _name => normalizeItemGroup(_controller.text);
  String? get _error => groupNameError(_name, widget.takenNames);
  bool get _canSubmit => _name != null && _error == null;

  void _submit() {
    if (_canSubmit) {
      Navigator.of(context).pop((name: _name!, withSelected: _withSelected));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final suggestions = [
      for (final n in presetGroupNames)
        if (!widget.takenNames.contains(n)) n,
    ];
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 12,
              decoration: InputDecoration(hintText: '예: 특송', errorText: _error),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final n in suggestions)
                  ActionChip(
                    label: Text(n),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _controller.text = n),
                  ),
              ],
            ),
            if (widget.selectedTitle != null)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _withSelected,
                onChanged: (v) => setState(() => _withSelected = v ?? true),
                title: Text(
                  '고른 항목 "${widget.selectedTitle}" 넣기',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: cs.onSurface),
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
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
