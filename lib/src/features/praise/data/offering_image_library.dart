import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 헌금송 배경으로 쓸 이미지 모음.
///
/// 등록하면 원본을 Application Support/offering_images/ 로 **복사**한다. 원본이
/// 다운로드 폴더에 있다가 지워지거나 옮겨져도 헌금송 배경이 깨지지 않게 하려는 것.
/// 목록은 따로 저장하지 않고 폴더 안의 파일이 곧 목록이다.
///
/// 이미 구운 헌금송 배경 PNG 는 이 이미지를 합쳐 따로 저장해 두므로, 여기서 이미지를
/// 지워도 저장한 콘티의 헌금송 화면은 그대로다.
class OfferingImageLibrary {
  /// PNG/JPG 만 받는다. 미리보기(Flutter)·Windows 발표 창(GDI+)·PPTX 가 모두
  /// 확실히 읽는 형식이 이 둘이다(항목별 배경과 같은 규칙).
  static const List<String> allowedExtensions = ['png', 'jpg', 'jpeg'];

  Future<Directory> _dir() async {
    final appDir = await getApplicationSupportDirectory();
    return Directory(p.join(appDir.path, 'offering_images'));
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
    await File(sourcePath).copy(target);
    return target;
  }

  /// 모음에서 지운다. 모음 밖의 파일(예전에 직접 고른 원본)은 절대 지우지 않는다.
  Future<void> remove(String path) async {
    final dir = await _dir();
    if (!p.isWithin(dir.path, path)) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  static bool _isAllowed(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return allowedExtensions.contains(ext);
  }
}
