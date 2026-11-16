import 'package:flutter/material.dart';

import '../data/worship_conti_repository.dart' show normalizeItemGroup;

/// 그룹 이름 칩 6개(콘티 항목 그룹 팝업·번호 범위 다이얼로그 공용).
const presetGroupNames = ['시작곡', '말씀', '헌신송', '광고', '찬양', '기타'];

/// 팝업·칩에 보일 이름 목록: 기본 이름 + 이 콘티에서 쓴 다른 이름.
List<String> extraGroupNames(Iterable<String> used) => [
  for (final n in used.toSet())
    if (!presetGroupNames.contains(n)) n,
];

const _customValue = '\u0000custom';
const _noneValue = '\u0000none';

/// 콘티 항목 행의 그룹 칩. 눌러서 그룹을 고르면 [onChanged] (null = 그룹 없음).
class ItemGroupChip extends StatelessWidget {
  const ItemGroupChip({
    super.key,
    required this.group,
    required this.usedNames,
    required this.onChanged,
    this.dimmed = false,
  });

  final String? group;

  /// 이 콘티에서 쓰는 그룹 이름들(중복 가능, 기본 이름은 걸러 낸다).
  final Iterable<String> usedNames;
  final ValueChanged<String?> onChanged;

  /// 앞 항목과 같은 그룹으로 이어진 둘째 항목부터는 흐리게.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = group;
    final label = name == null
        ? '그룹'
        : name.length > 8
        ? '${name.substring(0, 8)}…'
        : name;
    final chip = Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: name == null ? null : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: name == null ? Border.all(color: cs.outlineVariant) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (name != null) ...[
            Icon(Icons.label_outline, size: 11, color: cs.onSurfaceVariant),
            const SizedBox(width: 2),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    final extras = extraGroupNames(usedNames);
    return PopupMenuButton<String>(
      tooltip: name == null ? '그룹 지정' : '그룹: $name',
      padding: EdgeInsets.zero,
      onSelected: (value) async {
        if (value == _noneValue) return onChanged(null);
        if (value == _customValue) {
          final typed = await showDialog<String>(
            context: context,
            builder: (_) => const _GroupNameDialog(),
          );
          if (typed != null) onChanged(typed);
          return;
        }
        onChanged(value);
      },
      itemBuilder: (_) => [
        for (final n in presetGroupNames) _item(n, name),
        if (extras.isNotEmpty) ...[
          const PopupMenuDivider(),
          for (final n in extras) _item(n, name),
        ],
        const PopupMenuDivider(),
        const PopupMenuItem(value: _customValue, child: Text('직접 입력…')),
        if (name != null)
          const PopupMenuItem(value: _noneValue, child: Text('그룹 없음')),
        const PopupMenuDivider(),
        PopupMenuItem(
          enabled: false,
          height: 28,
          child: Text(
            '같은 이름이 이어진 항목은 한 그룹입니다.',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
      ],
      child: Semantics(
        button: true,
        label: name == null ? '그룹 지정' : '그룹: $name. 눌러서 바꾸기',
        excludeSemantics: true,
        child: Opacity(opacity: dimmed ? 0.6 : 1, child: chip),
      ),
    );
  }

  PopupMenuItem<String> _item(String n, String? current) => PopupMenuItem(
    value: n,
    child: Row(
      children: [
        SizedBox(
          width: 22,
          child: n == current ? const Icon(Icons.check, size: 16) : null,
        ),
        Text(n),
      ],
    ),
  );
}

class _GroupNameDialog extends StatefulWidget {
  const _GroupNameDialog();

  @override
  State<_GroupNameDialog> createState() => _GroupNameDialogState();
}

class _GroupNameDialogState extends State<_GroupNameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = normalizeItemGroup(_controller.text);
    if (name != null) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('그룹 이름'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 12,
        decoration: const InputDecoration(hintText: '예: 특송'),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: normalizeItemGroup(_controller.text) == null
              ? null
              : _submit,
          child: const Text('지정'),
        ),
      ],
    );
  }
}

/// 번호 범위 지정 결과. [name] 이 null 이면 그룹 없음으로 지정.
typedef GroupRange = ({int from, int to, String? name});

/// 콘티 머리줄 '그룹 지정 (번호 범위)'. 취소하면 null.
Future<GroupRange?> showGroupRangeDialog(
  BuildContext context, {
  required int itemCount,
  required Iterable<String> usedNames,
}) => showDialog<GroupRange>(
  context: context,
  builder: (_) => _GroupRangeDialog(itemCount: itemCount, usedNames: usedNames),
);

/// 입력한 범위의 오류 문구. 올바르면 null. (테스트용으로 분리)
String? groupRangeError(int? from, int? to, int itemCount) {
  if (from == null || to == null || from < 1 || to < 1) {
    return '1~$itemCount 사이 번호를 넣어 주세요.';
  }
  if (from > itemCount || to > itemCount) {
    return '1~$itemCount 사이 번호를 넣어 주세요.';
  }
  if (from > to) return '시작 번호는 끝 번호보다 클 수 없습니다.';
  return null;
}

class _GroupRangeDialog extends StatefulWidget {
  const _GroupRangeDialog({required this.itemCount, required this.usedNames});
  final int itemCount;
  final Iterable<String> usedNames;

  @override
  State<_GroupRangeDialog> createState() => _GroupRangeDialogState();
}

class _GroupRangeDialogState extends State<_GroupRangeDialog> {
  final _from = TextEditingController(text: '1');
  final _to = TextEditingController(text: '1');
  final _name = TextEditingController();
  bool _none = false;

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    _name.dispose();
    super.dispose();
  }

  String? get _error => groupRangeError(
    int.tryParse(_from.text.trim()),
    int.tryParse(_to.text.trim()),
    widget.itemCount,
  );
  String? get _groupName => _none ? null : normalizeItemGroup(_name.text);
  bool get _canSubmit => _error == null && (_none || _groupName != null);

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(context).pop((
      from: int.parse(_from.text.trim()),
      to: int.parse(_to.text.trim()),
      name: _groupName,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final error = _error;
    final from = int.tryParse(_from.text.trim());
    final to = int.tryParse(_to.text.trim());
    final names = [...presetGroupNames, ...extraGroupNames(widget.usedNames)];
    return AlertDialog(
      title: const Text('그룹 지정'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _numberField(_from, '시작 번호'),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('~'),
                ),
                _numberField(_to, '끝 번호'),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              enabled: !_none,
              maxLength: 12,
              decoration: const InputDecoration(labelText: '그룹 이름'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final n in names)
                  ActionChip(
                    label: Text(n),
                    visualDensity: VisualDensity.compact,
                    onPressed: _none
                        ? null
                        : () => setState(() => _name.text = n),
                  ),
              ],
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: _none,
              onChanged: (v) => setState(() => _none = v ?? false),
              title: const Text('그룹 없음으로 지정'),
            ),
            const SizedBox(height: 4),
            if (error != null)
              Text(error, style: TextStyle(fontSize: 12, color: cs.error))
            else
              Text(
                _none
                    ? '$from~$to번을 그룹 없음으로 지정합니다.'
                    : '$from~$to번 (곡 ${to! - from! + 1}개)을 "${_name.text.trim()}"으로 지정합니다.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
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
          child: const Text('지정'),
        ),
      ],
    );
  }

  Widget _numberField(TextEditingController c, String label) => Expanded(
    child: TextField(
      controller: c,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
  );
}
