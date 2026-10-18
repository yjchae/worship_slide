import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app_colors.dart';
import '../data/conti_cloud_repository.dart';
import '../data/sync_service.dart';
import '../domain/worship_conti.dart';

/// 클라우드(공유 폴더)에 올라온 콘티 목록. 골라서 이 PC 로 내려받거나 클라우드에서 지운다.
/// 받은 콘티는 '콘티 불러오기' 목록에 들어간다.
class CloudContiDialog extends StatefulWidget {
  const CloudContiDialog({super.key, required this.service});

  final SyncService service;

  static Future<void> show(BuildContext context, SyncService service) =>
      showDialog<void>(
        context: context,
        builder: (_) => CloudContiDialog(service: service),
      );

  @override
  State<CloudContiDialog> createState() => _CloudContiDialogState();
}

class _CloudContiDialogState extends State<CloudContiDialog> {
  List<CloudConti>? _cloud;
  Map<String, WorshipConti> _local = const {};
  String? _error;

  /// 받거나 지우는 중인 콘티 uid(버튼을 잠깐 막는다).
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final listed = await widget.service.listCloudContis();
      if (!mounted) return;
      setState(() {
        _cloud = listed.cloud;
        _local = listed.local;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cloud = const [];
        _error = '클라우드 콘티를 읽지 못했습니다: $error';
      });
    }
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<bool> _confirm(String title, String body, String ok) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ok),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _download(CloudConti conti) async {
    if (_local.containsKey(conti.uid) &&
        !await _confirm(
          '다시 받기',
          '"${conti.name}" 은(는) 이미 이 PC 에 있습니다. 클라우드의 것으로 바꿀까요?\n'
              '이 PC 의 콘티는 지워지고, 클라우드 판에는 없는 동영상·음악 파일 페이지와 '
              "'원본 열어 수정' 연결이 빠집니다.",
          '바꾸기',
        )) {
      return;
    }
    setState(() => _busy.add(conti.uid));
    try {
      await widget.service.downloadConti(conti);
      if (!mounted) return;
      _snack('"${conti.name}" 콘티를 받았습니다. 콘티 불러오기에서 열 수 있습니다.');
      await _load();
    } catch (error) {
      if (mounted) _snack('받지 못했습니다: ${_message(error)}');
    } finally {
      if (mounted) setState(() => _busy.remove(conti.uid));
    }
  }

  Future<void> _delete(CloudConti conti) async {
    if (!await _confirm(
      '클라우드에서 지우기',
      '"${conti.name}" 을(를) 클라우드에서 지울까요? 이미 받은 PC 의 콘티는 그대로 남습니다.',
      '지우기',
    )) {
      return;
    }
    setState(() => _busy.add(conti.uid));
    try {
      await widget.service.deleteCloudConti(conti);
      await _load();
    } catch (error) {
      if (mounted) _snack('지우지 못했습니다: ${_message(error)}');
    } finally {
      if (mounted) setState(() => _busy.remove(conti.uid));
    }
  }

  static String _message(Object error) =>
      error is FileSystemException ? error.message : '$error';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cloud = _cloud;
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.dialog),
      ),
      title: const Text('클라우드 콘티 내려받기'),
      contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      content: SizedBox(
        width: 480,
        child: cloud == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : cloud.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error ??
                      '클라우드에 올린 콘티가 없습니다.\n'
                          '콘티 불러오기 창에서 콘티 옆 구름 버튼으로 올릴 수 있습니다.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _error == null ? cs.onSurfaceVariant : cs.error,
                  ),
                ),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: cloud.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final conti = cloud[i];
                  final have = _local.containsKey(conti.uid);
                  // 이 PC 가 올린 콘티는 다시 받지 않는다 — 원본(동영상·원본 PPT 연결 포함)이 이 PC 에
                  // 있는데 받으면 그보다 못한 사본으로 바뀐다.
                  final mine =
                      have && conti.uploadedBy == widget.service.deviceName;
                  final busy = _busy.contains(conti.uid);
                  return ListTile(
                    title: Text(
                      conti.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${formatContiDate(conti.createdAt)} · ${conti.itemCount}개 · '
                      '${conti.uploadedBy.isEmpty ? '' : '${conti.uploadedBy} 가 '}'
                      '${formatContiDate(conti.uploadedAt)} 올림'
                      '${mine
                          ? ' · 이 PC 가 올림'
                          : have
                          ? ' · 이 PC 에 있음'
                          : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!mine)
                          IconButton(
                            icon: Icon(
                              have
                                  ? Icons.sync_rounded
                                  : Icons.cloud_download_outlined,
                              size: 20,
                            ),
                            tooltip: have ? '다시 받기(바꾸기)' : '내려받기',
                            onPressed: busy ? null : () => _download(conti),
                          ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 20,
                          ),
                          tooltip: '클라우드에서 지우기',
                          color: cs.error,
                          onPressed: busy ? null : () => _delete(conti),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            setState(() => _cloud = null);
            _load();
          },
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('새로 고침'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}

/// 콘티 목록의 날짜 표시('2026-01-05 10:30'). 콘티 불러오기·클라우드 콘티 창이 같이 쓴다.
String formatContiDate(DateTime dt) =>
    '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
    '${dt.day.toString().padLeft(2, '0')} '
    '${dt.hour.toString().padLeft(2, '0')}:'
    '${dt.minute.toString().padLeft(2, '0')}';
