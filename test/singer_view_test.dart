import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/presentation/singer_view_data.dart';

void main() {
  test('싱어 화면 데이터는 현재·다음 페이지와 번호를 싣는다', () {
    const data = SingerViewData(
      current: SingerPage(
        mainText: '주 하나님 지으신 모든 세계',
        englishText: 'O Lord my God',
        title: '주 하나님 지으신 모든 세계',
      ),
      next: SingerPage(mainText: '', title: '주 하나님 지으신 모든 세계'),
      pageNumber: 3,
      totalPages: 20,
      isBlackout: true,
    );

    final json = data.toJson();
    expect(json['page_number'], 3);
    expect(json['total_pages'], 20);
    expect(json['blackout'], isTrue);

    final current = json['current'] as Map<String, dynamic>;
    expect(current['main_text'], '주 하나님 지으신 모든 세계');
    expect(current['english_text'], 'O Lord my God');
    expect(current['image_path'], '');
    expect(current['is_blank'], isFalse);

    // 자동 여백처럼 글자가 없는 페이지는 빈 화면으로 표시한다.
    expect((json['next'] as Map<String, dynamic>)['is_blank'], isTrue);
  });

  test('마지막 페이지면 next 는 null 이고, 이미지 페이지는 빈 화면이 아니다', () {
    const data = SingerViewData(
      current: SingerPage(mainText: '', imagePath: '/tmp/slide_1.png'),
      next: null,
      pageNumber: 1,
      totalPages: 1,
      isBlackout: false,
    );

    final json = data.toJson();
    expect(json['next'], isNull);
    final current = json['current'] as Map<String, dynamic>;
    expect(current['is_blank'], isFalse);
    expect(current['title'], '');
  });
}
