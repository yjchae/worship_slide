import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/slide_media.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';
import 'package:worship_slides/src/features/praise/presentation/media_player_html.dart';

void main() {
  test('유튜브 주소 모양마다 영상 id 를 꺼낸다', () {
    const id = 'dQw4w9WgXcQ';
    for (final url in [
      'https://www.youtube.com/watch?v=$id&list=PL1',
      'https://m.youtube.com/watch?v=$id',
      'https://youtu.be/$id?si=abc',
      'https://www.youtube.com/shorts/$id',
      'https://www.youtube.com/embed/$id',
      'https://www.youtube.com/live/$id',
      '  https://music.youtube.com/watch?v=$id  ',
    ]) {
      expect(youtubeId(url), id, reason: url);
    }
    for (final url in [
      'https://vimeo.com/123',
      'https://www.youtube.com/watch?v=short',
      'https://www.youtube.com/@channel',
      'not a url',
    ]) {
      expect(youtubeId(url), isNull, reason: url);
    }
  });

  test('유튜브 시작 위치', () {
    expect(youtubeStartSeconds('https://youtu.be/dQw4w9WgXcQ?t=90'), 90);
    expect(youtubeStartSeconds('https://youtu.be/dQw4w9WgXcQ?t=90s'), 90);
    expect(youtubeStartSeconds('https://youtu.be/dQw4w9WgXcQ?t=1h2m3s'), 3723);
    expect(youtubeStartSeconds('https://youtu.be/dQw4w9WgXcQ?start=5'), 5);
    expect(youtubeStartSeconds('https://youtu.be/dQw4w9WgXcQ'), 0);
  });

  test('저장했다 읽으면 그대로, 깨진 값은 null', () {
    const media = SlideMedia(
      kind: MediaKind.video,
      source: '/a/b.mp4',
      fadeIn: 0.5,
      fadeOut: 3,
      rect: [0.1, 0.2, 0.3, 0.4],
    );
    final back = SlideMedia.decode(SlideMedia.encode(media))!;
    expect(back.key, media.key);
    expect(back.fadeIn, 0.5);
    expect(back.fadeOut, 3);
    expect(SlideMedia.decode('{"kind":"tv","source":"x"}'), isNull);
    expect(SlideMedia.decode('not json'), isNull);
    expect(SlideMedia.decode(null), isNull);
    // 페이드는 범위 안으로
    expect(
      SlideMedia.fromJson({'kind': 'audio', 'source': 'x', 'fade_in': 99})!
          .fadeIn,
      SlideMedia.maxFade,
    );
  });

  test('미디어 페이지는 빈 페이지 + 미디어, 제목으로 종류가 보인다', () {
    const item = BlankStagingItem(
      media: SlideMedia(kind: MediaKind.audio, source: r'C:\music\헌금송 MR.mp3'),
    );
    expect(item.displayTitle, '[음악] 헌금송 MR.mp3');
    expect(const BlankStagingItem().displayTitle, '[ 빈 페이지 ]');
  });

  test('플레이어 HTML 에 설정이 그대로 실리고 스크립트가 안 끊긴다', () {
    Map<String, dynamic> config(String html) {
      final m = RegExp(r'var C=(\{.*?\});\n').firstMatch(html)!;
      return jsonDecode(m.group(1)!) as Map<String, dynamic>;
    }

    const tricky = SlideMedia(
      kind: MediaKind.video,
      source: '/x/</script><b>.mp4',
      fadeIn: 1.5,
    );
    final mac = mediaPlayerHtml(tricky, windows: false);
    expect(mac.split('</script>').length, 2); // 끝의 닫는 태그 하나뿐
    expect(config(mac)['src'], Uri.file('/x/</script><b>.mp4').toString());
    expect(config(mac)['fadeIn'], 1.5);

    final win = mediaPlayerHtml(
      const SlideMedia(kind: MediaKind.audio, source: r'D:\곡\a b.mp3'),
      windows: true,
    );
    expect(config(win)['src'], 'https://$kWindowsMediaHost/a%20b.mp3');

    final yt = mediaPlayerHtml(
      const SlideMedia(
        kind: MediaKind.youtube,
        source: 'https://youtu.be/dQw4w9WgXcQ?t=30',
      ),
      windows: false,
    );
    expect(config(yt)['yt'], 'dQw4w9WgXcQ');
    expect(config(yt)['start'], 30);
    expect(config(yt)['src'], isNull);
  });

  test('재생 위치 JSON: 이상한 값은 0, 문자열이 아니면 null', () {
    final p = MediaPlayback.tryParse('{"t":12.5,"d":180,"p":true}')!;
    expect((p.position, p.duration, p.playing), (12.5, 180.0, true));
    final odd = MediaPlayback.tryParse('{"t":-1,"d":null}')!;
    expect((odd.position, odd.duration, odd.playing), (0.0, 0.0, false));
    expect(MediaPlayback.tryParse('nope'), isNull);
    expect(MediaPlayback.tryParse(3), isNull);
  });
}
