import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../app_colors.dart';
import '../data/sync_service.dart';

/// "찬양·콘티 동기화" 설정: 공유 폴더 고르기 · 찬양 동기화 · 클라우드 콘티 · 끄기.
/// 동기화는 모두 손으로 한다 — 버튼을 누를 때만 맞춘다.
class SyncDialog extends StatelessWidget {
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

  Future<void> _pickFolder() async {
    await FilePicker.skipEntitlementsChecks();
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: '찬양·콘티를 같이 쓸 공유 폴더 (Google Drive 공유 드라이브 등)',
      initialDirectory: service.status.value.folder,
    );
    if (folder != null) await service.setFolder(folder);
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
          valueListenable: service.status,
          builder: (context, status, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '여러 PC 가 같은 폴더를 고르면 찬양과 콘티를 주고받을 수 있습니다. '
                'Google Drive 데스크톱 앱이 PC 에 보여 주는 공유 드라이브 폴더를 고르세요.',
                style: muted,
              ),
              const SizedBox(height: 16),
              _FolderBox(status: status),
              const SizedBox(height: 12),
              _StatusLine(status: status),
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
          valueListenable: service.status,
          builder: (context, status, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status.enabled)
                TextButton(
                  onPressed: () => service.setFolder(null),
                  child: const Text('동기화 끄기'),
                ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _pickFolder,
                child: Text(status.enabled ? '폴더 바꾸기' : '폴더 고르기'),
              ),
              if (status.enabled) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: onOpenCloudContis,
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  label: const Text('클라우드 콘티'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: status.syncing ? null : onSyncSongs,
                  icon: const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('찬양 동기화'),
                ),
              ],
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
          Icon(
            status.enabled
                ? Icons.folder_shared_rounded
                : Icons.cloud_off_rounded,
            size: 18,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              status.folder ?? '동기화 꺼짐 — 이 PC 의 찬양·콘티만 씁니다',
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
          ? '같은 폴더를 쓰는 다른 PC 없음'
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
