import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 공통 배경 이미지 모음. 헌금송 배경이나 특정 항목(찬양) 배경으로 골라 쓴다.
///
/// 등록하면 원본을 Application Support/offering_images/ 로 **복사**한다. 원본이
/// 다운로드 폴더에 있다가 지워지거나 옮겨져도 배경이 깨지지 않게 하려는 것.
/// (폴더 이름은 헌금송 전용이던 시절 그대로 — 이미 등록한 이미지가 그대로 목록에 뜬다.)
/// 목록은 따로 저장하지 않고 폴더 안의 파일이 곧 목록이다.
///
/// [BackgroundImageLibrary.videos] 는 같은 방식의 배경 영상 모음(`background_videos/`) — 가사 뒤 배경 영상·동영상 페이지가 같이 쓴다.
class BackgroundImageLibrary {
  const BackgroundImageLibrary()
    : _folder = 'offering_images',
      extensions = allowedExtensions,
      isVideo = false;

  const BackgroundImageLibrary.videos()
    : _folder = 'background_videos',
      extensions = videoExtensions,
      isVideo = true;

  /// PNG/JPG 만 받는다. 미리보기(Flutter)·Windows 발표 창(GDI+)·PPTX 가 모두
  /// 확실히 읽는 형식이 이 둘이다.
  static const List<String> allowedExtensions = ['png', 'jpg', 'jpeg'];

  /// WKWebView(macOS)·WebView2(Windows) 가 둘 다 확실히 재생하는 형식.
  static const List<String> videoExtensions = ['mp4', 'm4v', 'mov', 'webm'];

  final String _folder;
  final List<String> extensions;

  final bool isVideo;

  /// 이번 실행에서 썸네일을 못 만든 영상(코덱 없음 등). 격자를 열 때마다 다시 시도하지 않는다.
  static final Set<String> _thumbnailFailed = {};

  static const MethodChannel _channel = MethodChannel(
    'worship_slides/presentation',
  );

  /// 영상 옆에 두는 썸네일 PNG(목록에는 안 잡힌다 — 확장자가 다르다).
  static String thumbnailPath(String video) => '$video.thumb.png';

  /// 등록할 때 붙인 시각(`<ms>_`)을 뗀 이름.
  static String displayName(String path) =>
      p.basename(path).replaceFirst(RegExp(r'^\d{13}_'), '');

  Future<Directory> _dir() async {
    final appDir = await getApplicationSupportDirectory();
    return Directory(p.join(appDir.path, _folder));
  }

  /// 등록된 이미지 경로들. 최근에 등록한 것이 앞.
  Future<List<String>> list() async {
    final dir = await _dir();
    if (!await dir.exists()) return const [];
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File && _isAllowed(entity.path)) files.add(entity);
    }
    final modified = {
      for (final file in files) file.path: (await file.stat()).modified,
    };
    files.sort((a, b) => modified[b.path]!.compareTo(modified[a.path]!));
    return [for (final file in files) file.path];
  }

  /// [sourcePath] 를 모음에 복사하고 복사본 경로를 돌려준다.
  /// 이미 모음 안에 있는 파일이면 그대로 돌려준다.
  Future<String> register(String sourcePath) async {
    final dir = await _dir();
    if (p.isWithin(dir.path, sourcePath)) return sourcePath;
    await dir.create(recursive: true);

    // 같은 이름을 여러 번 등록해도 덮어쓰지 않게 시각을 앞에 붙인다.
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final target = p.join(dir.path, '${stamp}_${p.basename(sourcePath)}');
    // 임시 이름(목록에 안 잡히는 확장자)으로 복사한 뒤 바꾼다 — 큰 영상 복사가 중간에
    // 실패해도 잘린 파일이 모음에 뜨지 않게.
    final part = File('$target.part');
    try {
      await File(sourcePath).copy(part.path);
      await part.rename(target);
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    }
    return target;
  }

  /// 모음에서 지운다. 모음 밖의 파일(예전에 직접 고른 원본)은 절대 지우지 않는다.
  Future<void> remove(String path) async {
    final dir = await _dir();
    if (!p.isWithin(dir.path, path)) return;
    for (final file in [File(path), File(thumbnailPath(path))]) {
      if (await file.exists()) await file.delete();
    }
  }

  /// [video] 의 썸네일 경로. 없으면 OS(macOS AVFoundation·Windows 탐색기 썸네일)로 만든다.
  /// 못 만들면(코덱 없음 등) null — 격자는 아이콘으로 보인다. 실패는 이번 실행 동안 기억한다.
  static Future<String?> thumbnail(String video) async {
    final out = File(thumbnailPath(video));
    if (await out.exists()) {
      if (await out.length() > 0) return out.path;
      await out.delete(); // 쓰다 만 빈 파일
    }
    if (_thumbnailFailed.contains(video) || !await File(video).exists()) {
      return null;
    }
    // 임시 이름에 쓰게 하고 성공했을 때만 바꾼다(쓰다 만 PNG 가 남지 않게).
    final part = File('${out.path}.part');
    try {
      final ok = await _channel.invokeMethod<bool>('videoThumbnail', {
        'path': video,
        'out': part.path,
      });
      if (ok == true && await part.exists() && await part.length() > 0) {
        await part.rename(out.path);
        return out.path;
      }
    } catch (_) {}
    try {
      if (await part.exists()) await part.delete();
    } catch (_) {}
    _thumbnailFailed.add(video);
    return null;
  }

  bool _isAllowed(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return extensions.contains(ext);
  }
}
