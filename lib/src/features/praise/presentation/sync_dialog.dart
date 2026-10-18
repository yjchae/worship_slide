import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app_colors.dart';
import '../data/sync_service.dart';

/// "찬양·콘티 동기화" 설정: 접속 키 넣기 · 찬양 동기화 · 클라우드 콘티 · 연결 끊기.
/// 동기화는 모두 손으로 한다 — 버튼을 누를 때만 맞춘다.
class SyncDialog extends StatefulWidget {
  const SyncDialog({
    super.key,
    required this.service,
    required this.onSyncSongs,
    required this.onOpenCloudContis,
  });

  final SyncService service;

  /// '찬양 동기화' — 홈 화면이 돌리고 곡 목록을 다시 읽고 결과를 알린다.
  final Future<void> Function() onSyncSongs;

  /// '클라우드 콘티' — 올린 콘티 목록(내려받기) 창을 연다.
  final VoidCallback onOpenCloudContis;

  static Future<void> show(
    BuildContext context, {
    required SyncService service,
    required Future<void> Function() onSyncSongs,
    required VoidCallback onOpenCloudContis,
  }) => showDialog<void>(
    context: context,
    builder: (_) => SyncDialog(
      service: service,
      onSyncSongs: onSyncSongs,
      onOpenCloudContis: onOpenCloudContis,
    ),
  );

  @override
  State<SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<SyncDialog> {
  final _keyController = TextEditingController();
  bool _connecting = false;
  String? _keyError;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _keyError = null;
    });
    try {
      await widget.service.connect(_keyController.text);
      _keyController.clear();
    } on FormatException catch (error) {
      _keyError = error.message;
    } on FileSystemException catch (error) {
      _keyError = error.message;
    } catch (error) {
      _keyError = '$error';
    }
    if (mounted) setState(() => _connecting = false);
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('연결 끊기'),
        content: const Text(
          '이 PC 에서 접속 키를 지웁니다. 드라이브의 찬양·콘티는 그대로 남고, '
          '다시 쓰려면 키를 다시 넣어야 합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('연결 끊기'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.service.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.dialog),
      ),
      title: const Text('찬양·콘티 동기화'),
      content: SizedBox(
        width: 460,
        child: ValueListenableBuilder<SyncStatus>(
          valueListenable: widget.service.status,
          builder: (context, status, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '같은 접속 키를 넣은 PC 끼리 구글 드라이브로 찬양과 콘티를 주고받습니다. '
                '구글 로그인이나 드라이브 앱은 필요 없습니다.',
                style: muted,
              ),
              const SizedBox(height: 16),
              if (status.enabled) ...[
                _FolderBox(status: status),
                const SizedBox(height: 12),
                _StatusLine(status: status),
              ] else ...[
                TextField(
                  controller: _keyController,
                  enabled: !_connecting,
                  minLines: 2,
                  maxLines: 4,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    labelText: '접속 키 (관리자에게 받은 WS1- 로 시작하는 글)',
                    errorText: _keyError ?? status.lastError,
                    errorMaxLines: 3,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _connect(),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                '· 찬양 동기화: 누를 때마다 다른 PC 의 새 찬양·바뀐 찬양을 받고, 이 PC 의 찬양을 올립니다.\n'
                '  같은 곡을 두 PC 에서 고쳤으면 나중에 고친 쪽이 남고, 지운 곡은 다른 PC 에서도 지워집니다.\n'
                '· 콘티: 콘티 불러오기 창에서 하나씩 클라우드에 올리고, 여기서 내려받습니다\n'
                '  (PPT 페이지·배경 이미지까지 같이 갑니다. 동영상·음악 파일은 안 갑니다).\n'
                '· 프로그램을 켤 때 한 번 서버를 보고, 새 찬양이나 콘티가 있으면 알려 드립니다.',
                style: muted.copyWith(height: 1.6),
              ),
            ],
          ),
        ),
      ),
      actions: [
        ValueListenableBuilder<SyncStatus>(
          valueListenable: widget.service.status,
          builder: (context, status, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status.enabled) ...[
                TextButton(
                  onPressed: status.syncing ? null : _disconnect,
                  child: const Text('연결 끊기'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: widget.onOpenCloudContis,
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  label: const Text('클라우드 콘티'),
                ),
                const SizedBox(width: 8),
                if (status.syncing)
                  OutlinedButton.icon(
                    onPressed: widget.service.cancel,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('동기화 취소'),
                  )
                else
                  FilledButton.icon(
                    onPressed: widget.onSyncSongs,
                    icon: const Icon(Icons.sync_rounded, size: 18),
                    label: const Text('찬양 동기화'),
                  ),
              ] else
                FilledButton(
                  onPressed: _connecting ? null : _connect,
                  child: Text(_connecting ? '확인하는 중…' : '연결'),
                ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('닫기'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FolderBox extends StatelessWidget {
  const _FolderBox({required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_done_rounded, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              status.folder ?? '',
              style: TextStyle(fontSize: 13, color: cs.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    if (!status.enabled) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final error = status.lastError ?? status.warning;
    final String text;
    final local = status.hasLocalChanges ? ' · 이 PC 에서 고친 찬양을 아직 안 올렸습니다' : '';
    if (status.syncing) {
      text = '찬양 맞추는 중…';
    } else if (error != null) {
      text = error;
    } else if (status.lastSyncAt == null) {
      text = '이번 실행에서 아직 찬양을 맞추지 않았습니다$local';
    } else {
      final peers = status.peers.isEmpty
          ? '같은 키를 쓰는 다른 PC 없음'
          : '다른 PC ${status.peers.length}대: ${status.peers.join(', ')}';
      text = '${syncAgo(status.lastSyncAt!)} 찬양 맞춤 · $peers$local';
    }
    return Row(
      children: [
        if (status.syncing)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(
            error != null
                ? Icons.error_outline_rounded
                : Icons.check_circle_outline_rounded,
            size: 16,
            color: error != null ? cs.error : cs.primary,
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: error != null ? cs.error : cs.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// "방금 / 3분 전 / 14:05" 같은 짧은 표시. 상태 줄과 다이얼로그가 같이 쓴다.
String syncAgo(DateTime at) {
  final diff = DateTime.now().difference(at);
  if (diff.inMinutes < 1) return '방금';
  if (diff.inHours < 1) return '${diff.inMinutes}분 전';
  final hh = at.hour.toString().padLeft(2, '0');
  final mm = at.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}
