import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../domain/page_element.dart';
import 'page_rich_text.dart';

/// 편집 창 캔버스 안, 글 상자 자리에 끼우는 편집기(flutter_quill).
///
/// [PageCanvas] 가 그 요소의 글 대신 이 위젯을 같은 `Positioned`/`OverflowBox` 자리에 놓는다.
/// 글자 크기는 pt 그대로 두고 `textScaler`(= [fontScale]) 로 키운다 — Quill 의 `size` 서식이 pt 라서.
/// 줄 높이·간격·목록 기호·정렬은 [PageTextBlock](굽기)과 같은 규칙으로 맞춘다(page_rich_text.dart).
class PageTextEditor extends StatelessWidget {
  const PageTextEditor({
    super.key,
    required this.element,
    required this.fontScale,
    required this.controller,
    required this.focusNode,
    required this.scrollController,
    required this.editorKey,
    required this.onExit,
    required this.onFormat,
  });

  final PageTextElement element;
  final double fontScale;
  final QuillController controller;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final GlobalKey<EditorState> editorKey;

  /// Esc — 편집 끝내기(상자는 고른 채).
  final VoidCallback onExit;

  /// ⌘/Ctrl+B·I·U — 리본과 같은 길(상자 굵게를 아는 쪽이 정한다).
  final ValueChanged<String> onFormat;

  static bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    final e = element;
    final base = TextStyle(
      fontFamily: e.fontFamily,
      fontSize: e.fontSize,
      color: e.color,
      fontWeight: e.bold ? FontWeight.w700 : FontWeight.w400,
    );
    const zero = VerticalSpacing.zero;
    final block = DefaultTextBlockStyle(
      base,
      HorizontalSpacing.zero,
      zero,
      zero,
      null,
    );
    SingleActivator key(LogicalKeyboardKey k, {bool shift = false}) =>
        SingleActivator(k, meta: _mac, control: !_mac, shift: shift);
    return Localizations.override(
      context: context,
      delegates: const [FlutterQuillLocalizations.delegate],
      child: MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(fontScale)),
        child: QuillEditor(
          controller: controller,
          focusNode: focusNode,
          scrollController: scrollController,
          config: QuillEditorConfig(
            editorKey: editorKey,
            // OverflowBox(높이 무한) 안이라 스크롤 뷰를 쓰지 않는다. 넘치면 굽기처럼 아래로 삐져나온다.
            scrollable: false,
            padding: EdgeInsets.zero,
            enableSelectionToolbar: false,
            // 커서는 글자 색(슬라이드 배경 위에서 글이 보이면 커서도 보인다).
            textSelectionThemeData: TextSelectionThemeData(
              cursorColor: e.color,
              selectionColor: Theme.of(
                context,
              ).colorScheme.secondary.withValues(alpha: 0.45),
            ),
            // 리본을 누를 때마다 포커스가 빠지지 않게. 밖 클릭은 편집 창이 정한다.
            onTapOutsideEnabled: false,
            customStyles: DefaultStyles(
              paragraph: block,
              align: block,
              leading: block,
              color: e.color,
              bold: const TextStyle(fontWeight: FontWeight.w700),
              lists: DefaultListBlockStyle(
                base,
                HorizontalSpacing.zero,
                zero,
                zero,
                null,
                null,
                indentWidthBuilder: (block, _, count, _) {
                  final list = block.style.attributes['list']?.value;
                  return HorizontalSpacing(
                    list is String
                        ? pageListIndent(list, count, e.fontSize * fontScale)
                        : 0,
                    0,
                  );
                },
              ),
            ),
            // bold:false = 굵은 상자 안의 보통 글자(Quill 은 키만 보고 굵게 한다).
            customStyleBuilder: (a) => a.key == 'bold' && a.value == false
                ? const TextStyle(fontWeight: FontWeight.w400)
                : const TextStyle(),
            // ignore: experimental_member_use — 목록 기호를 굽기와 같은 위젯으로 그리는 길이 이것뿐이다.
            customLeadingBlockBuilder: (node, config) {
              final list = config.attribute.value;
              if (list != 'bullet' && list != 'ordered') return null;
              final first =
                  (node.toDelta().toJson().firstOrNull as Map?)?['attributes'];
              return pageListMarker(
                element: e,
                fontScale: fontScale,
                list: list as String,
                index: config.index ?? 1,
                firstAttrs: first is Map ? pageInlineAttrs(first) : const {},
              );
            },
            customShortcuts: {
              // Quill 기본(const SingleActivator(escape))과 같은 const 객체면 맵에서 덮여 버린다 —
              // includeRepeats 를 달리 줘 다른 키로 둔다.
              const SingleActivator(
                LogicalKeyboardKey.escape,
                includeRepeats: false,
              ): const _ExitIntent(),
              key(LogicalKeyboardKey.keyB): const _FormatIntent('bold'),
              key(LogicalKeyboardKey.keyI): const _FormatIntent('italic'),
              key(LogicalKeyboardKey.keyU): const _FormatIntent('underline'),
              // Quill 은 다시 하기가 ⌘/Ctrl+Y 뿐이다.
              key(LogicalKeyboardKey.keyZ, shift: true): const _RedoIntent(),
            },
            customActions: {
              _ExitIntent: CallbackAction<_ExitIntent>(
                onInvoke: (_) => onExit(),
              ),
              _FormatIntent: CallbackAction<_FormatIntent>(
                onInvoke: (i) => onFormat(i.key),
              ),
              _RedoIntent: CallbackAction<_RedoIntent>(
                onInvoke: (_) => controller.redo(),
              ),
            },
          ),
        ),
      ),
    );
  }
}

class _ExitIntent extends Intent {
  const _ExitIntent();
}

class _RedoIntent extends Intent {
  const _RedoIntent();
}

class _FormatIntent extends Intent {
  const _FormatIntent(this.key);

  final String key;
}

/// 요소 글 → 편집기 문서. Quill 은 상자 정렬을 모르니 줄마다 `align` 을 넣는다(왼쪽은 기본이라 안 넣음).
/// 돌려받을 때는 [pageRichOf] 가 다시 뺀다 — 저장되는 rich 에는 정렬이 남지 않는다.
Document pageEditorDocument(PageTextElement e) => Document.fromJson(
  pageRichOps(
    pageRichLines(e),
    align: switch (e.align) {
      TextAlign.center => 'center',
      TextAlign.right || TextAlign.end => 'right',
      _ => null,
    },
  ),
);

/// 편집기 문서 → (평문, rich). 받는 서식만 남긴다(rich == null = 서식 없음).
({String text, String? rich}) pageRichOf(Document doc) {
  final lines = pageRichLinesFromOps(doc.toDelta().toJson());
  return (
    text: lines.map((l) => l.text).join('\n'),
    rich: encodePageRich(lines),
  );
}
