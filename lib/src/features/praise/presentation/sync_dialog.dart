import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../app_colors.dart';
import '../data/sync_service.dart';

/// "곡·콘티 동기화" 설정: 공유 폴더 고르기 · 지금 맞추기 · 끄기.
class SyncDialog extends StatelessWidget {
  const SyncDialog({super.key, required this.service});

  final SyncService service;

  static Future<void> show(BuildContext context, SyncService service) =>
      showDialog<void>(
        context: context,
        builder: (_) => SyncDialog(service: service),
      );

  Future<void> _pickFolder() async {
    await FilePicker.skipEntitlementsChecks();
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: '곡을 같이 쓸 공유 폴더 (Google Drive 공유 드라이브 등)',
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
      title: const Text('곡·콘티 동기화'),
      content: SizedBox(
        width: 460,
        child: ValueListenableBuilder<SyncStatus>(
          valueListenable: service.status,
          builder: (context, status, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '여러 PC 가 같은 폴더를 고르면 곡과 저장한 콘티의 추가·수정·삭제가 서로 맞춰집니다. '
                'Google Drive 데스크톱 앱이 PC 에 보여 주는 공유 드라이브 폴더를 고르세요.',
                style: muted,
              ),
              const SizedBox(height: 16),
              _FolderBox(status: status),
              const SizedBox(height: 12),
              _StatusLine(status: status),
              const SizedBox(height: 16),
              Text(
                '· 같은 곡을 두 PC 에서 고치면 나중에 고친 쪽이 남습니다.\n'
                '· 곡을 지우면 다른 PC 에서도 지워집니다(전체 초기화 포함).\n'
                '· 저장한 콘티는 PPT 페이지·배경 이미지까지 같이 넘어갑니다. 동영상·음악 파일은 넘어가지 않습니다.\n'
                '· 앱이 켜져 있는 동안 1분마다, 곡을 고치면 3초 뒤에 맞춥니다.',
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
                FilledButton(
                  onPressed: status.syncing ? null : service.syncNow,
                  child: const Text('지금 동기화'),
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
              status.folder ?? '동기화 꺼짐 — 이 PC 의 곡만 씁니다',
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
    final error = status.lastError;
    final String text;
    if (status.syncing) {
      text = '맞추는 중…';
    } else if (error != null) {
      text = error;
    } else if (status.lastSyncAt == null) {
      text = '아직 맞추지 않았습니다';
    } else {
      final peers = status.peers.isEmpty
          ? '같은 폴더를 쓰는 다른 PC 없음'
          : '다른 PC ${status.peers.length}대: ${status.peers.join(', ')}';
      final pending = status.pendingContis == 0
          ? ''
          : ' · 콘티 ${status.pendingContis}개는 파일이 올라오길 기다리는 중';
      text = '${syncAgo(status.lastSyncAt!)} 맞춤 · $peers$pending';
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
