import 'dart:io';

import 'package:flutter/material.dart';

import '../data/libreoffice_installer.dart';

enum _Phase { checking, ready, installing, failed }

/// LibreOffice 가 없을 때 띄우는 안내 + 자동 설치 다이얼로그.
/// 설치까지 끝나면 true 로 닫힌다 — 부른 쪽이 하던 작업을 다시 시도한다.
class LibreOfficeInstallDialog extends StatefulWidget {
  const LibreOfficeInstallDialog({
    super.key,
    required this.reason,
    required this.onOpenDownloadPage,
  });

  /// 왜 필요한지 (".ppt 파일을 읽으려면 …").
  final String reason;
  final VoidCallback onOpenDownloadPage;

  static Future<bool> show(
    BuildContext context, {
    required String reason,
    required VoidCallback onOpenDownloadPage,
  }) async {
    final installed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LibreOfficeInstallDialog(
        reason: reason,
        onOpenDownloadPage: onOpenDownloadPage,
      ),
    );
    return installed ?? false;
  }

  @override
  State<LibreOfficeInstallDialog> createState() =>
      _LibreOfficeInstallDialogState();
}

class _LibreOfficeInstallDialogState extends State<LibreOfficeInstallDialog> {
  _Phase _phase = _Phase.checking;
  LibreOfficePackageManager? _manager;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _findManager();
  }

  Future<void> _findManager() async {
    final manager = await LibreOfficeInstaller.findPackageManager();
    if (!mounted) return;
    setState(() {
      _manager = manager;
      _phase = _Phase.ready;
    });
  }

  Future<void> _install() async {
    final manager = _manager;
    if (manager == null) return;
    setState(() {
      _phase = _Phase.installing;
      _status = '${manager.label}로 설치를 시작합니다…';
    });
    final installed = await LibreOfficeInstaller.install(
      manager,
      onProgress: (line) {
        if (mounted) setState(() => _status = line);
      },
    );
    if (!mounted) return;
    if (installed) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _phase = _Phase.failed);
  }

  @override
  Widget build(BuildContext context) {
    final installing = _phase == _Phase.installing;
    return PopScope(
      canPop: !installing,
      child: AlertDialog(
        title: const Text('LibreOffice가 필요합니다'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.reason),
              const SizedBox(height: 16),
              _buildPhaseBody(context),
            ],
          ),
        ),
        actions: installing ? null : _buildActions(),
      ),
    );
  }

  Widget _buildPhaseBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final manager = _manager;
    switch (_phase) {
      case _Phase.checking:
        return const LinearProgressIndicator();
      case _Phase.ready when manager == null:
        return Text(
          '이 PC에는 자동 설치 도구(${_isWindows ? 'winget' : 'Homebrew'})가 없습니다.\n'
          '다운로드 페이지에서 직접 설치한 뒤 다시 시도해 주세요.',
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        );
      case _Phase.ready:
        return Text(
          '자동 설치를 누르면 ${manager!.label}로 설치합니다. '
          '수백 MB를 내려받으므로 몇 분 걸릴 수 있습니다.'
          '${_isWindows ? '\n"이 앱이 디바이스를 변경하도록 허용" 창이 뜨면 "예"를 눌러 주세요.' : ''}',
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        );
      case _Phase.installing:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              _status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text('설치가 끝날 때까지 이 창을 닫지 마세요.', style: textTheme.bodySmall),
          ],
        );
      case _Phase.failed:
        return Text(
          '설치를 끝내지 못했습니다. 자세한 내용은 로그에 남겼습니다.\n'
          '다시 시도하거나 다운로드 페이지에서 직접 설치해 주세요.',
          style: textTheme.bodyMedium?.copyWith(color: scheme.error),
        );
    }
  }

  List<Widget> _buildActions() {
    return [
      TextButton(
        // 다운로드 페이지에서 직접 설치했을 수도 있으니 닫을 때 한 번 더 확인한다.
        onPressed: () async {
          final installed = await LibreOfficeInstaller.isInstalled();
          if (mounted) Navigator.of(context).pop(installed);
        },
        child: const Text('닫기'),
      ),
      OutlinedButton.icon(
        onPressed: widget.onOpenDownloadPage,
        icon: const Icon(Icons.open_in_new_rounded),
        label: const Text('다운로드 페이지'),
      ),
      if (_manager != null)
        FilledButton.icon(
          onPressed: _install,
          icon: const Icon(Icons.download_rounded),
          label: Text(_phase == _Phase.failed ? '다시 시도' : '자동 설치'),
        ),
    ];
  }

  bool get _isWindows => Platform.isWindows;
}
