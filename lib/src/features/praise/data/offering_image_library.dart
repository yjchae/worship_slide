import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 헌금송 배경 이미지 보관소. **한 장만** 둔다.
///
/// 등록하면 원본을 Application Support/offering_images/ 로 **복사**한다. 원본이
/// 다운로드 폴더에 있다가 지워지거나 옮겨져도 헌금송 배경이 깨지지 않게 하려는 것.
/// 새로 등록하면 이전 이미지는 지운다.
///
/// 이미 구운 헌금송 배경 PNG 는 이 이미지를 합쳐 따로 저장해 두므로, 이미지를 바꾸거나
/// 지워도 저장한 콘티의 헌금송 화면은 그대로다.
class OfferingImageLibrary {
  /// PNG/JPG 만 받는다. 미리보기(Flutter)·Windows 발표 창(GDI+)·PPTX 가 모두
  /// 확실히 읽는 형식이 이 둘이다(항목별 배경과 같은 규칙).
  static const List<String> allowedExtensions = ['png', 'jpg', 'jpeg'];

  Future<Directory> _dir() async {
    final appDir = await getApplicationSupportDirectory();
    return Directory(p.join(appDir.path, 'offering_images'));
  }

  /// [sourcePath] 를 보관소에 복사해 등록하고 복사본 경로를 돌려준다.
  ///
  /// 이전 이미지는 여기서 지우지 않는다. 다이얼로그에서 등록만 하고 취소하면 예전 이미지가
  /// 그대로 쓰여야 하므로, 디자인을 저장한 뒤 [keepOnly] 로 정리한다.
  Future<String> register(String sourcePath) async {
    final dir = await _dir();
    if (p.isWithin(dir.path, sourcePath)) return sourcePath;
    await dir.create(recursive: true);

    // 파일 이름에 시각을 넣는다. 같은 이름이면 Flutter 이미지 캐시가 예전 그림을 보여 준다.
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final ext = p.extension(sourcePath).toLowerCase();
    final target = p.join(dir.path, 'background_$stamp$ext');
    await File(sourcePath).copy(target);
    return target;
  }

  /// 저장된 디자인이 쓰는 [keep] 한 장만 남기고 보관소를 비운다(null 이면 전부 지움).
  /// 보관소 밖의 파일(예전에 직접 고른 원본)은 건드리지 않는다.
  Future<void> keepOnly(String? keep) async {
    final dir = await _dir();
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is File && entity.path != keep) {
        try {
          await entity.delete();
        } catch (_) {
          // 다른 프로그램이 잡고 있으면(Windows) 다음 저장 때 다시 지운다.
        }
      }
    }
  }
}
