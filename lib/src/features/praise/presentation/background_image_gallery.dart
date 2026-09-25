import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/background_image_library.dart';

/// 공통 배경 이미지 모음에서 한 장을 고르는 썸네일 격자.
///
/// 맨 앞 칸은 "없음", 맨 뒤 칸은 "+ 등록". 썸네일에 마우스를 올리면 모음에서 지우는
/// 버튼이 뜬다. 헌금송 디자인 등록과 항목 배경 다이얼로그가 같이 쓴다.
class BackgroundImageGallery extends StatefulWidget {
  const BackgroundImageGallery({
    super.key,
    required this.library,
    required this.selected,
    required this.onChanged,
    this.emptyColor = Colors.black,
  });

  final BackgroundImageLibrary library;
  final String? selected;
  final ValueChanged<String?> onChanged;

  /// "없음" 칸에 칠할 색(배경 색만 쓰는 상태를 보여 준다).
  final Color emptyColor;

  @override
  State<BackgroundImageGallery> createState() => _BackgroundImageGalleryState();
}

class _BackgroundImageGalleryState extends State<BackgroundImageGallery> {
  List<String> _paths = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final paths = await widget.library.list();
    if (mounted) setState(() => _paths = paths);
  }

  Future<void> _register() async {
    await FilePicker.skipEntitlementsChecks();
    final result = await FilePicker.pickFiles(
      dialogTitle: '배경 이미지 등록 (PNG / JPG)',
      type: FileType.custom,
      allowedExtensions: BackgroundImageLibrary.allowedExtensions,
      allowMultiple: true,
    );
    if (result == null) return;
    String? last;
    try {
      for (final file in result.files) {
        if (file.path != null) last = await widget.library.register(file.path!);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('이미지를 등록하지 못했습니다: $e')));
    }
    await _reload();
    if (last != null) widget.onChanged(last);
  }

  Future<void> _remove(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('배경 이미지 삭제'),
        content: const Text(
          '공통 모음에서 이 이미지를 지웁니다.\n'
          '이 이미지를 배경으로 쓰는 항목(저장한 콘티 포함)은 배경 색만 남습니다.\n'
          '이미 적용한 헌금송 화면은 그대로입니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.library.remove(path);
    } catch (_) {
      // 다른 프로그램이 잡고 있으면(Windows) 못 지운다. 목록만 다시 읽는다.
    }
    if (widget.selected == path) widget.onChanged(null);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selected = widget.selected;
    // 모음 밖의 이미지(예전에 직접 고른 원본)도 선택된 상태면 보여 준다.
    final paths = [
      if (selected != null && !_paths.contains(selected)) selected,
      ..._paths,
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _tile(
          context,
          selected: selected == null,
          onTap: () => widget.onChanged(null),
          child: ColoredBox(
            color: widget.emptyColor,
            child: const Center(
              child: Text(
                '없음',
                style: TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ),
          ),
        ),
        for (final path in paths)
          _tile(
            context,
            selected: selected == path,
            onTap: () => widget.onChanged(path),
            onRemove: _paths.contains(path) ? () => _remove(path) : null,
            child: Image.file(
              File(path),
              fit: BoxFit.cover,
              cacheWidth: 192,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined, size: 18),
            ),
          ),
        _tile(
          context,
          selected: false,
          onTap: _register,
          child: Center(
            child: Icon(Icons.add_photo_alternate_outlined, color: cs.primary),
          ),
          tooltip: '이미지 등록',
        ),
      ],
    );
  }

  Widget _tile(
    BuildContext context, {
    required bool selected,
    required VoidCallback onTap,
    required Widget child,
    VoidCallback? onRemove,
    String? tooltip,
  }) {
    final cs = Theme.of(context).colorScheme;
    Widget tile = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 96,
        height: 54,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? cs.primary : Theme.of(context).dividerColor,
            width: selected ? 3 : 1,
          ),
        ),
        child: child,
      ),
    );
    if (onRemove != null) {
      tile = _HoverRemove(onRemove: onRemove, child: tile);
    }
    return tooltip == null ? tile : Tooltip(message: tooltip, child: tile);
  }
}

/// 마우스를 올렸을 때만 오른쪽 위에 삭제 버튼을 띄운다.
class _HoverRemove extends StatefulWidget {
  const _HoverRemove({required this.onRemove, required this.child});

  final VoidCallback onRemove;
  final Widget child;

  @override
  State<_HoverRemove> createState() => _HoverRemoveState();
}

class _HoverRemoveState extends State<_HoverRemove> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        children: [
          widget.child,
          if (_hover)
            Positioned(
              top: 2,
              right: 2,
              child: Tooltip(
                message: '모음에서 삭제',
                child: InkWell(
                  onTap: widget.onRemove,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
