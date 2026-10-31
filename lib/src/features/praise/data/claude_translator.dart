import 'dart:convert';
import 'dart:io';

/// 원본(한글) 가사를 Claude 로 번역하거나 발음을 영어로 옮긴다.
/// API 키 없이 이 PC 에 깔고 로그인해 둔 Claude Code(`claude -p`)를 부른다.
class ClaudeTranslator {
  /// Finder 로 띄운 macOS 앱은 PATH 에 ~/.local/bin·Homebrew 가 없어서 직접 찾는다.
  static String _executable() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    for (final path in [
      '$home/.local/bin/claude',
      '/opt/homebrew/bin/claude',
      '/usr/local/bin/claude',
      '$home\\.local\\bin\\claude.exe',
    ]) {
      if (File(path).existsSync()) return path;
    }
    return 'claude';
  }

  /// 언어 이름에 '발음' 이 들어 있으면 번역이 아니라 한글 발음을 로마자로 옮긴다.
  static bool isPronunciation(String language) => language.contains('발음');

  /// [pages] 와 같은 순서·같은 개수로 돌려준다. 빈 페이지는 그대로 빈 채로 둔다.
  static Future<List<String>> translatePages(
    List<String> pages,
    String language,
  ) async {
    final indexes = [
      for (var i = 0; i < pages.length; i++)
        if (pages[i].trim().isNotEmpty) i,
    ];
    if (indexes.isEmpty) return List.filled(pages.length, '');

    final task = isPronunciation(language)
        ? 'Transliterate each Korean worship-song lyric page into how it sounds, '
              'written in English letters (Revised Romanization, spaced by word, '
              'easy for English speakers to sing along). Do NOT translate the meaning.'
        : 'Translate each Korean worship-song lyric page into $language. '
              'Keep it natural, singable and faithful to Christian worship '
              'vocabulary used by $language-speaking churches. '
              'In Indonesian, always write 하나님 as Tuhan, never Allah.';
    final Process process;
    try {
      // 작업 폴더는 임시 폴더 — 프로젝트의 CLAUDE.md 같은 걸 읽어 들이지 않게.
      process = await Process.start(
        _executable(),
        [
          '-p',
          '$task Return exactly one output page per input page, in the same '
              'order. Keep the same number of lines in each page (line N of the '
              'output matches line N of the input). Output only the lyrics.',
          '--output-format',
          'json',
          '--tools',
          '',
          '--no-session-persistence',
          '--system-prompt',
          'You are a worship lyrics translator.',
          '--json-schema',
          jsonEncode({
            'type': 'object',
            'properties': {
              'pages': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
            'required': ['pages'],
            'additionalProperties': false,
          }),
        ],
        workingDirectory: Directory.systemTemp.path,
        runInShell: Platform.isWindows,
      );
    } on ProcessException {
      throw Exception(
        'Claude Code(claude 명령)를 찾지 못했습니다. 설치하고 터미널에서 한 번 로그인해 주세요.',
      );
    }
    process.stdin.write(
      jsonEncode({
        'pages': [for (final i in indexes) pages[i].trim()],
      }),
    );
    await process.stdin.close();
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        process.kill();
        throw Exception('Claude 응답이 5분 넘게 없어 멈췄습니다.');
      },
    );

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await stdout) as Map<String, dynamic>;
    } on FormatException {
      throw Exception('Claude 실행 실패($code): ${(await stderr).trim()}');
    }
    final structured = body['structured_output'];
    if (body['is_error'] == true || structured is! Map) {
      throw Exception('Claude 오류: ${body['result'] ?? (await stderr).trim()}');
    }
    final out = (structured['pages'] as List).cast<String>();
    if (out.length != indexes.length) {
      throw Exception(
        '페이지 수가 맞지 않습니다(원본 ${indexes.length}, 결과 ${out.length}). 다시 시도해 주세요.',
      );
    }
    final result = List.filled(pages.length, '');
    for (var k = 0; k < indexes.length; k++) {
      result[indexes[k]] = out[k].trim();
    }
    return result;
  }
}
