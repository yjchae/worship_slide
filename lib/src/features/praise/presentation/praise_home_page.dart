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
    includeEnglishLyrics: true,
    englishTextColor: Color(0xFFFFF176),
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
    final songs = await _repository.searchSongs(_searchController.text);
    final storedCount = await _repository.countSongs();
    if (!mounted) {
      return;
    }
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
                        _Header(
                          storedCount: _storedCount,
                          selectedCount: _selectedSongs.length,
                        ),
                        const SizedBox(height: 20),
                        _ImportPanel(
                          selectedFolder: _selectedFolder,
                          isImporting: _isImporting,
                          importTotalCount: _importTotalCount,
                          importSavedCount: _importSavedCount,
                          importStatusText: _importStatusText,
                          onImportPressed: _pickAndImportFolder,
                        ),
                        const SizedBox(height: 16),
                        _SearchPanel(
                          controller: _searchController,
                          songs: _songs,
                          selectedSongs: _selectedSongs,
                          onChanged: _toggleSelection,
                          onDeleteSelected: _deleteSelectedSongs,
                          onClearAll: _clearAllSongs,
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

class _Header extends StatelessWidget {
  const _Header({required this.storedCount, required this.selectedCount});

  final int storedCount;
  final int selectedCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(24),
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '찬양 가사 보관함',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '폴더 안의 PPT/PPTX를 읽어 SQLite에 저장하고, 원하는 찬양만 골라 새 PPTX로 다시 묶습니다.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _StatBadge(label: '저장된 찬양', value: '$storedCount'),
              _StatBadge(label: '선택한 찬양', value: '$selectedCount'),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatBadge extends StatelessWidget {
  const _StatBadge({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 132,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImportPanel extends StatelessWidget {
  const _ImportPanel({
    required this.selectedFolder,
    required this.isImporting,
    required this.importTotalCount,
    required this.importSavedCount,
    required this.importStatusText,
    required this.onImportPressed,
  });

  final String? selectedFolder;
  final bool isImporting;
  final int importTotalCount;
  final int importSavedCount;
  final String? importStatusText;
  final VoidCallback onImportPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const Icon(Icons.folder_open_rounded, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '찬양 폴더 불러오기',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    selectedFolder ?? '아직 선택된 폴더가 없습니다.',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                  if (importStatusText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      importTotalCount > 0
                          ? '$importStatusText  $importSavedCount / $importTotalCount'
                          : importStatusText!,
                      style: TextStyle(
                        color: Colors.teal.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            FilledButton.icon(
              onPressed: isImporting ? null : onImportPressed,
              icon: isImporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file_rounded),
              label: Text(isImporting ? '읽는 중' : '폴더 선택'),
            ),
          ],
        ),
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
  });

  final TextEditingController controller;
  final List<PraiseSong> songs;
  final List<PraiseSong> selectedSongs;
  final void Function(PraiseSong song, bool isSelected) onChanged;
  final VoidCallback onDeleteSelected;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
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
                          );
                        },
                      ),
              ),
            ],
          ),
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
            const SizedBox(height: 20),
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
                    color.toARGB32() == style.backgroundColor.toARGB32();
                return InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () =>
                      onStyleChanged(style.copyWith(backgroundColor: color)),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Colors.black : Colors.grey.shade300,
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
                final selected = color.toARGB32() == style.textColor.toARGB32();
                return InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => onStyleChanged(style.copyWith(textColor: color)),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Colors.black : Colors.grey.shade300,
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
              onChanged: (value) =>
                  onStyleChanged(style.copyWith(includeEnglishLyrics: value)),
            ),
            const SizedBox(height: 8),
            const Text('영어 가사 색상'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: textSwatches.map((color) {
                final selected =
                    color.toARGB32() == style.englishTextColor.toARGB32();
                return InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () =>
                      onStyleChanged(style.copyWith(englishTextColor: color)),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Colors.black : Colors.grey.shade300,
                        width: selected ? 3 : 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            const Text('글자 위치'),
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
                onStyleChanged(style.copyWith(textPosition: selection.first));
              },
            ),
            const Spacer(),
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

    return Container(
      height: 220,
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: style.backgroundColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Align(
        alignment: alignment,
        child: DefaultTextStyle(
          style: const TextStyle(),
          child: RichText(
            textAlign: TextAlign.center,
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              children: [
                TextSpan(
                  text: sampleText,
                  style: TextStyle(
                    color: style.textColor,
                    fontSize: style.fontSize,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                if (style.includeEnglishLyrics && sampleEnglishText.isNotEmpty)
                  TextSpan(
                    text: '\n$sampleEnglishText',
                    style: TextStyle(
                      color: style.englishTextColor,
                      fontSize: style.fontSize * 0.8,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
