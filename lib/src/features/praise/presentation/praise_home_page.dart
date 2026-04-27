import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/export_style_store.dart';
import '../data/praise_repository.dart';
import '../data/python_bridge.dart';
import '../domain/export_style.dart';
import '../domain/praise_song.dart';

class PraiseHomePage extends StatefulWidget {
  const PraiseHomePage({super.key});

  @override
  State<PraiseHomePage> createState() => _PraiseHomePageState();
}

class _PraiseHomePageState extends State<PraiseHomePage> {
  static const ExportStyle _defaultStyle = ExportStyle(
    fontSize: 30,
    backgroundColor: Color(0xFF1B1B1B),
    textColor: Colors.white,
    textPosition: VerticalTextPosition.middle,
    lyricsTextAlign: HorizontalPosition.center,
    includeEnglishLyrics: true,
    englishTextColor: Color(0xFFFFF176),
    showSongTitle: false,
    titleFontSize: 14,
    titleTextColor: Color(0xB3FFFFFF),
    titleHorizontalPosition: HorizontalPosition.right,
    titleVerticalPosition: VerticalTextPosition.bottom,
  );

  final PraiseRepository _repository = PraiseRepository();
  final PythonBridge _pythonBridge = PythonBridge();
  final ExportStyleStore _styleStore = ExportStyleStore();
  final TextEditingController _searchController = TextEditingController();

  List<PraiseSong> _songs = const [];
  final List<PraiseSong> _selectedSongs = [];
  String? _selectedFolder;
  bool _isImporting = false;
  bool _isExporting = false;
  int _storedCount = 0;
  int _importTotalCount = 0;
  int _importSavedCount = 0;
  String? _importStatusText;
  ExportStyle _style = _defaultStyle;

  final List<Color> _swatches = const [
    Color(0xFF1B1B1B),
    Color(0xFF0F4C5C),
    Color(0xFF5F0F40),
    Color(0xFF7A3E00),
    Color(0xFFF4F1EA),
  ];

  final List<Color> _textSwatches = const [
    Colors.white,
    Colors.black,
    Color(0xFFE3F2FD),
    Color(0xFFFFF176),
    Color(0xFFFFCDD2),
  ];

  @override
  void initState() {
    super.initState();
    _loadSongs();
    _loadSavedStyle();
    _searchController.addListener(_loadSongs);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_loadSongs)
      ..dispose();
    super.dispose();
  }

  Future<void> _loadSongs() async {
    // 한글 IME 조합 중에는 건너뜀 — setState가 조합을 끊는 것을 방지
    if (_searchController.value.composing != TextRange.empty) return;
    final songs = await _repository.searchSongs(_searchController.text);
    final storedCount = await _repository.countSongs();
    if (!mounted) {
      return;
    }
    // DB 쿼리 대기 중에 새 조합이 시작됐을 수 있으므로 재확인
    if (_searchController.value.composing != TextRange.empty) return;
    setState(() {
      _songs = songs;
      _storedCount = storedCount;
    });
  }

  Future<void> _loadSavedStyle() async {
    final savedStyle = await _styleStore.load();
    if (!mounted || savedStyle == null) {
      return;
    }
    setState(() {
      _style = savedStyle;
    });
  }

  Future<void> _updateStyle(ExportStyle style) async {
    setState(() {
      _style = style;
    });
    await _styleStore.save(style);
  }

  Future<void> _pickAndImportFolder() async {
    await FilePicker.skipEntitlementsChecks();
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: '찬양 PPT 폴더 선택',
    );
    if (folder == null) {
      return;
    }

    setState(() {
      _selectedFolder = folder;
      _isImporting = true;
      _importTotalCount = 0;
      _importSavedCount = 0;
      _importStatusText = '폴더를 분석하는 중입니다.';
    });

    try {
      final result = await _pythonBridge.importFolder(folder);
      if (!mounted) {
        return;
      }
      setState(() {
        _importTotalCount = result.importedCount;
        _importSavedCount = 0;
        _importStatusText = result.importedCount == 0
            ? '저장할 찬양이 없습니다.'
            : '가져온 찬양을 저장하는 중입니다.';
      });
      if (result.songs.isNotEmpty) {
        await _repository.replaceAllSongs(
          result.songs,
          onSongSaved: (savedCount) async {
            if (!mounted) {
              return;
            }
            setState(() {
              _importSavedCount = savedCount;
              _importStatusText = '찬양을 저장하는 중입니다.';
            });
            await Future<void>.delayed(Duration.zero);
          },
        );
      }
      await _loadSongs();
      if (!mounted) {
        return;
      }
      final message = switch ((result.importedCount, result.failedCount)) {
        (0, 0) => '가져올 PPT/PPTX 파일을 찾지 못했습니다.',
        (> 0, 0) => '${result.importedCount}개의 찬양을 저장했습니다.',
        (0, > 0) =>
          '처리한 ${result.processedCount}개 중 저장된 파일이 없습니다. '
              '첫 오류: ${result.failures.first.fileName}',
        _ =>
          '${result.importedCount}개 저장, ${result.failedCount}개 건너뜀 '
              '(총 ${result.processedCount}개 검사)',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      if (result.libreofficeMissing && mounted) {
        await _showLibreofficeDialog();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('가져오기 실패: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importStatusText = null;
        });
      }
    }
  }

  Future<void> _exportPresentation() async {
    if (_selectedSongs.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('먼저 찬양을 선택해 주세요.')));
      return;
    }

    await FilePicker.skipEntitlementsChecks();
    final outputPath = await FilePicker.saveFile(
      dialogTitle: '저장할 PPTX 파일 선택',
      fileName: 'praise_lyrics.pptx',
      type: FileType.custom,
      allowedExtensions: ['pptx'],
    );

    if (outputPath == null) {
      return;
    }

    setState(() {
      _isExporting = true;
    });

    try {
      final savedPath = await _pythonBridge.exportPresentation(
        outputPath: outputPath,
        songs: _selectedSongs,
        style: _style,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('PPTX 저장 완료: $savedPath')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('PPTX 저장 실패: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  Future<void> _clearAllSongs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('전체 초기화'),
        content: const Text('저장된 찬양 DB를 모두 삭제합니다. 계속할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('전체 삭제'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    await _repository.clearAllSongs();
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedSongs.clear();
    });
    await _loadSongs();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('저장된 찬양을 모두 삭제했습니다.')));
  }

  Future<void> _deleteSelectedSongs() async {
    final deletableIds = _selectedSongs
        .map((song) => song.id)
        .whereType<int>()
        .toList();
    if (deletableIds.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('삭제할 찬양을 먼저 선택해 주세요.')));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('선택 곡 삭제'),
        content: Text('${deletableIds.length}곡을 DB에서 삭제합니다. 계속할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    await _repository.deleteSongsByIds(deletableIds);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedSongs.removeWhere((song) => deletableIds.contains(song.id));
    });
    await _loadSongs();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${deletableIds.length}곡을 삭제했습니다.')));
  }

  Future<void> _openSongEditor(PraiseSong? song) async {
    final result = await showDialog<PraiseSong>(
      context: context,
      builder: (context) => _SongEditDialog(song: song),
    );
    if (result == null || !mounted) return;
    if (song == null) {
      await _repository.insertSong(result);
    } else {
      await _repository.updateSong(result);
    }
    await _loadSongs();
  }

  void _openUrl(String url) {
    if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else if (Platform.isWindows) {
      Process.run('start', [url], runInShell: true);
    } else {
      Process.run('xdg-open', [url]);
    }
  }

  Future<void> _showLibreofficeDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('LibreOffice가 필요합니다'),
        content: const Text(
          '.ppt 파일을 읽으려면 LibreOffice가 설치되어 있어야 합니다.\n\n'
          '.pptx 파일은 LibreOffice 없이도 정상적으로 가져올 수 있습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('닫기'),
          ),
          FilledButton.icon(
            onPressed: () {
              _openUrl(
                'https://www.libreoffice.org/download/download-libreoffice/',
              );
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.download_rounded),
            label: const Text('LibreOffice 다운로드'),
          ),
        ],
      ),
    );
  }

  void _toggleSelection(PraiseSong song, bool isSelected) {
    setState(() {
      if (isSelected) {
        final alreadySelected = _selectedSongs.any(
          (selected) => selected.id == song.id,
        );
        if (!alreadySelected) {
          _selectedSongs.add(song);
        }
      } else {
        _selectedSongs.removeWhere((selected) => selected.id == song.id);
      }
    });
  }

  void _onStagingReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final song = _selectedSongs.removeAt(oldIndex);
      _selectedSongs.insert(newIndex, song);
    });
  }

  void _removeFromStaging(PraiseSong song) {
    setState(() {
      _selectedSongs.removeWhere((s) => s.id == song.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 1120;
              return Flex(
                direction: isWide ? Axis.horizontal : Axis.vertical,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 7,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _TopBar(
                          storedCount: _storedCount,
                          selectedFolder: _selectedFolder,
                          isImporting: _isImporting,
                          importTotalCount: _importTotalCount,
                          importSavedCount: _importSavedCount,
                          importStatusText: _importStatusText,
                          onImportPressed: _pickAndImportFolder,
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: _StagingPanel(
                            selectedSongs: _selectedSongs,
                            onReorder: _onStagingReorder,
                            onRemove: _removeFromStaging,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: _SearchPanel(
                            controller: _searchController,
                            songs: _songs,
                            selectedSongs: _selectedSongs,
                            onChanged: _toggleSelection,
                            onDeleteSelected: _deleteSelectedSongs,
                            onClearAll: _clearAllSongs,
                            onAddSong: () => _openSongEditor(null),
                            onEditSong: _openSongEditor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: isWide ? 20 : 0, height: isWide ? 0 : 20),
                  Expanded(
                    flex: 4,
                    child: _DesignPanel(
                      style: _style,
                      isExporting: _isExporting,
                      swatches: _swatches,
                      textSwatches: _textSwatches,
                      selectedSongs: _selectedSongs,
                      onStyleChanged: _updateStyle,
                      onExportPressed: _exportPresentation,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.storedCount,
    required this.selectedFolder,
    required this.isImporting,
    required this.importTotalCount,
    required this.importSavedCount,
    required this.importStatusText,
    required this.onImportPressed,
  });

  final int storedCount;
  final String? selectedFolder;
  final bool isImporting;
  final int importTotalCount;
  final int importSavedCount;
  final String? importStatusText;
  final VoidCallback onImportPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: const LinearGradient(
          colors: [Color(0xFF143642), Color(0xFF0F8B8D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Text(
            '찬양 가사 보관함',
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '저장 ',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Text(
                  '$storedCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(width: 1, height: 20, color: Colors.white30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  selectedFolder ?? '아직 선택된 폴더가 없습니다.',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                if (importStatusText != null)
                  Text(
                    importTotalCount > 0
                        ? '$importStatusText  $importSavedCount / $importTotalCount'
                        : importStatusText!,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.22),
              foregroundColor: Colors.white,
            ),
            onPressed: isImporting ? null : onImportPressed,
            icon: isImporting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.upload_file_rounded, size: 16),
            label: Text(isImporting ? '읽는 중' : '폴더 선택'),
          ),
        ],
      ),
    );
  }
}

class _SearchPanel extends StatelessWidget {
  const _SearchPanel({
    required this.controller,
    required this.songs,
    required this.selectedSongs,
    required this.onChanged,
    required this.onDeleteSelected,
    required this.onClearAll,
    required this.onAddSong,
    required this.onEditSong,
  });

  final TextEditingController controller;
  final List<PraiseSong> songs;
  final List<PraiseSong> selectedSongs;
  final void Function(PraiseSong song, bool isSelected) onChanged;
  final VoidCallback onDeleteSelected;
  final VoidCallback onClearAll;
  final VoidCallback onAddSong;
  final ValueChanged<PraiseSong> onEditSong;

  @override
  Widget build(BuildContext context) {
    return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '찬양 검색',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text('${songs.length}건'),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: onAddSong,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('새 곡'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: selectedSongs.isEmpty ? null : onDeleteSelected,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('선택 삭제'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: songs.isEmpty ? null : onClearAll,
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: const Text('DB 초기화'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: '제목 또는 가사로 검색',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: songs.isEmpty
                    ? const Center(child: Text('저장된 찬양이 없습니다. 먼저 폴더를 불러와 주세요.'))
                    : ListView.separated(
                        itemCount: songs.length,
                        separatorBuilder: (context, index) =>
                            const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final song = songs[index];
                          final selected = selectedSongs.any(
                            (item) => item.id == song.id,
                          );
                          return CheckboxListTile(
                            value: selected,
                            onChanged: (value) =>
                                onChanged(song, value ?? false),
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(song.title),
                            subtitle: Text(
                              song.pages.join(' / '),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            contentPadding: EdgeInsets.zero,
                            secondary: IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              tooltip: '가사 수정',
                              onPressed: () => onEditSong(song),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
  }
}

class _StagingPanel extends StatelessWidget {
  const _StagingPanel({
    required this.selectedSongs,
    required this.onReorder,
    required this.onRemove,
  });

  final List<PraiseSong> selectedSongs;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(PraiseSong song) onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '선택한 찬양 순서',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                Text('${selectedSongs.length}곡'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: selectedSongs.isEmpty
                  ? const Center(
                      child: Text(
                        '왼쪽에서 찬양을 선택하면 순서가 여기에 표시됩니다.',
                        style: TextStyle(color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: selectedSongs.length,
                      onReorder: onReorder,
                      itemBuilder: (context, index) {
                        final song = selectedSongs[index];
                        return ListTile(
                          key: ValueKey(song.id ?? song.title),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          leading: SizedBox(
                            width: 28,
                            child: Center(
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          title: Text(
                            song.title,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.close_rounded, size: 20),
                                tooltip: '제거',
                                onPressed: () => onRemove(song),
                              ),
                              ReorderableDragStartListener(
                                index: index,
                                child: const Icon(
                                  Icons.drag_handle_rounded,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesignPanel extends StatelessWidget {
  const _DesignPanel({
    required this.style,
    required this.isExporting,
    required this.swatches,
    required this.textSwatches,
    required this.selectedSongs,
    required this.onStyleChanged,
    required this.onExportPressed,
  });

  final ExportStyle style;
  final bool isExporting;
  final List<Color> swatches;
  final List<Color> textSwatches;
  final List<PraiseSong> selectedSongs;
  final ValueChanged<ExportStyle> onStyleChanged;
  final VoidCallback onExportPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PPTX 디자인',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            _PreviewBox(style: style, selectedSongs: selectedSongs),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('글자 크기 ${style.fontSize.toStringAsFixed(0)}'),
                    Slider(
                      min: 18,
                      max: 54,
                      divisions: 9,
                      value: style.fontSize,
                      onChanged: (value) =>
                          onStyleChanged(style.copyWith(fontSize: value)),
                    ),
                    const SizedBox(height: 8),
                    const Text('배경 색상'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: swatches.map((color) {
                        final selected =
                            color.toARGB32() ==
                            style.backgroundColor.toARGB32();
                        return InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () => onStyleChanged(
                            style.copyWith(backgroundColor: color),
                          ),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selected
                                    ? Colors.black
                                    : Colors.grey.shade300,
                                width: selected ? 3 : 1,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),
                    const Text('한글 가사 색상'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: textSwatches.map((color) {
                        final selected =
                            color.toARGB32() == style.textColor.toARGB32();
                        return InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () =>
                              onStyleChanged(style.copyWith(textColor: color)),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selected
                                    ? Colors.black
                                    : Colors.grey.shade300,
                                width: selected ? 3 : 1,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('영어 가사 포함'),
                      value: style.includeEnglishLyrics,
                      onChanged: (value) => onStyleChanged(
                        style.copyWith(includeEnglishLyrics: value),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('영어 가사 색상'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: textSwatches.map((color) {
                        final selected =
                            color.toARGB32() ==
                            style.englishTextColor.toARGB32();
                        return InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () => onStyleChanged(
                            style.copyWith(englishTextColor: color),
                          ),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selected
                                    ? Colors.black
                                    : Colors.grey.shade300,
                                width: selected ? 3 : 1,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),
                    const Text('글자 수직 위치'),
                    const SizedBox(height: 10),
                    SegmentedButton<VerticalTextPosition>(
                      segments: VerticalTextPosition.values
                          .map(
                            (position) => ButtonSegment<VerticalTextPosition>(
                              value: position,
                              label: Text(position.label),
                            ),
                          )
                          .toList(),
                      selected: {style.textPosition},
                      onSelectionChanged: (selection) {
                        onStyleChanged(
                          style.copyWith(textPosition: selection.first),
                        );
                      },
                    ),
                    const SizedBox(height: 14),
                    const Text('글자 수평 정렬'),
                    const SizedBox(height: 10),
                    SegmentedButton<HorizontalPosition>(
                      segments: HorizontalPosition.values
                          .map(
                            (pos) => ButtonSegment<HorizontalPosition>(
                              value: pos,
                              label: Text(pos.label),
                            ),
                          )
                          .toList(),
                      selected: {style.lyricsTextAlign},
                      onSelectionChanged: (selection) {
                        onStyleChanged(
                          style.copyWith(lyricsTextAlign: selection.first),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    const Divider(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('제목 표시'),
                      value: style.showSongTitle,
                      onChanged: (value) =>
                          onStyleChanged(style.copyWith(showSongTitle: value)),
                    ),
                    if (style.showSongTitle) ...[
                      Text('제목 크기 ${style.titleFontSize.toStringAsFixed(0)}'),
                      Slider(
                        min: 8,
                        max: 28,
                        divisions: 10,
                        value: style.titleFontSize,
                        onChanged: (value) =>
                            onStyleChanged(style.copyWith(titleFontSize: value)),
                      ),
                      const SizedBox(height: 4),
                      const Text('제목 색상'),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: textSwatches.map((color) {
                          final selected =
                              color.toARGB32() ==
                              style.titleTextColor.toARGB32();
                          return InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: () => onStyleChanged(
                              style.copyWith(titleTextColor: color),
                            ),
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: selected
                                      ? Colors.black
                                      : Colors.grey.shade300,
                                  width: selected ? 3 : 1,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 14),
                      const Text('제목 수평 위치'),
                      const SizedBox(height: 10),
                      SegmentedButton<HorizontalPosition>(
                        segments: HorizontalPosition.values
                            .map(
                              (pos) => ButtonSegment<HorizontalPosition>(
                                value: pos,
                                label: Text(pos.label),
                              ),
                            )
                            .toList(),
                        selected: {style.titleHorizontalPosition},
                        onSelectionChanged: (selection) => onStyleChanged(
                          style.copyWith(
                            titleHorizontalPosition: selection.first,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text('제목 수직 위치'),
                      const SizedBox(height: 10),
                      SegmentedButton<VerticalTextPosition>(
                        segments: VerticalTextPosition.values
                            .map(
                              (pos) => ButtonSegment<VerticalTextPosition>(
                                value: pos,
                                label: Text(pos.label),
                              ),
                            )
                            .toList(),
                        selected: {style.titleVerticalPosition},
                        onSelectionChanged: (selection) => onStyleChanged(
                          style.copyWith(
                            titleVerticalPosition: selection.first,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: isExporting ? null : onExportPressed,
                icon: isExporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.slideshow_rounded),
                label: Text(isExporting ? '생성 중' : '선택한 찬양으로 PPTX 저장'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewBox extends StatelessWidget {
  const _PreviewBox({required this.style, required this.selectedSongs});

  final ExportStyle style;
  final List<PraiseSong> selectedSongs;

  // PPTX 슬라이드/텍스트박스 치수 (인치) — ppt_tool.py와 동일한 값
  static const double _slideW = 13.333;
  static const double _slideH = 7.5;
  // 가사 텍스트박스 치수
  static const double _lyricsBoxPad = 0.7;
  static const double _lyricsBoxT = 0.6;
  static const double _lyricsBoxH = 5.4;
  static const double _lyricsBoxWFull = 11.9;
  static const double _lyricsBoxWSide = 8.5;
  // 제목 텍스트박스 치수
  static const double _titleBoxH = 0.55;
  static const double _titlePad = 0.2;
  static const double _titleBoxWSide = 5.8;
  static const double _titleBoxWCenter = 10.0;

  @override
  Widget build(BuildContext context) {
    final sampleSong = selectedSongs.isEmpty ? null : selectedSongs.first;
    final sampleText = sampleSong == null
        ? '선택한 찬양이 여기에 미리보기로 보입니다.'
        : sampleSong.pages.isEmpty
        ? sampleSong.title
        : sampleSong.pages.first;
    final sampleEnglishText =
        sampleSong == null || sampleSong.englishPages.isEmpty
        ? ''
        : sampleSong.englishPages.first;

    final alignment = switch (style.textPosition) {
      VerticalTextPosition.top => Alignment.topCenter,
      VerticalTextPosition.middle => Alignment.center,
      VerticalTextPosition.bottom => Alignment.bottomCenter,
    };

    final lyricsTextAlign = switch (style.lyricsTextAlign) {
      HorizontalPosition.left => TextAlign.left,
      HorizontalPosition.center => TextAlign.center,
      HorizontalPosition.right => TextAlign.right,
    };

    final double lyricsBoxL;
    final double lyricsBoxW;
    switch (style.lyricsTextAlign) {
      case HorizontalPosition.left:
        lyricsBoxL = _lyricsBoxPad;
        lyricsBoxW = _lyricsBoxWSide;
      case HorizontalPosition.center:
        lyricsBoxL = _lyricsBoxPad;
        lyricsBoxW = _lyricsBoxWFull;
      case HorizontalPosition.right:
        lyricsBoxL = _slideW - _lyricsBoxPad - _lyricsBoxWSide;
        lyricsBoxW = _lyricsBoxWSide;
    }

    return AspectRatio(
      aspectRatio: _slideW / _slideH,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final fontScale = h / (_slideH * 72);

          // 제목 텍스트박스 위치 계산
          final double titleBoxW;
          final double titleLeft;
          final TextAlign titleAlign;
          switch (style.titleHorizontalPosition) {
            case HorizontalPosition.left:
              titleBoxW = _titleBoxWSide;
              titleLeft = _titlePad;
              titleAlign = TextAlign.left;
            case HorizontalPosition.center:
              titleBoxW = _titleBoxWCenter;
              titleLeft = (_slideW - _titleBoxWCenter) / 2;
              titleAlign = TextAlign.center;
            case HorizontalPosition.right:
              titleBoxW = _titleBoxWSide;
              titleLeft = _slideW - _titlePad - _titleBoxWSide;
              titleAlign = TextAlign.right;
          }
          final double titleTop = switch (style.titleVerticalPosition) {
            VerticalTextPosition.top => _titlePad,
            VerticalTextPosition.middle => (_slideH - _titleBoxH) / 2,
            VerticalTextPosition.bottom =>
              _slideH - _titlePad - _titleBoxH,
          };

          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                // 배경 + 가사
                Container(
                  color: style.backgroundColor,
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: w * lyricsBoxL / _slideW,
                      top: h * _lyricsBoxT / _slideH,
                      right: w * (1 - (lyricsBoxL + lyricsBoxW) / _slideW),
                      bottom: h * (1 - (_lyricsBoxT + _lyricsBoxH) / _slideH),
                    ),
                    child: Align(
                      alignment: alignment,
                      child: DefaultTextStyle(
                        style: const TextStyle(),
                        child: RichText(
                          textAlign: lyricsTextAlign,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: sampleText,
                                style: TextStyle(
                                  color: style.textColor,
                                  fontSize: style.fontSize * fontScale,
                                  fontWeight: FontWeight.w700,
                                  height: 1.25,
                                ),
                              ),
                              if (style.includeEnglishLyrics &&
                                  sampleEnglishText.isNotEmpty)
                                TextSpan(
                                  text: '\n$sampleEnglishText',
                                  style: TextStyle(
                                    color: style.englishTextColor,
                                    fontSize: style.fontSize * 0.8 * fontScale,
                                    fontWeight: FontWeight.w700,
                                    height: 1.3,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 제목 오버레이
                if (style.showSongTitle && sampleSong != null)
                  Positioned(
                    left: w * titleLeft / _slideW,
                    top: h * titleTop / _slideH,
                    width: w * titleBoxW / _slideW,
                    height: h * _titleBoxH / _slideH,
                    child: Text(
                      sampleSong.title,
                      textAlign: titleAlign,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: style.titleTextColor,
                        fontSize: style.titleFontSize * fontScale,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SongEditDialog extends StatefulWidget {
  const _SongEditDialog({this.song});

  final PraiseSong? song;

  @override
  State<_SongEditDialog> createState() => _SongEditDialogState();
}

class _SongEditDialogState extends State<_SongEditDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _lyricsController;
  late final TextEditingController _englishController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.song?.title ?? '');
    // DB의 ### 구분자를 빈 줄로 변환해서 표시 (저장 시 역변환)
    _lyricsController = TextEditingController(
      text: _toEditText(widget.song?.lyrics ?? ''),
    );
    _englishController = TextEditingController(
      text: _toEditText(widget.song?.englishLyrics ?? ''),
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _lyricsController.dispose();
    _englishController.dispose();
    super.dispose();
  }

  // DB 저장용: ### 도 빈 줄로 통일한 뒤, 빈 줄 단위로 페이지 분리
  String _normalizeLyrics(String raw) {
    final unified = raw.replaceAll(RegExp(r'[ \t]*###[ \t]*'), '\n\n');
    return unified
        .split(RegExp(r'\n[ \t]*\n+'))
        .map((page) => page.trim())
        .where((page) => page.isNotEmpty)
        .join('\n###\n');
  }

  // 편집 화면 표시용: ### → 빈 줄
  static String _toEditText(String stored) =>
      stored.replaceAll('\n###\n', '\n\n');

  void _save() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop(
      PraiseSong(
        id: widget.song?.id,
        fileName: widget.song?.fileName ?? title,
        title: title,
        lyrics: _normalizeLyrics(_lyricsController.text),
        englishLyrics: _normalizeLyrics(_englishController.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.song == null;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isNew ? '새 곡 추가' : '가사 수정',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: '제목',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _lyricsController,
                maxLines: 10,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  labelText: '한글 가사',
                  hintText: '페이지 구분: 빈 줄 (또는 ###)',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _englishController,
                maxLines: 10,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  labelText: '영어 가사',
                  hintText: '페이지 구분: 빈 줄 (또는 ###)',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _save,
                    child: Text(isNew ? '추가' : '저장'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
