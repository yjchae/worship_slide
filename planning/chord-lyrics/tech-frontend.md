# 코드(기타 코드) 가사 — 프론트엔드 기술 분석

작성: 프론트 개발 관점 / 2026-11-06 / 앱 코드는 고치지 않았다(분석만).
줄 번호는 이 문서를 쓸 때 기준이고 '약'이 붙은 것은 대략이다. 확인 못 한 것은 **미확인**.

기능 요약(전제): 원본 가사 음절 위치에 코드를 넣는다. 편집 표기는 ChordPro 인라인(`[G]주 은[D/F#]혜`).
코드 붙은 원본 가사는 원본 가사(`lyrics`)와 **별도 칸**에 둔다. 코드는 관객 화면(네이티브 발표 창)·PPTX·통역 화면(B)에는
**안 나가고**, 싱어 창(macOS/Windows)·휴대폰 싱어·리모컨·앱 발표 보기에서만 켜고 끈다. 원본 줄에만 붙는다. 항목별 조 바꾸기 가능성.

---

## 0. 핵심 제안 한눈에

| 결정 | 제안 |
|---|---|
| 저장 모양 | `PraiseSong.chordLyrics` = 원본 가사 전체를 ChordPro 로 쓴 글(페이지 구분 `\n\n` 그대로). **불변식: `stripChords(chordLyrics)` 의 페이지 = `lyrics` 의 페이지** |
| 짝짓기 | `pairedPages` 에서 `LyricsPage` 에 `chord` 칸을 더한다. **페이지마다 `strip(chord) == korean` 일 때만** 코드를 쓰고 아니면 `''` (어긋난 페이지는 코드만 조용히 빠진다) |
| 싣는 단계 | `_SlideInfo.chordText`(그 페이지 ChordPro, 조 바꾸기 적용 후) → **`SlidePageData` 에는 싣지 않는다**(관객 JSON 누출 차단) → `SingerPage.chordLines`(파싱된 구조) |
| 보내는 모양 | Dart 가 미리 파싱·조 바꾸기까지 해서 `chord_lines: [{"t":"주 은혜","c":[[0,"G"],[2,"D/F#"]]}, …]` (오프셋 = UTF-16). 렌더러는 파싱·조 계산을 모른다 |
| 그리는 모델 | 세 화면 공통 **"조각 넓히기"**: 줄을 코드 위치에서 조각으로 자르고, 조각 폭 = max(글자 폭, 코드 폭 + 틈). 코드는 조각 위 칸 |
| 발표 보기 | 현재 페이지 큰 화면에만, `SlideRenderView` 의 선택 인자(기본 null)로 **같은 TextPainter 위에 겹쳐** 그린다 → 관객 미리보기 배치·확대·포인터 좌표 그대로. 썸네일·PNG 굽기는 안 그림 |
| 편집 | 가사 수정 창 **원본 열(0번)에 ChordPro 를 그대로** 넣는 '코드 편집' 모드. 4번째 열을 만들지 않는다 → 표 연산이 코드를 글자와 함께 옮긴다 |
| 조 바꾸기 | 순수 함수 `domain/chord_lyrics.dart`, 반음 수는 `PraiseSong.chordTranspose`(콘티 스냅샷) — `copyWith` 가 나누기·복사·옮기기에 저절로 따라가게 |
| 켜고 끄기 | 네이티브 싱어 창 = Dart 설정(끄면 `chord_lines` 를 안 실음), 휴대폰 = **휴대폰마다** 머리줄 버튼(`localStorage`), 발표 보기 = `PresenterViewState.showChords` |

---

## 1. 데이터 흐름

### 1.1 지금 흐름 (읽은 코드)

```
PraiseSong (domain/praise_song.dart)
  lyrics / englishLyrics / extraLyrics  ── pairedPages → List<LyricsPage>  (typedef record: korean·english·extra, 약 2행)
        │                                   (_parsePages: \n[ \t]*\n 로 나눔, 끝의 빈 페이지 뗌)
SongStagingItem(song)  (domain/staging_item.dart) — song 하나만 든다
        │
_allSlides (praise_home_page.dart 약 896행)  ── 곡이면 pairs[j] → _SlideInfo(mainText, englishText, extraText, …)
        │                                       _SlideInfo 정의 약 81행
        ├─ _buildSlidePageData (약 1123행) → SlidePageData → toJson → 네이티브 발표 창(관객)
        ├─ _PresenterConsoleState._pageDataFor (약 13022행) → SlidePageData → ConsoleSlideView → SlideRenderView (발표 보기)
        ├─ SlidePageData.forB (slide_page_data.dart) → 통역 화면
        └─ _buildSingerViewData (약 1291행) → SingerPage(mainText, englishText, title, imagePath)
               → _sendSingerView (약 1992행)
                   ├─ _singerWeb.update({..._buildSingerViewData(slides, true), note, zoom, message})  ← 휴대폰(원본만)
                   └─ _singerDedupeKey 비교 후 invokeMethod('updateSinger', json)                    ← 네이티브 싱어 창
```

곡 페이지를 다시 만드는 곳은 거의 다 **`_songWithPages(song, List<LyricsPage>)`**(약 3821행, `song.copyWith(lyrics: encodePages(...)…)`)
한 곳을 지난다: 발표 보기 페이지 수정(`_applySlideEdit` 약 2230행), 나누기·복사·옮기기(`itemsFromPages` 약 10669행), 지운 페이지 빼기(약 606행).
`LyricsPage` 레코드 리터럴을 만드는 곳은 `pairedPages`(praise_song.dart 약 59행)·`_applySlideEdit`(약 2254행)·테스트(`test/extra_language_test.dart`) 뿐이다.

### 1.2 제안: 어디에 싣는가

1. **`PraiseSong`** 에 두 칸을 더한다.
   - `chordLyrics` (String, 기본 '') — 원본 가사의 ChordPro 판. DB `praise_songs` 새 칸 + 콘티 스냅샷 `worship_conti_items.song_chord_lyrics`(스키마·동기화는 백엔드 문서 몫).
   - `chordTranspose` (int, 기본 0) — 이 콘티 항목에서 올리고 내린 반음 수. 라이브러리 곡엔 0, 콘티 스냅샷에만 의미가 있다(`extraLyrics` 가 DB 엔 없고 스냅샷에만 있는 것과 같은 방식).
   - `copyWith` 에 둘 다 넣는다. `_songWithPages` 가 `copyWith` 라 **조 바꾸기 값은 나누기·복사·옮기기에 손대지 않아도 따라간다.**
   - 조 바꾸기를 `chordLyrics` 글에 **구워 넣지 않는** 이유: 되돌리기(원래 조)·라이브러리 곡과 비교(`_offerStagedSongUpdate`)·동기화 내용 비교가 흐려진다.
     대신 `SongStagingItem` 에 두면 안 된다 — `SongStagingItem(...)` 을 새로 만드는 곳이 많아 빠뜨린다(약 606·2260행 등).
2. **`LyricsPage`** 에 `chord` 칸을 더한다(`({String korean, String english, String extra, String chord})`).
   `pairedPages` 가 `_parsePages(chordLyrics)` 를 같은 인덱스로 짝짓되 **`stripChords(chordPage) == korean` 이 아니면 `chord: ''`**.
   - 이 검사 하나로 "코드 칸과 원본 칸이 어긋남"을 모든 경로에서 막는다: 발표 보기에서 원본 글자를 고친 페이지, 동기화로 다른 PC 가 원본만 고친 곡,
     폴더 다시 가져오기(`addNewSongs`)로 나누기만 바뀐 곡 등 — 그 페이지 코드만 빠지고 나머지는 산다.
   - 비교는 공백 정규화(줄 끝 공백·연속 공백) 후. NFD 한글이 섞인 DB(CLAUDE.md 성경 역본 사례)에 대비해 **양쪽 다 같은 출처 글자**라 합치기는 불필요(미확인: 실제 가사에 NFD 가 있는지).
   - `_songWithPages` 는 `chordLyrics: encodePages(pages.map((p) => p.chord))` 를 더한다. 단 **빈 chord 페이지는 '' 가 아니라 그 페이지 원본 글자(코드 없는 ChordPro)로** 채워야
     페이지 수가 원본과 같게 유지된다 → `encodePages` 는 끝의 빈 페이지를 떼므로 원본이 빈 페이지면 같이 떼어져 정합이 맞는다. 전부 비면 `''`.
   - `_applySlideEdit` 는 `chord: newMain == old.korean ? old.chord : ''`.
3. **`_SlideInfo`** 에 `chordText`(그 페이지 ChordPro, `transposeChordPro(pairs[j].chord, song.chordTranspose)` 적용 후) 한 칸. `_allSlides` 의 곡 분기 한 곳만 채운다. 성경·이미지·빈 페이지·자동 여백은 ''.
4. **`SlidePageData` 에는 넣지 않는다.** `toJson` 이 관객 창·통역 화면(`forB`)·PNG 굽기(`LyricsOverlayRenderer`)로 가는 길이라 실수 한 번이면 관객 화면에 코드가 샌다.
   발표 보기는 `_pageDataFor` 옆에서 `widget.slides[i].chordText` 를 따로 꺼내 넘긴다(2.3절). (`originalOnly` 처럼 "toJson 에 안 싣는 칸"으로 두는 선례가 있긴 하나, `withBackdrop`·`forB` 복사에서 빠뜨리거나 반대로 실을 위험이 있어 권하지 않음.)
5. **`SingerPage`** 에 `chordLines`(List, 기본 null) → JSON `chord_lines`. `_buildSingerViewData.pageAt` 에서 `slide.chordText` 가 있고 그 화면에서 코드를 켰을 때만 `parseChordPro` 결과를 싣는다.
   - 모양: `[{"t": "주 은혜", "c": [[0, "G"], [2, "D/F#"]]}, {"t": "", "c": [[0,"G"],[0,"C"]]} …]` — `t` 는 코드 뺀 줄, `c` 는 (`t` 안 UTF-16 오프셋, 코드 이름). 코드만 있는 줄(간주 `[G] [C] [D]`)은 `t:""`.
   - 이것을 `main_text` 대신 쓴다(`main_text` 는 그대로 둠 — 코드를 모르는 옛 렌더러·끈 상태는 예전처럼). `is_blank` 계산은 그대로.
   - 오프셋을 UTF-16 으로 고정하는 이유: Dart `String`·JS 문자열·Windows `std::wstring` 이 모두 UTF-16 이라 그대로 맞다. **Swift 는 `String.Index`(글자 묶음 단위)가 아니라 `utf16` 뷰/`NSString` 으로 잘라야 한다.**
   - 코드 이름은 Dart 에서 이미 조 바꾸기한 값. 렌더러는 조를 모른다.

### 1.3 ChordPro 파싱 규칙(제안, `domain/chord_lyrics.dart`)

- `[...]` 안이 **코드 문법**(`^[A-G](#|b|♯|♭)?[^/\s]*(/[A-G](#|b)?)?$`)이면 코드, 아니면 **주석 토큰**(`[x2]`·`[후렴]`·`[N.C.]`)으로 보고 조 바꾸기 없이 그대로 코드 칸에 표시(또는 무시 — 기획 결정 필요).
- `stripChords`: 모든 `[...]` 를 지우고, **코드만 있던 줄은 줄째 지운다**(빈 줄로 남기면 페이지 구분이 되어 버린다 — `_parsePages` 는 빈 줄로 나눈다).
- 기존 원본 가사에 원래 `[`·`]` 가 든 곡(PPT 에서 온 `[후렴]` 같은 글)은 ChordPro 로 처음 바꿀 때 `[[`… 같은 이스케이프가 필요하다 — 실제 DB 에 있는지 **미확인**. 처음 코드 편집을 켤 때 `lyrics` 에 `[` 가 있으면 경고하는 정도로 시작.
- 줄 끝 코드(`가사[G]`) = 오프셋 `t.length`.

---

## 2. 렌더링

### 2.0 공통 모델: 조각 넓히기

줄 `[G]주 은[D/F#]혜로` → 조각 `(G,"주 은")`, `(D/F#,"혜로")`. 각 조각은 위 칸 코드 + 아래 칸 글자, **조각 폭 = max(글자 폭, 코드 폭 + 작은 틈)**.
코드가 음절보다 넓으면 가사 사이가 벌어진다(코드 악보 앱들의 흔한 모양). 장점: 겹침이 생기지 않고, 줄 폭을 재기만 하면 기존 "가장 긴 줄에 맞춰 글자 줄이기"가 그대로 돈다.
대안 "코드를 0폭 절대 위치로 띄우고 겹치면 오른쪽으로 밀기"는 가사 간격이 그대로라 예쁘지만, 밀린 코드가 줄 폭 밖으로 나가 맞춤 계산에 안 잡히고(HTML 절대 위치 → `scrollWidth` 반영이 상자마다 다름) GDI 에서 따로 계산해야 해서 세 화면이 달라진다. **세 화면을 같은 산수로 맞추려면 조각 넓히기**를 권한다.

코드 칸 높이: 코드 글자 = 가사의 약 0.6em, 줄마다 코드 칸 약 0.75em 이 더 든다(코드가 하나도 없는 줄은 칸을 안 둔다 — 코드만 있는 줄과 반대). 결과적으로 같은 상자에서 **가사 글자는 약 25~35% 작아진다** — 싱어가 가사도 봐야 하니 휴대폰처럼 사람마다 끄는 스위치가 중요하다.

### 2.1 macOS 싱어 창 / 휴대폰 페이지 (HTML)

현재(읽은 코드):
- macOS `SingerWindowController`(MainFlutterWindow.swift 약 833행~). `update(data:)` 가 **매번 `loadHTMLString` 으로 HTML 통째**(약 953행). `pageHTML`(약 960행)이 `htmlEscape(main_text)` 를 `<div class="main">` 에 넣는다.
  맞춤은 `fitAll()`(약 1033행): 18번 이분 탐색, `.main,.sub{white-space:pre}`, 결과 < `innerHeight*0.035` 면 `.wrap`(pre-wrap + keep-all) 붙여 다시.
- 휴대폰 `singerPageHtml`(singer_web_server.dart 약 571행~): `fill()`(약 659행)이 DOM API(`textContent`)로 같은 구조를 만들고, `fitBox(id, cap)`(약 670행) 같은 규칙 + 다음 페이지 cap = 현재 × 0.75.

제안 마크업(두 곳 같게):
```html
<div class="fit chords">
  <div class="cl"><span class="seg"><b>G</b>주 은</span><span class="seg"><b>D/F#</b>혜로</span></div>
  <div class="cl only"><span class="seg"><b>G</b></span> <span class="seg"><b>C</b></span></div>  <!-- 코드만 있는 줄 -->
  <div class="cl"><span class="seg">코드 없는 줄</span></div>
</div>
```
```css
.cl{white-space:pre}                       /* 원본 줄 그대로 */
.seg{display:inline-flex;flex-direction:column;vertical-align:bottom}
.seg>b{font-size:.6em;color:#7fd1ff;line-height:1.15;min-height:1.15em;padding-right:.35em;white-space:pre}
.cl.nochord .seg>b{display:none}           /* 코드 없는 줄은 칸 안 둠 */
```
- `inline-flex` 열이라 조각 폭 = max(코드, 글자)가 브라우저 레이아웃으로 저절로 나온다. `scrollWidth`·`scrollHeight` 에 그대로 잡히므로 **`fitAll`/`fitBox` 는 고칠 게 없다**(글자 크기 `em` 기준이라 같이 줄어든다).
- **ruby 와 비교**: `<ruby>은<rt>D/F#</rt></ruby>` 는 마크업이 짧지만 ① `rt` 가 base 보다 넓으면 WebKit 이 base 글자를 **양쪽으로 벌려** 음절 간격이 들쭉날쭉(`ruby-align` 제어가 WebKit 에서 제한적 — 미확인), ② 코드는 음절 **왼쪽 시작점**에 붙어야 하는데 ruby 는 가운데 정렬이 기본, ③ 코드 하나가 여러 음절(다음 코드까지)을 덮는 구간 개념이 없다. → **inline-flex 조각 방식 권장**.
- **3.5% 자동 줄바꿈과의 관계**: 기준은 반환되는 가사 글자 크기라 코드 칸이 있어도 그대로 쓸 수 있다. 다만 코드 칸 때문에 3.5% 밑으로 더 자주 떨어진다(긴 줄 + 코드). `.wrap` 일 때 `inline-flex` 조각 사이는 줄바꿈 기회가 생겨 **낱말 가운데(`주 은|혜로`)에서 꺾일 수 있다**(원자 인라인 앞뒤 줄바꿈 기회, `keep-all` 이 막는지 **미확인**). 그래서 Dart 가 줄을 보낼 때 **공백 단위 낱말 묶음**으로 감싸게 한다: `<span class="w">조각…</span>` + 사이 공백 텍스트, `.wrap .w{white-space:nowrap}`. 낱말 안에서는 안 꺾이고 공백에서만 꺾인다. 이 묶음은 렌더러가 `t` 의 공백 위치로 만들 수 있으니 JSON 모양은 그대로.
- 다음 페이지에도 코드를 보일지: 보이는 것을 기본으로(연주자는 다음 코드가 더 필요). cap 0.75 규칙 그대로.
- macOS 는 `loadHTMLString` 이 매번 전체를 다시 읽으므로 크기 증가는 무관. `chord_lines` 를 Swift 에서 HTML 로 만드는 함수 하나(`chordHTML`)가 더해진다 — 이스케이프는 기존 `htmlEscape`. 오프셋 자르기는 `(t as NSString).substring(with:)`.
- 휴대폰 JS 는 `el()` 로 만들어 `textContent` 만 쓰므로 XSS 걱정 없음. 휴대폰 머리줄에 '코드' 버튼(`localStorage singer_chords`, '좌우/위아래' 버튼 `singer_layout` 과 같은 방식). **서버는 늘 실어 보내고 휴대폰이 숨긴다** — 기타 치는 사람과 노래만 하는 사람이 같은 싱어 QR 을 쓰기 때문.
- 대안(공유): Dart 가 escape 된 HTML 조각 `chord_html` 을 만들어 macOS·휴대폰이 그대로 쓰게 하면 HTML 생성이 한 곳이 된다. 그러나 Windows 는 어차피 구조가 필요하고 휴대폰은 `innerHTML` 을 쓰게 되므로 **구조(JSON)만 보내고 렌더러 셋이 각각 그리는 쪽**을 권함.

### 2.2 Windows 싱어 창 (GDI)

현재(windows/runner/singer_window.cpp):
- `Update`(약 213행)가 `main_text`·`english_text` 를 `Page{main, sub, …}`(singer_window.h 약 37행)로 읽는다.
- `PaintText`(약 437행): `Measure`(약 121행, `DrawTextW(DT_CALCRECT [| DT_WORDBREAK])`)로 본문·보조 크기를 재며 이분 탐색, `px < H*3.5%` 면 `wrap=true` 로 다시, 마지막에 **본문 전체를 `DrawTextW(DT_CENTER [| DT_WORDBREAK])` 한 번에** 그린다.

코드를 넣으려면 "블록 한 번에 그리기"를 **줄·조각 단위로 직접 배치**로 바꿔야 한다(코드가 있는 페이지만; 없으면 지금 경로 그대로).
- 측정: 조각마다 `GetTextExtentPoint32W`(가사 글꼴), 코드 글꼴로 코드 폭. 한 줄의 누적 폭이 필요하면 `GetTextExtentExPointW` 한 번으로 글자별 누적 폭 배열을 얻을 수 있다(조각 경계 = 코드 오프셋이라 UTF-16 인덱스 그대로 씀).
- 줄 폭 = Σ max(글자 폭, 코드 폭 + 틈), 줄 높이 = 가사 높이 + (코드 있으면 코드 칸). 이 값으로 기존 이분 탐색 `layout(px)` 의 `fits` 를 계산.
- 그리기: 줄마다 `left = box.left + (bw - lineW)/2`(가운데 정렬), 조각마다 코드 `TextOutW`(코드 글꼴·색) + 가사 `TextOutW`. `SetTextAlign(TA_TOP|TA_LEFT)`·`SetBkMode(TRANSPARENT)` 확인.
- **어려운 점 = 자동 줄바꿈 모드**: 지금은 `DT_WORDBREAK` 에 맡겨 꺾인 위치를 모른다. 코드가 있으면 직접 낱말 단위 탐욕 줄바꿈(공백에서만 꺾고, 낱말 하나가 상자보다 넓으면 그 낱말만 글자 단위)을 짜야 한다. 1차에는 "코드가 있는 페이지는 줄바꿈 안 함, 최소 글자 크기까지 줄이고 넘치면 잘림"으로 시작하고 2차에 줄바꿈을 넣는 것도 방법(긴 성경 구절과 달리 찬양 가사 줄은 짧다).
- 다음 페이지 `dim` 색 규칙에 코드 색도 하나씩(밝은/어두운).
- 난이도: **중간~큼**. 계산 자체는 단순하지만 ① 이 레포 리눅스에서 Windows 를 실행해 볼 수 없고 PR CI 는 컴파일만(CLAUDE.md) → 화면 확인은 사람 몫, ② 기존 블록 그리기와 새 줄 그리기의 세로 정렬·간격(본문 × 0.45 틈)이 같게 맞춰야 한다.
- 대안: 싱어 창 코드 표시를 macOS·휴대폰에 먼저 내고 Windows 는 2차(Windows 사용자는 휴대폰 싱어로 대신). 일정이 빠듯하면 권할 만하다.

### 2.3 Flutter 발표 보기

현재: `_PresenterConsoleState` 의 현재 페이지(약 13477행)·다음 페이지(약 13561행)·썸네일(약 12772행)이 모두 `ConsoleSlideView`(약 10716행) → `SlideRenderView`(slide_render_view.dart). 본문은 `Positioned` 상자 → `Align` → `FittedBox(scaleDown)` → `SizedBox(width)` → `RichText(SlideTextLayout.bodySpan(...))`(약 300~325행) 한 덩어리. 현재 페이지 위에는 `_ZoomRegionOverlay`·포인터가 **슬라이드 좌표**로 얹힌다.

선택지:
- **(A) 같은 글자 배치 위에 겹치기 — 권장.** `SlideRenderView` 에 선택 인자 `chordLines`(기본 null)를 더하고, `RichText` 자리를 `Stack[RichText, CustomPaint]` 로 바꾼다. `CustomPaint` 는 **같은 `bodySpan`·같은 폭·같은 `textAlign`** 으로 `TextPainter` 를 한 번 더 배치해 `getOffsetForCaret(TextPosition(offset: 줄시작+i))` 로 음절 x·줄 top 을 얻고 그 위에 코드를 그린다. `FittedBox` 안이라 축소도 같이 따른다.
  - 장점: 관객 미리보기 배치가 1px 도 안 바뀐다 → 영역 확대·포인터·넘침 경고 그대로. 기본 null 이라 썸네일·`LyricsOverlayRenderer`(가사 PNG 굽기)·`PageComposer`·디자인 미리보기는 영향 없음.
  - 단점: 줄 간격이 본문 `height 1.25`(slide_text_layout.dart `_mainHeight`)라 코드 칸이 없다 → 코드는 **윗줄 아래쪽과 겹친다**. 코드 글자를 작게(본문 0.45배) + 반투명 어두운 바탕 알약으로 그려 읽히게 한다. 첫 줄 코드는 상자 위로 나가므로 `Clip.hardEdge` 안인지 확인 필요(상단 기준 + 미세 조정 0 이면 위 여백 0.6인치가 있어 대개 들어감 — 미확인).
  - 줄 시작 오프셋: `bodySpan` 의 `mainText` 가 첫 TextSpan 이라 원본 글자 오프셋 = 문자열 오프셋. 단 코드만 있는 줄(`t:""`)은 관객 화면에 없는 줄이라 겹칠 자리가 없다 → 다음 줄 앞에 작게 붙이거나 생략.
  - `fitScale`(넘치면 글자 축소) 이 적용된 같은 `fontScale` 을 써야 한다 — `bodySpan` 을 그대로 다시 부르면 맞다.
- (B) '코드 보기'를 켜면 현재 페이지를 싱어식 코드 악보 위젯으로 **바꿔 그리기**. 읽기는 가장 좋지만 발표 보기가 더 이상 관객 화면 미리보기가 아니게 되고 확대·포인터 좌표가 틀린다(현재 슬라이드에 마우스를 올리면 관객 화면에 포인터가 나간다 — `_emitPointer`). 권하지 않음. 굳이 하려면 켠 동안 포인터·확대를 막아야 한다.
- (C) 현재 슬라이드 옆/아래 메모 영역에 작은 '코드 악보' 패널(현재 페이지 `chordLines` 를 싱어식으로)을 따로. 관객 미리보기를 안 건드리는 가장 안전한 길. (A) 가 겹침 때문에 못 읽히면 이쪽.

권장: **(A) 현재 페이지 큰 화면에만**, 토글은 `PresenterViewState.showChords`(탭을 오가도 유지, 기본 끔) + 툴바 버튼. 다음 페이지 작은 상자·썸네일·모든 페이지 격자에는 그리지 않는다(작아서 못 읽고 그릴 때마다 TextPainter 를 한 번 더 돌린다).
- 넘김·조 바꾸기 시 `_PresenterConsole.slides`(=`_SlideInfo` 목록)에 `chordText` 가 이미 들어 있으니 따로 보낼 것 없다.
- 미리보기 코드를 켜도 관객 창·통역·PPTX 는 `SlidePageData.toJson` 을 지나므로 안 바뀐다(1.2-4 결정 덕).

---

## 3. 가사 수정 창 (lyrics_editor_dialog.dart · lyrics_page_grid.dart)

현재: `LyricsPageGrid`(lyrics_page_grid.dart)는 열 3개(0 원본·1 보조·2 추가 보조)의 순수 모델. 연산 `splitCell`(빈 줄로 아래 행 나누기)·`splitAt(row, col, offset)`·`pushDown`·`pullUp`·`mergeWithNext`·`insertRows`(복사 붙여넣기)·`removeRow`. 저장 형식 = 빈 줄 구분 글이라 '통째로' 보기와 오간다.

제안: **원본 열(0번)이 ChordPro 를 그대로 담는 '코드 편집' 모드**(창 머리 토글).
- 켜면 0번 열 시작값 = `song.chordLyrics`(비었으면 `lyrics`). 저장할 때 `lyrics = strip(col0)`, `chordLyrics = col0 에 코드가 하나라도 있으면 col0, 아니면 ''`.
- 이렇게 하면 표 연산은 **글자 연산 그대로** 코드도 같이 옮긴다: 나누기·밀기·당기기·합치기·행 복사/붙여넣기 모두 코드가 자기 음절에 붙은 채 움직인다. 4번째 '코드' 열을 따로 두면 원본 열과 페이지가 어긋나는 순간(밀기·당기기는 열 하나만 옮긴다) 코드가 엉뚱한 페이지로 가므로 **4번째 열은 만들지 않는다.**
- 충돌·주의점:
  1. `splitAt(offset)` — 커서가 `[D/F#]` 안에 있으면 토큰이 둘로 갈린다 → 오프셋을 토큰 앞으로 당기는 처리(그리드에 `snapOutOfChord` 같은 보정, 또는 창에서 오프셋을 넘기기 전에). `splitCell` 은 빈 줄 기준이라 안전. 단 **코드만 있는 줄 바로 앞뒤에 빈 줄**을 넣으면 그 줄이 혼자 한 페이지가 된다 → strip 하면 빈 페이지가 되어 원본에 빈 페이지가 생긴다. 저장 전에 "코드만 있는 페이지"를 경고.
  2. 넘침 측정·행 미리보기(`SlideTextLayout`)·`missingRows`·'번역·변환'(`claude_translator.dart`, 원본 페이지를 Claude 에 넘김)은 **strip 한 글**을 써야 한다. 0번 열 글을 읽는 곳을 모두 `strip` 경유로: 창 안에서 `_originalText(row)` 같은 접근자 하나로 모으는 것을 권함.
  3. 모드를 끈 채(평문) 원본을 고치면: 저장 시 페이지마다 `strip(옛 chord 페이지) == 새 원본 페이지` 인 페이지만 코드를 살리고 나머지는 버린다(1.2-2 와 같은 규칙) + "N 페이지 코드가 지워집니다" 알림. 글자 단위 재정렬(diff 로 코드 옮기기)은 2차.
  4. 코드 입력 편의: 칸 도구에 '코드 넣기'(커서 위치에 `[]` 삽입 후 커서를 안쪽에) 정도. 음절 위에 끌어 놓는 시각 편집기는 큼 — 1차 범위 밖 권장.
  5. `contiOnly`(콘티 곡만 고치기) 모드도 같은 칸을 쓴다 — 결과 song 에 `chordLyrics` 가 실리도록 결과 만드는 곳 확인 필요(약 1480행짜리 파일, 결과 조립 위치 미확인).
  6. 행 복사본이 static 이라 다른 곡에 붙여 넣으면 코드도 같이 간다 — 의도대로.
- `SongEditDialog`(곡 편집 다이얼로그, 통째 편집)와 발표 보기 페이지 수정(`_applySlideEdit`)도 원본을 고친다 → 1.2-2 검사로 그 페이지 코드만 빠진다. 페이지 수정 창에 "이 페이지 코드가 지워집니다" 안내 정도.

---

## 4. 조 바꾸기 순수 함수

위치: **`lib/src/features/praise/domain/chord_lyrics.dart`**(Flutter 의존 없음, `conti_text_parse.dart`·`bible_voice_parse.dart` 처럼). 테스트 `test/chord_lyrics_test.dart`.

함수(제안):
- `ChordProLine parseChordProLine(String)` / `List<ChordProLine> parseChordPro(String page)` — `{text, chords:[(offset, name)]}`, 코드만 있는 줄 표시.
- `String stripChords(String chordPro)` — 코드 지우기 + 코드만 있던 줄 지우기.
- `String transposeChord(String name, int semitones, {bool? preferFlat})`
- `String transposeChordPro(String text, int semitones)` — 코드 토큰만 바꾸고 주석 토큰은 그대로.
- `int? keyOf(String chordPro)`(첫 코드/끝 코드로 조 추정, 표시용 '원래 G → 지금 A').

규칙:
- **근음만 바꾼다**: 맨 앞 `[A-G](#|b)?` 와 `/` 뒤 베이스 `[A-G](#|b)?`. 나머지(`m`, `maj7`, `sus4`, `7(b9)`, `add9`, `dim`, `+`)는 그대로 — 특히 `C7(b9)` 의 `b9` 를 근음으로 보면 안 된다.
- `#`/`b` 선택: 바꾼 뒤의 조가 플랫 조(F, B♭, E♭, A♭, D♭, G♭ / Dm, Gm, Cm, Fm, B♭m, E♭m)면 플랫, 아니면 샵. 조는 곡 첫 코드(또는 마지막 코드)로 추정, 못 하면 원래 코드에 `b` 가 많으면 플랫. `E#`·`B#`·`Cb`·`Fb` 는 내지 않는다.
- 대소문자: 근음은 **대문자만** 코드로 본다. `b` 는 플랫 기호와 겹치므로 소문자 근음(`am`)은 코드가 아니라 주석으로 남긴다(또는 편집 시 대문자로 고치라고 표시). `♯`·`♭` 은 읽을 때 `#`·`b` 로 바꿔 둔다.
- 0 반음·±12 반음은 원래 표기 그대로(±12 는 0 으로 정규화). 범위 −11~+11.
- 테스트 표: `G+2→A`, `D/F#+2→E/G#`, `Bb-1→A`, `F#m+1→Gm`(플랫 조 선호 확인), `C7(b9)+2→D7(b9)`, `Am7/G-2→Gm7/F`, `[x2]` 불변, `[N.C.]` 불변, `[후렴]` 불변, `Ebmaj7+3→F#maj7 또는 Gbmaj7`(조 규칙 확정 후), strip 왕복(`strip(transpose(t)) == strip(t)`), 코드만 있는 줄 strip 시 줄째 사라짐, 페이지 수 보존, UTF-16 오프셋(이모지·NFD 섞인 줄).
- 조 바꾸기 UI: 편집 탭 콘티 항목(찬양) 메뉴 '조 바꾸기 −/+' 와 발표 보기 툴바(현재 항목). 값은 `song.chordTranspose` → `_stagingItems` 갱신 후 **`_sendSingerView()` 를 꼭 불러야** 싱어·휴대폰이 바뀐다(페이지가 안 바뀌어도). 관객 화면은 다시 보낼 필요 없음.

---

## 5. 기존 장치와의 관계

- **`_singerDedupeKey`**(약 1965행): JSON 전체(경과 시간 뺌)를 문자열로 비교하므로 `chord_lines` 가 들어가면 **조 바꾸기·코드 켜기/끄기·코드 수정이 저절로 '바뀜'으로 잡힌다.** 고칠 것 없음. 반대로 디자인 슬라이더를 끌 때는 코드가 안 바뀌어 다시 안 보낸다(지금과 같음).
- **`SingerWebServer.update` / `remoteOnlyKeys`**(singer_web_server.dart 약 42·329행): `chord_lines` 는 `current`·`next` 페이지 안에 실리므로 싱어·리모컨 **둘 다** 받는다 — 요구(싱어·리모컨 모두)와 맞다. `remoteOnlyKeys` 에 넣지 않는다. 서버는 페이지 맵을 `{...page}` 로 복사하고 `image_path` 만 바꾸므로 새 키는 그대로 지나간다. 터널 `/state` 0.5초 폴링 응답이 조금 커지지만(줄당 수십 바이트) 무시할 수준.
- **`_buildSingerViewData(slides, true)`**(원본만): 지금은 `englishText` 만 비운다. 코드는 **원본 줄에 붙는 것**이라 원본만 모드에서도 그대로 싣는다. 휴대폰 쪽 켜고 끄기는 휴대폰 버튼(2.1)이 맡는다.
- 네이티브 싱어 창 켜고 끄기: Dart 쪽 설정(예: 발표 보기 툴바 싱어 버튼 옆 메뉴 '싱어 창에 코드', `screen_choice.json` 이나 `export_style.json` 이 아니라 별도 작은 설정)이 꺼져 있으면 `_buildSingerViewData(slides)` 에서 `chord_lines` 를 안 싣는다 → 휴대폰용 호출과 네이티브용 호출이 이미 따로라(약 1995·1997행) 인자 하나로 갈라진다.
- `SingerPage.isBlank`: 코드만 있고 가사가 빈 페이지는 strip 단계에서 생기지 않게 막았으므로(3-1) 그대로.
- 통역 화면(`forB`)·관객 창: `SlidePageData` 에 코드가 없으니 영향 없음.
- 발표 보기 곡 찾기(가사 범위)·넘침 측정·콘티 한번에 넣기 곡 비교: 모두 `lyrics`/`mainText`(코드 없음)를 보므로 영향 없음.
- `_offerStagedSongUpdate`(라이브러리 곡을 고치면 콘티도 바꿀까): 지금 비교가 가사 기준이면 **코드만 고친 경우 안 묻는다** — 코드만 바뀌어도 물을지 기획 결정 필요(미확인: 비교에 쓰는 칸).
- `.wsconti`·클라우드 콘티: DB 행을 그대로 담으므로 `song_chord_lyrics`·`song_chord_transpose` 칸을 더하면 따라간다(`portableItemRow` 확인 필요). 찬양 동기화 `SyncSong`·내용 해시·'같은 곡 합치기'(제목·원본·영어 같음) 판정에 코드 칸을 넣을지는 백엔드 문서 몫 — 넣지 않으면 두 PC 가 코드만 다르게 고친 같은 곡이 한쪽 코드로 합쳐진다.

---

## 6. 작업량·위험

| 묶음 | 작업량 | 비고 |
|---|---|---|
| `chord_lyrics.dart` 파싱·strip·조 바꾸기 + 테스트 | 작음 | 순수 함수, 리눅스에서 다 검증 가능 |
| `PraiseSong`·`LyricsPage`·`_songWithPages`·`_SlideInfo`·`_applySlideEdit` | 작음~중간 | `LyricsPage` 리터럴은 3곳뿐. 레코드에 칸을 더하면 컴파일러가 빠진 곳을 알려 준다 |
| DB·콘티 스냅샷·`.wsconti`·동기화 | 중간 | 백엔드 문서. 스키마 version 20 + 자동 백업 경로 |
| `SingerPage`/`SingerViewData` + Dart 쪽 켜기 설정 | 작음 | dedupe·서버는 손댈 것 없음 |
| macOS 싱어 HTML + 휴대폰 HTML | 중간 | 같은 CSS 두 벌. 휴대폰은 브라우저로 리눅스에서도 확인 가능, macOS 는 CI 컴파일만 |
| Windows GDI 싱어 | 중간~큼 | 줄·조각 직접 배치 + (2차) 직접 줄바꿈. 실행 확인 불가 |
| Flutter 발표 보기 겹치기 | 중간 | `SlideRenderView` 선택 인자 + CustomPaint. 위젯 테스트로 좌표 확인 가능 |
| 가사 수정 창 코드 모드 | 중간 | 표 연산은 그대로, strip 경유 접근자·오프셋 보정·경고 |
| 조 바꾸기 UI | 작음 | 반드시 `_sendSingerView` |
| **합계** | **큼** (세 플랫폼 렌더러 + 편집기 + 스키마) | macOS·휴대폰 먼저, Windows 2차로 나누면 1차는 중간~큼 |

위험:
1. **코드 칸과 원본 칸 어긋남** — 원본을 고치는 경로가 많다(가사 수정 창·곡 편집·발표 보기 페이지 수정·동기화·다시 가져오기). 페이지마다 `strip(chord)==korean` 검사로 "어긋난 페이지는 코드만 빠짐"을 기본 안전망으로 두지 않으면 엉뚱한 음절에 코드가 붙는다.
2. **관객 화면 누출** — `SlidePageData` 에 코드를 실으면 `toJson`·`forB`·PNG 굽기로 샐 수 있다. 싣지 않는 구조로 막는다.
3. **Windows GDI 는 이 환경에서 화면 확인 불가**(CI 컴파일만) + 자동 줄바꿈을 직접 구현해야 함. macOS Swift 도 실행 확인은 사람 몫.
4. **가사 글자가 작아짐** — 코드 칸이 줄마다 높이를 먹어 싱어 가사가 약 25~35% 작아지고 3.5% 줄바꿈이 더 잦다. 휴대폰마다·싱어 창마다 끄는 스위치가 필수.
5. **오프셋 단위** — Swift `String.Index`(글자 묶음)로 자르면 UTF-16 오프셋과 어긋난다. NFD 자모 가사가 있으면 특히(미확인). 오프셋은 UTF-16 로 못 박고 테스트에 넣는다.
6. 발표 보기 겹치기(A)는 줄 간격 1.25 라 코드가 윗줄과 겹친다 — 읽기 어려우면 (C) 패널로 물러선다.
7. 기존 가사에 `[`·`]` 가 든 곡(미확인)은 ChordPro 로 처음 바꿀 때 주석/코드로 잘못 읽힐 수 있다.
