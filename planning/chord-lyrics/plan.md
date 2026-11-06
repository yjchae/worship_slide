# 구현 명세 — 찬양 가사에 코드 넣기 (싱어·발표자 화면 전용)

- 작성일: 2026-11-06 (기획 초안 → QA 검토 [`qa-review.md`](qa-review.md) 반영 → **구현용 최종 명세**)
- 상태: **명세 확정, 구현 전**. 앱 코드는 아직 손대지 않았다
- 근거 문서: [`tech-backend.md`](tech-backend.md) · [`tech-frontend.md`](tech-frontend.md) · [`qa-review.md`](qa-review.md). **이 문서와 다르면 이 문서가 이긴다**
- 화면 목업: [`mockup.html`](mockup.html) · `screens/s1.png`, `s1b.png`, `s1c.png`, `s2.png` ~ `s7.png` (목업 수정 메모는 §2 끝)
- 요청 원문: "찬양 가사 넣을 때 코드도 가사 위치에 넣을 수 있게 하고, 그걸 싱어 화면이나 발표자 화면에서도 볼 수 있게 하고 싶어"

---

## 0. 한눈에 보기

| 항목 | 확정 내용 |
|---|---|
| 목표 | 원본 가사 음절 위에 기타·건반 코드(C, G7, Am/E …)를 얹은 **코드 악보**를 만들고, 발표 중 싱어·발표자 화면에서 켜고 끈다 |
| 편집 표기 | ChordPro 인라인 `[G]주 은[D/F#]혜`. 코드는 **바로 뒤 글자 위**. 무엇이 코드인지는 엄격한 문법 하나(§3-1)로 정한다 |
| 저장 | `praise_songs.lyrics` 는 그대로. 코드 붙은 원본 가사 `chord_lyrics`, 원래 조 `chord_key`, 코드 시각 `chord_updated_at` 을 새 칸으로(DB version 20). 코드는 `saveChords` 로만 쓴다 |
| 기준 | **원본 가사(`lyrics`)가 기준이다.** 코드 글은 자동으로 지우지 않는다. 어긋난 페이지는 표시할 때 숨긴다(§3-5) |
| 보이는 곳 (1차) | **macOS 싱어 창 · 휴대폰 싱어/리모컨 · 앱 발표 보기(발표자 화면)**. 화면마다 따로 켜고 끄며 기본은 끔 |
| Windows 싱어 창 | **2차.** 1차에서는 지금처럼 코드 없이 나오고, Windows 에서는 '싱어 코드' 스위치를 숨긴다. Windows 에서도 휴대폰과 발표 보기는 1차부터 된다 |
| 안 보이는 곳 | 관객 화면(미리보기·macOS·Windows 발표 창), PPTX, 통역 화면(B), 배경 영상 가사 PNG, 썸네일, 편집 페이지 굽기. **`SlidePageData` 에 코드를 싣지 않는다** |
| 언어 | 원본 언어 줄에만 붙는다. 보조·추가 보조 가사에는 코드가 없다 |
| 코드 색 | **`#FFA94D`** (다음 페이지는 `#B07A40`). 조 배지는 중립색 |
| 발표 보기 | **D4-A 확정.** '코드 보기'를 켜면 현재 슬라이드 칸이 코드 악보(따로 만든 `ChordSheetView`)로 바뀌고, 관객 화면은 구석에 작은 그림으로 남는다. 켜져 있는 동안 포인터와 확대는 막는다 |
| 조 바꾸기 | **1차에 포함.** 콘티 항목마다 ±반음과 ♯/♭ 선호를 둔다. 라이브러리 곡은 바뀌지 않는다. 콘티 한번에 넣기가 읽은 조로 자동으로 맞춘다 |
| 동기화 | 스냅샷에 **`chords` 구역**을 따로 둔다. 곡 `updated_at`·`contentKey`·`tieKey` 는 그대로다. 옛 앱은 이 구역을 모르고 지나갈 뿐 코드를 지우지 못한다 |
| 2차 | Windows 싱어 창, 악보 OCR 에서 코드 살리기, ChordPro 파일 가져오기, 코드 악보 인쇄, 카포, 중간 전조 등(§4) |

### 사용자 확정 사항 (2026-11-06)
1. 발표 보기는 **D4-A**: 코드 보기를 켜면 현재 칸이 코드 악보가 되고, 관객 화면은 구석 작은 그림으로 남는다
2. 조 바꾸기는 **1차에 포함**한다
3. 코드 색은 **`#FFA94D`**
4. 1차 범위는 **macOS 싱어 창 · 휴대폰 · 발표 보기**다. **Windows 싱어 창은 2차**로 미루고, 1차에서는 지금처럼 코드 없이 둔다

### 이 명세가 정한 결정 (초안·QA 를 거쳐 확정, 바꾸려면 팀장 확인)

| # | 결정 | 확정 | 이유 |
|---|---|---|---|
| D1 | 코드 저장 위치 | `praise_songs` 에 새 칸을 둔다(`song_translations` 를 쓰지 않음) | 옛 앱 언어 목록에 '코드'가 떠서 관객 화면에 대괄호가 나갈 수 있다. 제목이 키라 편곡끼리 섞인다 |
| D2 | 어긋남 처리 | 저장 데이터는 지우지 않는다. 다시 맞추기는 확실할 때만 자동이다. 표시할 때 페이지마다 검사한다(§3-5) | QA 충돌 3 |
| D3 | 입력 | 인라인 타이핑을 기본으로, 글자 클릭 팝업과 '코드 위 가사' 붙여 넣기 변환을 둔다. 셋 다 1차다 | §2-S1 비교 |
| D5 | 켜기/끄기 | 화면마다 따로, 기본은 끔이다. 휴대폰은 `localStorage` 로 기억하고, 앱 스위치 둘은 **앱 실행 동안만** 기억한다(다음 실행 때 끔) | 보컬과 반주자의 요구가 다르다. 저장소를 늘리지 않는다 |
| D7 | 원래 조 | **지시문을 쓰지 않고 별도 칸 `chord_key`** 에 둔다. 비어 있으면 첫 코드로 추정하고 '(추정)'으로 표시한다 | QA H3 — 지시문은 strip·페이지 짝짓기·표 연산을 모두 깨뜨린다 |
| D8 | 코드만 있는 줄·페이지 | 둘 다 허용한다. 규칙 하나(§3-1 strip 정의)로 처리한다 | QA H6 |
| D9 | 휴대폰 | 코드를 보낸다(원본 줄에 붙으므로). 보조 가사는 계속 뺀다 | |
| D10 | ♯/♭ 선호 | 콘티 항목마다 저장한다(`song_chord_accidental`) | QA 충돌 5 |
| D11 | 대괄호 이스케이프 | 코드 글 안에서 `\[` 는 글자 `[` 를 뜻한다. 가사를 처음 코드 글로 바꿀 때, 코드 문법에 맞는 대괄호에 자동으로 `\` 를 붙인다 | QA H7 — 코드 모드를 켜기만 해도 관객 가사가 바뀌는 일을 막는다 |

---

## 1. 사용자 흐름

### 1-1. 코드 넣기 (평일, 찬양 담당)
1. 검색 결과에서 곡을 열고 '가사 수정'을 누르면 가사 수정 창(페이지 표)이 열린다.
2. 머리줄 **`코드` 스위치**를 켠다. 원본 열 칸의 글이 코드 글로 바뀐다.
   - 처음이면 `escapeLyricsForChords(lyrics)` 로 바꾼다. 원래 가사에 `[A]` 같은 대괄호가 있으면 `\[A]` 로 바꾸고 배너로 알린다: `가사에 원래 있던 대괄호 2개는 글자로 둡니다`.
   - 칸 아래에 코드 악보 미리보기가 뜬다.
3. 넣는 방법은 셋이다.
   - **직접 치기**: 칸에 `[G]` 를 친다. `[` 를 치면 자동완성이 뜬다(이 곡에 쓴 코드, 원래 조의 다이어토닉 코드).
   - **글자 클릭**: 미리보기 글자를 누르면 코드 팝업(S1b)이 뜬다. 그 글자 앞에 `[..]` 가 들어간다. 이미 있는 코드를 누르면 바꾸거나 지울 수 있다.
   - **붙여 넣기**: '코드 줄 + 가사 줄' 꼴 악보를 붙여 넣으면 바꿀지 묻는 배너(S1c)가 뜬다.
4. 머리줄 `원래 조 [G (추정) ▼]` 를 확인한다. 고르면 `chord_key` 에 저장되고 '(추정)'이 사라진다.
5. 저장한다. 다음 경우엔 저장 전에 확인창이 뜬다(저장은 막지 않는다).
   - 코드 문법에 안 맞는 대괄호(`[Gsuss]`)가 있다: "관객 화면에 글자로 나갑니다".
   - 마지막 페이지가 코드뿐이다: "이 페이지 코드는 보이지 않습니다".
6. 저장하면 이렇게 반영된다.
   - `lyrics = stripChords(코드 글)` 이다. 코드만 고쳤으면 `lyrics` 가 한 글자도 안 바뀐다.
   - `saveChords` 가 코드와 원래 조를 저장하고 `chord_updated_at` 을 올린다.
   - 검색 결과 줄에 `코드` 배지가 붙고, 상태 줄에 '동기화 안 한 찬양 있음'이 뜬다.

### 1-2. 콘티 담기
1. 평소처럼 담는다. 담는 순간(`_withSubLyrics` 와 같은 자리) `chordLyrics`·`chordKey` 가 스냅샷으로 들어가고, `chordTranspose = 0`, 표기는 자동이 된다.
2. 콘티 항목 줄에 조 칩 `G` 이 보인다. 칩을 눌러 −/+ 로 바꾸면 `G→A`(S5)가 된다.
3. 콘티 한번에 넣기에서 `3. 주 은혜 A` 처럼 조가 적혀 있으면, 곡에 코드가 있을 때 그 조로 맞춘다(S6, 체크는 기본 켬).
4. 콘티를 저장하면 코드 스냅샷, 조 값, ♯/♭ 선호가 같이 저장된다.
5. 나중에 라이브러리 곡의 코드나 가사를 고치면 '콘티도 바꿀까요'를 묻는다(코드만 고쳐도 묻는다). 바꾸면 코드는 새 값이 되고 **조 값과 ♯/♭ 은 그대로** 남는다(§3-9).

### 1-3. 발표 중 보기
1. 발표 보기 툴바의 마이크 버튼으로 싱어 창을 연다. 그 옆 **`싱어 코드`** 스위치(macOS 만)를 켜면 싱어 창에 코드가 뜬다.
2. 반주자는 휴대폰 QR 로 들어가 머리줄 **`코드`** 버튼을 켠다. 리모컨 키도 같다.
3. 조작자는 현재 슬라이드 칸 머리의 **`코드 보기`** 를 켠다. 칸이 코드 악보로 바뀌고 관객 화면은 구석 작은 그림으로 보인다.
4. 관객 화면과 PPTX 는 아무것도 바뀌지 않는다.

### 1-4. 현장에서 조 바꾸기
1. 발표 보기 오른쪽 칸 '조' 묶음에서 `−` 를 누른다.
2. 싱어 창, 휴대폰, 발표 보기 코드가 바로 바뀐다. 페이지가 그대로여도 `_sendSingerView()` 를 직접 부른다(QA M8). 관객 화면에는 다시 보내지 않는다.
3. 콘티를 저장하면 남는다.

---

## 2. 화면 목록

### S1. 가사 수정 창 — 코드 모드
![가사 수정 코드 모드](screens/s1.png)

**머리줄**
- 곡 제목, 보기 `페이지 표 | 통째로`, **`코드` 스위치**, 저장·취소.
- 코드 모드에선 **`원래 조 [▼]`** 도 보인다. 장조 12개, 단조 12개, '모름'. 값이 비어 있으면 추정값에 '(추정)'을 붙인다.

**원본 열 (코드 모드)**
- 칸 값은 그 페이지의 코드 글이다.
- 코드 토큰은 `#FFA94D` 굵게, `\[` 이스케이프는 회색으로 칠한다.
- 문법에 안 맞는 대괄호는 빨간 물결 밑줄을 긋고, 칸 아래에 `코드로 못 읽음: [Gsuss] — 관객 화면에 글자로 나갑니다` 를 띄운다.
- 대문자로만 고치면 되는 경우(`[g]` → `[G]`, `[am]` → `[Am]`)는 `[고치기]` 버튼을 준다.

**칸 아래 미리보기 띠**
- 원본 칸마다, `ChordSheetView` 작은 크기로 그린다(어두운 바탕).
- 글자에 마우스를 올리면 그 글자 위 자리를 점선으로 보인다. 누르면 S1b 가 뜬다.

**보조·추가 보조 열**
- 그대로다. 코드는 없다.

**칸 도구·행 메뉴**
- 지금과 같다: 당기기, 밀기, 합치기, 나누기, 복사·붙여 넣기.
- 원본 열 값이 코드 글이라 코드가 같이 움직인다(§3-7).

**번역·변환과 넘침 측정**
- 코드 모드에서도 원본 칸은 **`stripChords` 한 글**로 쓴다. Claude 에 대괄호를 넘기지 않는다(QA M6).
- `missingRows` 도 같은 기준이다.

**아래 요약 줄**
- 기존 요약에 `코드 32개 · 코드 없는 페이지 2 · 못 읽음 1` 을 더한다.

**평소 모드 (코드 스위치 끔)**
- 원본 칸에는 가사만 보인다. 곡에 코드가 있으면 칸 왼쪽 위에 `♪` 가 붙는다.
- 이 모드에서 가사를 고치고 저장하면 `realignChords` 를 돌린다.
  - 확실하면(§3-5) 코드도 같이 저장하고 배너를 띄운다: `코드 30개 그대로, 2개 옮김` + `[코드 모드로 보기]`.
  - 확실하지 않으면 코드는 **옛 글 그대로** 둔다. 배너에 `코드 확인 필요 — 가사가 바뀐 페이지 2곳은 코드가 숨겨집니다` + `[다시 맞춘 결과로 바꾸기]` 를 띄운다.

**통째로 보기**
- 코드 모드면 큰 입력칸 하나가 코드 글 전체다.

**입력 방법 비교 (D3)**

| | 인라인 `[G]` | 글자 클릭 팝업 | '코드 위 가사' 변환 |
|---|---|---|---|
| 빠르기 | 가장 빠름 | 코드 하나에 클릭 2~3번 | 이미 있는 악보면 한 번에 |
| 배우기 | 규칙을 알아야 함 | 쉬움 | 쉬움 |
| 정확도 | 글자 단위로 정확 | 정확 | 고정폭 가정이라 비례 글꼴 악보는 어긋날 수 있음 → 미리보기로 확인 |
| 1차 | 기본 | 보조 | 포함(한글 폭 2칸) |

### S1b. 코드 넣기 팝업 (글자 클릭)
![코드 팝업](screens/s1b.png)

- 입력칸 하나. 입력하는 동안 `isChordName` 으로 검사하고, 틀리면 빨간 테두리를 두르고 [넣기] 를 막는다.
- 빠른 버튼 줄: 이 곡에서 쓴 코드를 많이 쓴 순서로, 그 아래 원래 조의 다이어토닉 7개(G 조면 `G Am Bm C D Em F#m7b5`).
- 조립 버튼: 뿌리음 `C D E F G A B`, `♯` `♭`, `m 7 maj7 sus4 add9 dim`, `/베이스`.
- 이미 코드가 있는 글자면 [바꾸기] [지우기].
- 키: Enter 넣기, Esc 닫기, Tab 다음 글자로.

### S1c. '코드 위 가사' 붙여 넣기 배너
![붙여 넣기 변환](screens/s1c.png)

- 붙여 넣은 글에 '코드만 있는 줄 + 바로 아래 가사 줄' 쌍이 **2쌍 이상**이면 배너를 띄운다: `코드 위 가사 형식 같습니다. [코드 표기로 바꾸기] [그대로 두기]`.
- 바꾸면 `chordOverLyricsToInline` 결과가 들어가고 되돌리기 배너가 뜬다.

### S2. macOS 싱어 창 (네이티브)
![싱어 창 코드](screens/s2.png)

- **배치는 지금 그대로다.** 머리줄, 현재 페이지(63%), 다음 페이지(37%).
- 현재 페이지 안은 **원본 덩어리 다음에 보조 덩어리**(`.sub{margin-top:.45em}`)다. 원본 줄과 보조 줄을 엇갈려 그리지 않는다(QA M1).
- '싱어 코드'가 켜져 있고 그 페이지에 `chord_lines` 가 있으면 **원본 덩어리의 줄마다 위에 코드 줄**을 그린다. 수치는 §3-11 표를 따른다.
- 코드 글자가 아래 가사보다 넓으면 가사 사이를 벌린다(뒤 틈 0.4em).
- 머리줄 **조 배지** `A (원래 G, +2)`:
  - 조를 바꿨을 때만 띄운다.
  - **중립색**: 테두리·글자 `#8b95a2`, 바탕 없음.
  - **제목 바로 오른쪽**에 둔다. 시계 옆에 두지 않는다 — 시계 경고 `#ffb547` 과 헷갈리지 않게.
- 코드가 없거나 어긋난 페이지는 지금과 똑같이 그린다. 코드 줄 자리도 두지 않는다.
- 창에는 버튼이 없다. 켜고 끄는 건 발표 보기 툴바에서 한다.
- 구현 위치: `MainFlutterWindow.swift` `SingerWindowController` HTML. 오프셋은 `utf16` 뷰 기준으로 자른다. JS 에서 자르면 원래 UTF-16 이라 그대로 맞는다.

### S3. 휴대폰 싱어 / 발표자 리모컨
![휴대폰 코드](screens/s3.png)

- 머리줄 '좌우/위아래' 버튼 옆에 **`코드`** 버튼을 둔다.
  - `localStorage` `singer_chords` 에 기억하고 기본은 끔이다.
  - 현재·다음 페이지 둘 다 `chord_lines` 가 없으면 흐리게 한다(누를 수는 있다, QA M7).
- 그리는 규칙은 S2 와 같다(같은 JSON 모양, 같은 수치). 다음 페이지도 코드를 포함하고, 0.75배 상한은 그대로다.
- 조 배지도 S2 와 같은 중립색이다. 제목 옆에 둔다.
- 리모컨에서 코드를 켠 채 확대하면 처음 한 번 안내를 띄운다: `코드 줄 때문에 확대 위치가 실제 화면과 조금 다를 수 있어요`.
- 구현 위치: `singer_web_server.dart` `singerPageHtml`.

### S4. 발표 보기 (발표자 화면) — D4-A
![발표 보기 코드](screens/s4.png)

**툴바**
- 마이크 버튼 옆에 **`싱어 코드`** 스위치를 둔다. **macOS 에서만** 보인다.
- 싱어 창이 닫혀 있어도 켤 수 있다. 값은 `PresenterViewState.singerChords` 에 앱 실행 동안만 둔다.

**현재 슬라이드 칸 머리**
- **`코드 보기`** 스위치를 둔다(`PresenterViewState.chordView`).
- 켜고 현재 페이지에 코드가 있으면 칸 안을 `ChordSheetView` 로 그린다. 따로 만든 위젯이고 `SlideRenderView` 에 인자를 더하지 않는다.
  - 배치는 S2 와 같다: 원본 덩어리(코드 줄 포함) 다음에 보조 덩어리.
  - 칸 오른쪽 아래 구석에 관객 화면 작은 그림을 둔다. 폭은 25%이고, 지금 `ConsoleSlideView` 를 **그대로** 쓴다(코드 인자 없음). 누르면 코드 보기가 꺼진다.
- 코드 보기 중에는 이렇게 한다.
  - 영역 확대·포인터 도구를 흐리게 한다.
  - 현재 칸 위의 마우스 이동은 **`_emitPointer` 를 부르지 않는다**. 포인터 모드가 켜진 채 코드 보기를 켜도 관객 화면에 포인터가 안 나간다.
- 코드가 없는 페이지(성경·PPT·빈 페이지, 코드 없는 곡)는 평소 슬라이드로 보인다.

**오른쪽 칸**
- '다음 슬라이드'는 코드 보기가 켜져 있으면 다음 페이지도 `ChordSheetView` 로 그린다.
- **'조' 묶음**은 현재 항목이 코드 있는 곡일 때만 보인다: `원래 G · 지금 A (+2)` `[−] [+] [원래대로]`. 값은 S5 와 같다.
- 버튼은 포커스를 가져가지 않는다. 발표 단축키가 그대로 돈다(리본과 같은 `ExcludeFocus`).

**썸네일·모든 페이지 격자**
- 코드를 그리지 않는다. 코드 있는 곡 항목의 첫 썸네일에 작은 `♪` 배지를 붙인다.

**2순위 대안**
- 써 보니 읽기 어렵거나 조작자가 쓰지 않으면, 현재 칸은 그대로 두고 **오른쪽 칸에 코드 악보 패널**을 두는 방식으로 물러선다. 코드는 같은 `ChordSheetView` 를 쓴다.

### S5. 콘티 항목 조 바꾸기 (편집 탭 콘티 목록)
![조 바꾸기](screens/s5.png)

- 코드 있는 곡 항목에 **조 칩**을 단다.
  - 원래대로면 `G`, 바꿨으면 `G→A`.
  - **중립색**: 테두리 `outline`, 글자 `onSurfaceVariant`. 바꿨을 때만 글자를 굵게 한다. 주황은 쓰지 않는다.
- 칩을 누르면 팝오버가 뜬다.
  - `원래 조  G` 또는 `G (추정)` + `[가사 수정에서 정하기]`
  - `−` `[ A  +2 ]` `+` (−11~+11, 12 는 0 으로 돈다)
  - 결과 조 빠른 고르기 12칸
  - `♯/♭ 표기: 자동 | ♯ | ♭`
  - 첫 페이지 한 줄 미리보기
  - `[원래대로]`
- 같은 곡 항목 둘(n/m)은 따로 바꾼다. 나뉜 곡의 앞·뒤 조각은 나눌 때 값을 이어받고, 그 뒤로는 따로다.
- 어긋난 페이지가 있으면 칩 옆에 `코드 확인 N` 을 붙인다(N = 숨긴 페이지 수).

### S6. 콘티 한번에 넣기 — 조 칸
![콘티 한번에 넣기 조](screens/s6.png)

- 고른 곡 옆에 조 칸을 둔다.
  - 글에 조가 있고 곡에 코드가 있으면 `G → F (−2)` 체크박스(기본 켬).
  - 곡에 코드가 없으면 `F` 만 회색으로 띄우고 적용하지 않는다.
  - 장조·단조가 다르면(원래 G, 글 Em) `Em (원래 G — 직접 맞춰 주세요)` 로 표시만 하고 적용하지 않는다.
- `F-G` 처럼 조가 둘이면 첫 조로 맞추고, 툴팁에 `중간 전조는 직접` 을 띄운다.
- 후보 곡을 바꾸면 조 칸을 다시 계산한다.

### S7. 곡 목록·콘티 목록 배지
![배지](screens/s7.png)

- 검색 결과 곡 줄: `코드` 배지(중립). 코드가 어긋난 곡은 `코드 확인` 배지(주황 경고색 — 이것만 경고).
- 콘티 항목: 조 칩(S5)과 `코드 확인 N`.

### 목업 수정 메모 (구현을 막지는 않음)
- s2·s4 의 원본·보조 엇갈림은 S2 에 적은 대로 **덩어리 배치가 맞다**(M1).
- s1·s2·s3 예시 코드를 하나로 맞춘다. `[Gsus]` 로 고친 상태로 통일하고, +2 결과는 `C#m7 F#m7 Asus E` (M2).
- s1 요약 수 17·배너 수(L1), s1/s1c `Em7` 위치(L2), s5/s7 `코드 확인` 수(L3), s4 버전 표기(L4).
- 조 배지·칩은 중립색이고, 배지는 시계에서 떨어뜨린다(M11).

---

## 3. 데이터 규칙

### 3-1. 코드 문법 — 하나뿐인 정의 (QA H1)

**코드 이름** (`isChordName`, 전체 일치, 대소문자를 가림):

```
CHORD = ^(?:N\.C\.|ROOT QUAL? EXT* (?:/ROOT)?)$
ROOT  = [A-G](?:#|b|♯|♭)?
QUAL  = maj|min|dim|aug|sus2|sus4|sus|m|M|°|ø|\+
EXT   = \d{1,2}
      | (?:add|sus)\d{1,2}
      | [#b♯♭]\d{1,2}
      | \((?:[#b♯♭]?\d{1,2}|maj7|add\d{1,2})(?:,(?:[#b♯♭]?\d{1,2}))*\)
```

Dart 정규식(구현 기준):
```dart
const _root = r'[A-G](?:#|b|♯|♭)?';
const _qual = r'(?:maj|min|dim|aug|sus2|sus4|sus|m|M|°|ø|\+)';
const _ext  = r'(?:\d{1,2}|(?:add|sus)\d{1,2}|[#b♯♭]\d{1,2}|\((?:[#b♯♭]?\d{1,2}|maj7|add\d{1,2})(?:,[#b♯♭]?\d{1,2})*\))';
final chordNamePattern = RegExp('^(?:N\\.C\\.|$_root$_qual?$_ext*(?:/$_root)?)\$');
```

| 대괄호 글 | 판정 |
|---|---|
| `[G]` `[D/F#]` `[Em7]` `[Bb]` `[F#m7b5]` `[Cmaj7]` `[Dsus4]` `[D7sus4]` `[Cadd9]` `[C7(b9)]` `[Am(maj7)]` `[Am7/G]` `[N.C.]` | **코드** |
| `[후렴]` `[Chorus]` `[Bridge]` `[Ending]` `[Coda]` `[Fine]` `[D.S.]` `[x2]` `[Gsuss]` `[g]` `[am]` `[C6/9]` `[H]` `[]` | **가사 글자** — 원본 가사에 그대로 남고 관객 화면에 나간다. 편집 창은 빨간 밑줄, 저장 전 경고를 띄운다(`[g]`·`[am]` 은 `[고치기]`) |

- **코드 토큰** = `[` + 코드 이름 + `]`. 앞에 `\` 가 붙은 `\[` 는 토큰이 아니다.
- 짝 없는 `[`·`]` 와 줄을 넘는 대괄호는 글자다.
- `[[G]]` 은 바깥 `[`·`]` 가 글자이고 안쪽 `[G]` 가 코드다. 경고를 띄운다.

**이스케이프 (D11)**
- 코드 글 안의 두 글자 `\[` 는 **글자 `[`** 다. 그 뒤가 코드처럼 생겨도 코드가 아니다.
- 다른 곳의 `\` 는 그냥 글자다.
- 이스케이프는 코드 글 안에서만 쓴다. `lyrics` 칸은 코드 글로 풀지 않는다.
- `escapeLyricsForChords(lyrics)`: 가사 안에서 **코드 토큰으로 읽힐 `[`** 앞에만 `\` 를 붙인다. 그래서 `stripChords(escapeLyricsForChords(x)) == x` 가 늘 성립한다(테스트로 못 박는다).

**`stripChords(chordText)`** — 코드 글에서 원본 가사를 만드는 유일한 함수다.
1. 줄로 나눈다.
2. 줄마다 코드 토큰을 지우고 `\[` 를 `[` 로 바꾼다.
3. **코드 토큰이 하나 이상 있었는데 지운 뒤 공백만 남은 줄**(코드만 있는 줄)은 줄바꿈째 지운다. 코드가 없던 빈 줄은 그대로 둔다(페이지 구분).
4. 줄 끝 공백을 지운다.
5. `normalizeEditableLyrics` 로 끝의 빈 페이지를 떼고 각 페이지를 trim 한다. 선행 빈 페이지는 남는다.

이 정의에서 나오는 결과:
- 페이지 안의 코드만 있는 줄은 사라진다. 페이지 수는 그대로다.
- **코드만 있는 페이지**(모든 줄이 코드뿐)는 **빈 페이지**가 된다. 앞이나 가운데에 있으면 빈 페이지로 남는다. 관객 화면엔 빈 페이지, 싱어엔 코드만 보인다.
  - 끝에 있으면 5에서 떼어진다. 그 페이지 코드는 짝이 없어 보이지 않는다(편집 창 경고).
- 테스트 예시:

  | 입력 | 결과 |
  |---|---|
  | `가사\n[G] [D]\n\n가사2` | `가사\n\n가사2` |
  | `[G] [D]\n\n가사` | `\n\n가사`(선행 빈 페이지 하나) |
  | `가사\n\n[G] [D]` | `가사` |
  | `[G]주 \[A]` | `주 [A]` |

**코드 위치**
- 코드는 토큰 뒤 첫 글자 위에 뜬다. 오프셋은 **strip 한 줄 안의 UTF-16 오프셋**이다.
- 줄 끝 코드(`주님[G]`)는 오프셋 = 줄 길이이고, 마지막 글자 오른쪽에 뜬다.
- 연달아 쓴 `[G][D]주` 는 같은 오프셋에 둘이고, 나란히 `G D` 로 그린다.
- 공백 앞 코드(`[G] 주`)는 공백 위에 뜬다.

### 3-2. 잘못된 표기 처리 요약
| 경우 | 데이터 | 화면 |
|---|---|---|
| 문법 밖 대괄호 | 글자로 저장한다(관객에게 나감) | 편집 창: 빨간 밑줄, 요약 `못 읽음 N`, 저장 전 확인 |
| 마지막 페이지가 코드뿐 | 그대로 저장한다 | 그 페이지 코드는 안 보인다. 저장 전 확인 |
| 코드 이름 대소문자만 틀림 | 글자 | `[고치기]` 제안 |
| `chord_key` 가 장·단조 24개 밖 | 무시한다(추정으로) | — |

### 3-3. 저장 칸·JSON 이름 대조표 (QA 충돌 5 — 이 표가 유일한 기준)

| 대상 | 이름 | 타입·값 | 비고 |
|---|---|---|---|
| 곡 코드 글 | `praise_songs.chord_lyrics` | TEXT, **NULL = 코드 없음** | 빈 문자열은 쓰지 않는다. 저장할 때 `''` 를 NULL 로 바꾼다 |
| 곡 원래 조 | `praise_songs.chord_key` | TEXT, `'G'` `'Bb'` `'F#m'` …, NULL = 모름(추정) | 지시문을 쓰지 않는다(H3) |
| 곡 코드 시각 | `praise_songs.chord_updated_at` | INTEGER NOT NULL DEFAULT 0, ms | 코드·원래 조를 바꿀 때만 오른다. **곡 `updated_at` 은 안 올린다**. NULL 글 + 시각 > 0 = 지움 |
| 콘티 코드 스냅샷 | `worship_conti_items.song_chord_lyrics` | TEXT, NULL = 없음 | `song_lyrics` 와 짝 |
| 콘티 원래 조 스냅샷 | `worship_conti_items.song_chord_key` | TEXT | |
| 콘티 조 값 | `worship_conti_items.song_transpose` | INTEGER, −11~11, NULL·0 = 원래 조 | 범위 밖이나 정수가 아니면 0 으로 읽는다 |
| 콘티 ♯/♭ 선호 | `worship_conti_items.song_chord_accidental` | TEXT `''`(자동) / `'#'` / `'b'` | 다른 값은 `''` 로 읽는다 |
| DB 버전 | `PraiseDatabase.schemaVersion = 20` | | 모두 `_addColumnIfMissing`. 올리기 전 `worship_slides.db.v19.bak` 자동 백업 |
| 곡 모델 | `PraiseSong.chordLyrics` · `chordKey` · `chordTranspose` · `chordAccidental` | §5-3 | **`toMap` 에 넣지 않는다**(H2). `fromMap` 은 읽는다. 콘티 행 읽기·쓰기는 `worship_conti_repository.dart` 가 직접 한다 |
| 페이지 짝 | `LyricsPage.chord` | String, '' = 이 페이지 코드 없음 | `pairedPages` 가 §3-5 규칙으로 채운다 |
| 슬라이드 정보 | `_SlideInfo.chordText` | 그 페이지 코드 글(**조 바꾸기를 적용한 뒤**), '' = 없음 | `_allSlides` 곡 분기에서만 채운다 |
| 관객 페이지 | `SlidePageData` | **코드 칸 없음** | 관객·통역(B)·배경 영상 PNG 로 새는 길을 막는다 |
| 싱어 페이지 | `SingerPage.chordLines` → JSON **`chord_lines`** | `[{"t": "주 은혜", "c": [[0,"G"],[2,"D/F#"]]}, {"t": "", "c": [[0,"G"],[0,"C"]]}]` | `t` = strip 한 줄, `c` = (UTF-16 오프셋, 조를 바꾼 코드 이름). 코드만 있는 줄은 `t:""`. 코드가 없으면 키를 빼거나 null |
| 싱어 조 표시 | `SingerPage.keyLabel` → JSON **`key_label`** | `"A (원래 G, +2)"`, 조가 그대로면 `""` | 페이지마다 둔다(현재·다음이 다른 곡일 수 있다) |
| 싱어 켜기 | (키 없음) | | 네이티브용 JSON 은 '싱어 코드'가 꺼져 있으면 `chord_lines` 를 **싣지 않는다**. 휴대폰용 JSON 은 늘 싣고 휴대폰 버튼이 정한다. `show_chords` 키는 없다 |
| 싱어 중복 막기 | `_singerDedupeKey` | | `chord_lines`·`key_label` 이 JSON 에 들어가므로 저절로 포함되는지 확인한다 |
| 동기화 스냅샷 | 최상위 **`chords`** 구역 | `[{"uid": "...", "chord_lyrics": "..."\|null, "chord_key": "G"\|null, "updated_at": 1730000000000}]` | `SyncSnapshot.chords: List<SyncChord>`. `SyncSong` 은 그대로다. §3-8 |
| 동기화 최신 비교 | `SyncService._songKeys` | `'chords'` 를 더한다 | '안 올린 수정' 판정 |
| `.wsconti`·클라우드 | 콘티 행 그대로 | 위 네 칸이 자동으로 실린다 | `portableItemRow` 가 옛 콘티를 지금 곡으로 채울 때 `song_chord_lyrics`·`song_chord_key` 도 채운다 |
| 곡 모음 | `exportSongBundle` / `importSongBundle` | 곡마다 `chord_lyrics`·`chord_key` | 가져올 때 이미 있는 곡의 코드는 덮지 않는다(QA M10) |
| PPTX payload | `python_bridge.dart exportPresentation` | **코드 키를 보내지 않는다** | 지금 `title·lyrics·english_lyrics·extra_lyrics` 만 보낸다. 테스트로 못 박는다 |

### 3-4. 코드 저장 길 (QA H2)
- 코드를 DB 에 쓰는 길은 **`PraiseRepository.saveChords` 하나**다.
  - `chord_lyrics`·`chord_key`·`chord_updated_at = _after(옛 값, 지금)` 만 UPDATE 한다.
  - 바뀐 게 없으면 시각도 안 올린다.
  - 그다음 `onSongsChanged`/`hasLocalChanges` 를 부른다.
- `updateSong`·`insertSong`·`_newSongRow` 는 `toMap` 을 쓰고 코드 칸을 모른다. 그래서 가사만 고치는 길이 코드를 덮지 않는다.
- 가사 수정 창과 곡 편집(`_openSongEditor`)은 이 순서로 부른다.
  1. 가사가 바뀌었으면 `updateSong`.
  2. 코드나 원래 조가 바뀌었으면 `saveChords`.
- `replaceAllSongs`: uid 를 이어 쓰는 곡(같은 제목·가사)은 지우기 전의 `chord_lyrics`·`chord_key`·`chord_updated_at` 을 새 행에 옮긴다. **안 하면 전체 다시 가져오기 한 번에 코드가 다 사라진다.**
- `addNewSongs` 의 '나누기만 바뀐 곡 고치기': `realignChords` 를 돌린다. `confident` 이면 `saveChords` 하고, 아니면 코드를 그대로 둔다(어긋남).
- 곡을 지우면 코드도 행째 사라진다(`deleteSongsByIds`·전체 초기화는 고칠 게 없다).

### 3-5. 코드와 가사가 어긋났을 때 — 세 겹 (QA 충돌 3)

| 겹 | 규칙 |
|---|---|
| 저장 데이터 | 코드 글은 **자동으로 지우지 않는다**. `realignChords` 는 결과가 `confident` 일 때만 자동으로 저장한다. 그 밖에는 옛 글을 두고 편집 창이 제안만 한다 |
| 곡 상태 | `chordsMatchLyrics(chord, lyrics)` = `stripChords(chord) == normalizeEditableLyrics(lyrics)`. 칸에 저장하지 않고 읽을 때 계산한다. 거짓이면 '코드 확인' 배지 |
| 표시 | `matchedChordPages(chord, lyrics)`: **strip 한 글의 페이지 수가 `lyrics` 페이지 수와 같을 때만** 인덱스로 짝짓고, 페이지마다 `strip(코드 페이지) == 원본 페이지` 인 것만 코드를 준다. 페이지 수가 다르면 모두 숨긴다. '코드 확인 N' 의 N = 숨긴 페이지 수 |

**`realignChords(oldChordText, newLyrics)`**
1. 옛 코드 글을 strip 하고, 새 가사와 **글자 단위 diff**(Myers)를 한다. 줄바꿈과 페이지 구분도 글자로 본다.
2. 코드마다 붙어 있던 글자가 살아 있으면 그 글자의 새 위치에 붙인다. 지워졌으면 같은 줄의 다음 살아 있는 글자에, 없으면 그 줄 끝에 붙인다(옮김). 줄째 지워진 코드는 버린다.
3. 코드만 있는 줄은 앞뒤 가사 줄이 살아 있으면 그 사이에 둔다.

**`confident`(자동 저장 조건)** — 둘 중 하나:
- (a) 옛 strip 과 새 가사가 **줄바꿈과 공백만 다르다**(페이지 경계를 옮김 — 당기기·밀기·나누기·합치기).
- (b) 바뀐 글자가 새 가사 글자 수의 **10% 이하**이고, 옮김 0 · 버림 0.

**부르는 곳**

| 부르는 곳 | 처리 |
|---|---|
| 가사 수정 창 평소 모드 저장, 곡 편집 | `confident` 면 자동 저장하고 배너로 알린다. 아니면 옛 글을 두고 '다시 맞춘 결과로 바꾸기' 버튼을 준다 |
| `addNewSongs` 고치기 | `confident` 일 때만 저장한다 |
| 찬양 동기화 합치기 | **부르지 않는다.** 코드 글을 고치지 않는다(PC 마다 다르게 다시 맞춰 서로 덮어쓰는 일을 막는다) |
| 콘티 스냅샷 쪽 수정(발표 보기 '한 장 고치기' `_SlideQuickEditDialog`, `contiOnly` 가사 수정) | **부르지 않는다.** 그 페이지만 표시 검사에서 숨는다. 가사 수정 창에서 콘티 곡을 코드 모드로 고치면 그 스냅샷의 `chordLyrics` 를 같이 바꾼다 |

- 원본 가사를 코드 글로 덮어쓰는 길은 **코드 모드 편집 저장 하나뿐**이다. 사용자가 보고 있는 글이고, 코드만 고쳤으면 `lyrics` 는 바뀌지 않는다.

### 3-6. 원래 조와 추정
- `chord_key` 가 있으면 그 값을 쓴다.
- 없으면 `estimateKey(chordText)` 를 쓴다: 첫 코드의 뿌리음, 그 코드가 `m`/`min` 이면 단조. `N.C.` 는 건너뛴다. 코드가 없으면 null.
- 화면엔 추정이면 '(추정)'을 붙인다.

### 3-7. 페이지 나누기·합치기·당기기와 코드
- 코드 모드에선 원본 열 값이 코드 글이라 `LyricsPageGrid` 연산(`splitAt`·`mergeWithNext`·`pullUp`·`pushDown`·`insertRows`·`splitCell`)이 코드를 데려간다. 저장 때 `lyrics = stripChords(전체)`.
- **커서 위치 나누기**: 커서가 코드 토큰 안이나 `\[` 사이에 있으면 토큰 앞으로 당긴다. 토큰 바로 뒤에서 나누면 토큰은 뒤 조각 맨 앞으로 간다(코드가 그 글자에 붙어 있도록). → `snapSplitOffset(text, offset)` 하나로 처리한다.
- 칸에 빈 줄 든 글 붙여 넣기 나누기: 토큰은 줄 안에 있으므로 규칙 그대로다.
- 평소 모드 연산은 저장 때 §3-5 다시 맞추기로 이어진다. 페이지 경계만 바뀐 경우라 (a) 조건으로 자동 저장되고 코드를 하나도 안 잃는다.
- **콘티 쪽**: `itemsFromPages`(복사·옮기기·나누기), `_splitStagingItem`, 붙여 넣기, 끌어 옮기기, **성경 음성 넣기**(곡 중간에 넣으면 곡을 나눈다)는 모두 `_songWithPages` 를 지난다. 규칙은 하나다(QA M5).
  - `_songWithPages` 는 `chordLyrics` 를 `pages.map((p) => p.chord.isEmpty ? escapeLyricsForChords(p.korean) : p.chord)` 를 이어 붙여 다시 만든다. 코드 없는 페이지는 이스케이프한 원본 글로 채워 페이지 수를 맞춘다. 모든 페이지가 코드가 없으면 null.
  - `chordKey`·`chordTranspose`·`chordAccidental` 은 `copyWith` 로 앞·뒤 조각 모두에 그대로 간다.
  - 곡 끝 빈 페이지를 빈 페이지 항목으로 떼면(`itemsFromPages`) 그 페이지 코드는 버린다(빈 페이지 항목엔 코드가 없다 — 받아들인다).
- `_applySlideEdit`(한 장 고치기): `chord: newMain == old.korean ? old.chord : ''`.
- 언어 바꾸기(`_reapplySubLanguage`)·원본 다시 불러오기: `korean` 은 그대로라 코드도 그대로다.

### 3-8. 찬양 동기화 (QA 충돌 2 — 백엔드안)
- **`SyncSnapshot.chords`** 구역을 둔다. `exportSnapshot` 은 `chord_updated_at > 0` 인 곡만 싣는다.
  - 지운 코드는 `chord_lyrics: null` 에 시각을 실어 지움을 전한다.
  - `format`·`version` 은 그대로다. 옛 앱은 모르는 키를 버리므로 깨지지 않는다.
- **합치기** `_mergeChords` 는 `_mergeIn` 에서 `_mergeSongs` 뒤에 돈다(uid 합치기가 끝난 다음).
  - 키는 `canonical(uid)`(aliases 를 따라감)다.
  - `updated_at` 이 큰 쪽이 이긴다. 같으면 `'${chord_lyrics ?? ''}\u0000${chord_key ?? ''}'` 문자열 비교로 가른다 — 어느 PC 에서도 같은 답이 나온다.
  - 이 PC 에 그 곡이 없으면 버린다.
  - 이 PC 값보다 새로우면 `chord_lyrics`·`chord_key`·`chord_updated_at` 만 UPDATE 한다.
  - **곡 `updated_at`·`contentKey`·`content_hash`·`tieKey` 는 손대지 않는다.**
- **다른 PC 가 가사를 바꿔 이쪽 코드가 어긋나도 합칠 때 고치지 않는다.** 어긋남으로 표시되고, 사람이 편집 창에서 다시 맞춘다.
- **옛 앱이 섞일 때**: 옛 PC 파일엔 `chords` 가 없다. 코드에 대해 아무 말도 안 한 것으로 본다. 옛 PC 가 가사를 고쳐도 코드는 남고 어긋남으로 보인다.
- **중복 정리** `_canonicalLocalRows`: 같은 내용의 행을 지울 때, `chord_updated_at` 이 큰 쪽 코드를 남는 행으로 먼저 옮긴다.
- `_renameUid` 는 행이 그대로라 코드가 따라간다.
- `preview`(켤 때 확인)는 코드만 바뀐 곡도 '바뀐 찬양' **1곡**으로 센다. `preview` 는 DB 를 안 바꾼다(지금처럼 롤백).
- `_songKeys` 에 `'chords'` 를 넣는다. `saveChords` 는 `hasLocalChanges` 를 켠다.

### 3-9. 콘티 스냅샷과 '콘티도 바꿀까요' (QA H5)
- 담을 때 `chordLyrics`·`chordKey` 를 복사하고, `chordTranspose = 0`, 표기는 자동이다. 불러올 때는 스냅샷을 쓰고 라이브러리 곡을 따라가지 않는다.
- v19 이전 콘티 행은 코드 칸이 NULL 이라 코드 없음이다. 굳히기 마이그레이션은 하지 않는다.
- **`songEditChanged`** 비교에 `chordLyrics`·`chordKey` 를 넣는다. 코드만 고쳐도 '콘티도 바꿀까요'를 묻는다.
- **대상 항목**: 지금 규칙(항목 가사가 고치기 전 원본과 같음)에 더해, 항목의 `chordLyrics`·`chordKey` 가 고치기 전 라이브러리 값과 같아야 한다. 콘티 쪽에서 따로 고친 코드는 덮지 않는다.
- **바꿀 때 `_offerStagedSongUpdate`**:
  1. `_withSubLyrics(edited)` 로 새 항목을 만든다.
  2. **옛 항목의 `chordTranspose`·`chordAccidental` 을 `copyWith` 로 옮겨 붙인다.**
  3. 빠뜨리면 조 값이 0 으로 돌아간다 — 테스트로 못 박는다.

### 3-10. 조 바꾸기 규칙
- `transposeChordName(name, n)`: 뿌리음과 `/` 뒤 베이스음만 n 반음 옮긴다. 성질·텐션은 그대로다. `N.C.` 와 문법 밖 이름은 그대로 둔다. `E#`·`B#`·`Cb`·`Fb` 는 내지 않는다.
- **표기**
  - `ChordAccidental.sharp` / `flat` 이면 그것을 쓴다.
  - `auto` 면 **바꾼 뒤의 조**(`keyAfter(원래 조 또는 추정, n)`)로 고른다. F·B♭·E♭·A♭·D♭·G♭ 장조와 그 관계 단조(Dm·Gm·Cm·Fm·B♭m·E♭m)는 ♭, 나머지는 ♯.
  - 조를 모르면 원래 코드 글의 표기를 따른다(♭ 가 더 많으면 ♭).
  - 문자는 입력 그대로(`#`·`b`)로 낸다. 글리프 `♯`·`♭` 표시는 미확인이라 1차는 ASCII 다.
- n = 0 이면 원래 글을 그대로 쓴다(표기를 다시 쓰지 않는다).
- **콘티 한번에 넣기**: `semitonesBetween(원래 조 또는 추정, 글의 첫 조)` 로 계산한다. 결과는 −5~+6 으로 맞추고, 장·단조가 다르면 null(적용 안 함).
- `strip(transposeChordText(t, n)) == strip(t)` 가 늘 성립한다(테스트).
- 관객 화면·PPTX 에는 영향이 없다. 조를 바꾸면 `_sendSingerView()` 를 직접 부른다(발표 보기는 setState).

### 3-11. 그리기 수치 (세 렌더러 공통: macOS 싱어 HTML, 휴대폰 HTML, Flutter `ChordSheetView`)

| 값 | 수치 |
|---|---|
| 코드 글자 크기 | 가사 글자 × **0.55**, 굵게 |
| 코드 색 | **`#FFA94D`** (현재) / **`#B07A40`** (다음 페이지 — 지금 다음 페이지 보조색 `#b8a25a` 처럼 흐린 값) |
| 코드 줄 높이 | 코드 글자 × 1.15 (가사 줄 위에 붙인다) |
| 코드 뒤 최소 틈 | 코드 글자의 0.4em. 조각 폭 = max(가사 폭, 코드 폭 + 틈) |
| 보조 색 | 그대로 `#ffd54f` / 다음 `#b8a25a` |
| 조 배지 | 테두리·글자 `#8b95a2`, 바탕 없음, 머리줄 제목 바로 오른쪽 |
| 시계 경고 | 그대로 `#ffb547` — 코드·배지와 구분된다 |

**맞춤**
- 가장 긴 줄의 폭과 전체 높이(코드 줄 포함)가 상자에 들어가는 가장 큰 글자 크기를 고른다. 지금 규칙에 코드 줄 높이만 더한 것이다.
- 자동 줄바꿈 문턱(창 높이 3.5%)은 그대로다. 코드가 있는 줄은 **조각 경계의 공백에서만** 꺾는다. HTML 은 조각을 inline-block 으로, 공백을 조각 사이 글자로 둔다.
- 다음 페이지는 현재 페이지 글자의 0.75배 상한 그대로다.
- 어림: 코드 줄이 끼면 줄 높이가 약 1.5~1.6배가 되고, 글자는 약 0.65~0.75배로 줄어든다(**미확인**, 실제 콘티로 측정).

---

## 4. 범위 밖 / 2차

| 항목 | 메모 |
|---|---|
| **Windows 싱어 창 코드** | 사용자 확정 2차. `singer_window.cpp` GDI 로 조각마다 재고 그리며, 공백 경계로 직접 줄바꿈한다. 1차에선 `chord_lines` 를 안 보내고 스위치를 숨긴다 |
| 악보 OCR 에서 코드 살리기 | 지금 `is_chord_line`·`_CHORD_LINE` 으로 버린다. 코드 줄 x 좌표와 가사 글자 x 좌표로 인라인을 만들 수 있다. OCR 이 코드를 뭉개는 문제(`Bo`, `DIC`)가 크다. 그때 Python `_CHORD_TOKEN_RE` 를 §3-1 문법에 맞춘다 |
| ChordPro 파일(.cho/.pro) 가져오기·내보내기, 지시문 | 붙여 넣기로는 1차에 된다(`{…}` 지시문은 글자로 남는다) |
| 끝 페이지가 코드뿐인 경우 보이기(아웃트로) | §3-1 |
| 곡 중간 전조, 카포, 내시빌 넘버 | — |
| 코드 악보 PDF·인쇄(반주자 배포용) | 관객 PPTX 와 별개. 관객용엔 넣지 않는다 |
| 싱어 창에서 `C` 키로 켜기, 앱 스위치를 다음 실행까지 기억 | — |
| 보조 언어 줄 코드, 관객 화면·통역(B) 코드 | 하지 않는다 |

---

## 5. 구현 순서 — 백엔드 단계 → (Dart API 계약) → 프론트 단계

### 5-1. 백엔드 단계 (화면 없음, 테스트로 끝낸다)

| # | 일 | 파일 | 테스트 |
|---|---|---|---|
| B0 | **선행(H7)**: §3-1 문법과 이스케이프를 가장 먼저 만든다. 사용자 DB 에서 대괄호 든 가사 수를 세는 SQL(`SELECT count(*) FROM praise_songs WHERE lyrics LIKE '%[%'`)을 사용 설명에 적어 두고 결과를 받는다. 세기는 경고 문구 조정용이다 — 이스케이프가 데이터 손실을 막으므로 B1 이후를 막지 않는다 | `domain/chord_lyrics.dart` | `stripChords(escapeLyricsForChords(x)) == x` (대괄호·`\` 섞인 가사 표본 30개) |
| B1 | 도메인 순수 함수 전부(§5-3) | `domain/chord_lyrics.dart` (새 파일) | `test/chord_lyrics_test.dart`: QA 체크리스트 '순수 로직' 전부, §3-1 표 판정 전부, H6 세 예시 |
| B2 | DB v20 칸과 `PraiseSong` 필드(`toMap` 제외·`fromMap` 포함)·`LyricsPage.chord`·`pairedPages`·`_songWithPages` 규칙 | `praise_database.dart`, `praise_song.dart` | `test/db_backup_test.dart`(v19→20, 칸이 이미 있는 DB), `pairedPages` 짝짓기 |
| B3 | 저장소: `saveChords`, `songsByIds`·검색이 코드 칸을 읽음, `replaceAllSongs` 코드 이어 쓰기, `addNewSongs` 다시 맞추기, 곡 모음 내보내기·가져오기 | `praise_repository.dart` | 코드만 저장 → DB 반영(H2). 가사만 저장 → 코드 그대로. 전체 교체 뒤 코드 유지 |
| B4 | 동기화 `chords` 구역, `_mergeChords`, `_canonicalLocalRows` 코드 옮기기, `preview` 세기, `_songKeys` | `sync_snapshot.dart`, `song_sync_repository.dart`, `sync_service.dart` | `test/sync_test.dart`: 코드 전파 · 곡 시각 그대로 · 옛 앱 흉내(`chords` 없음 + 가사 수정) · 같은 시각 순서 무관 · 지움 전파 · 중복 정리 · `preview` |
| B5 | 콘티 저장·불러오기 네 칸, `portableItemRow`, `.wsconti`·클라우드 왕복, 범위 밖 값 버리기 | `worship_conti_repository.dart` | 콘티 왕복, 옛 `.wsconti` 가져오기, `song_transpose` 99·'x' → 0 |
| B6 | 콘티 쪽 순수 동작: `itemsFromPages`·나누기가 코드·조를 이어받음 | `praise_home_page.dart` 의 순수 함수 쪽 / `move_pages` 관련 | `test/move_pages_test.dart` 에 코드 곡 나누기·옮기기·끝 빈 페이지 |
| B7 | 누출 테스트: `SlidePageData.toJson`·`forB` 에 코드 키 없음, PPTX payload 에 코드 없음 | — | `test/` 새 케이스 + `python/test_export_text.py`(payload 에 `chord_lyrics` 가 와도 무시) |

### 5-2. 프론트 단계 (B1~B5 가 끝난 뒤. F1·F2 는 따로, F3~F5 는 F2 뒤)

| # | 일 | 파일 | 확인 |
|---|---|---|---|
| F1 | 가사 수정 창 코드 모드(S1·S1b·S1c), 평소 모드 다시 맞추기 배너, `_openSongEditor` 의 `saveChords`, `songEditChanged`, '콘티도 바꿀까요' 조 유지(H5) | `lyrics_editor_dialog.dart`, `lyrics_page_grid.dart`(`snapSplitOffset`), `praise_home_page.dart` | `test/lyrics_page_grid_test.dart` 코드 칸 연산. 코드 모드를 켜고 그냥 저장 → `lyrics` 불변. `LYRICS_EDITOR_SHOT` 스크린숏 |
| F2 | 싱어 데이터: `_SlideInfo.chordText`(조 적용), `SingerPage.chordLines`·`keyLabel`, 네이티브용(스위치)과 휴대폰용(늘) 두 JSON, 조를 바꾸면 `_sendSingerView` | `singer_view_data.dart`, `praise_home_page.dart` | JSON 단위 테스트. 스위치가 꺼져 있으면 키 없음 |
| F3 | 휴대폰 HTML(S3) | `singer_web_server.dart` | 리눅스에서 브라우저로 확인: 버튼, 맞춤, 공백 줄바꿈, 터널 폴링 |
| F4 | macOS 싱어 HTML(S2) | `macos/Runner/MainFlutterWindow.swift` | PR CI 컴파일 + 사람이 macOS 에서 확인 |
| F5 | 발표 보기(S4): `ChordSheetView`(새 위젯), '코드 보기'·'싱어 코드'(macOS 만) 스위치, 포인터 막기, 구석 그림, 다음 슬라이드, '조' 묶음 | `presentation/chord_sheet_view.dart`(새), `praise_home_page.dart` | 위젯 테스트: 코드 보기 중 `_emitPointer` 안 불림, 단축키 그대로 |
| F6 | 조 UI(S5), 배지(S7) | `praise_home_page.dart` | — |
| F7 | 콘티 한번에 넣기 조 칸(S6), 반환형 변경(H4) | `conti_text_import_dialog.dart`, `praise_home_page.dart` `_importContiText` | `test/conti_text_parse_test.dart` 에 `A`·`F#m`·`Bb`·`(Key Bb)`·`F-G` → 조 값 |
| F8 | CLAUDE.md, `docs/` 사용 설명서("코드 쓰는 PC 는 모두 새 버전으로" 포함) | — | — |

### 5-3. Dart API 계약 (백엔드 → 프론트)

```dart
// lib/src/features/praise/domain/chord_lyrics.dart  (새 파일, 순수 함수만 — Flutter import 없음)

enum ChordAccidental { auto, sharp, flat }   // DB: '' / '#' / 'b'

/// strip 한 한 줄 + 그 줄 위 코드들. 싱어 JSON {"t": text, "c": [[offset, name], ...]} 와 1:1.
class ChordLine {
  const ChordLine(this.text, this.chords);
  final String text;                              // 코드 뺀 줄 (코드만 있는 줄이면 '')
  final List<({int offset, String name})> chords; // offset = text 안 UTF-16 위치(0..text.length)
  Map<String, Object> toJson();                   // {"t": ..., "c": [[o, n], ...]}
}

/// 코드 이름 하나가 §3-1 문법에 맞는지 (대괄호 없이: 'D/F#').
bool isChordName(String name);

/// 코드 글 → 원본 가사 (§3-1 strip 정의. 결과는 normalizeEditableLyrics 를 지난 모양).
String stripChords(String chordText);

/// 원본 가사 → 코드 글 시작값. 코드로 읽힐 '[' 앞에만 '\' 를 붙인다.
/// 늘 stripChords(escapeLyricsForChords(x)) == normalizeEditableLyrics(x).
String escapeLyricsForChords(String lyrics);

/// 코드 글을 페이지로 (PraiseSong 페이지 나누기와 같은 빈 줄 규칙, 끝 빈 페이지 유지 안 함).
List<String> chordPagesOf(String chordText);

/// 한 페이지 코드 글 → 줄 목록 (싱어·ChordSheetView 가 그대로 쓴다).
List<ChordLine> parseChordPage(String chordPage);

/// 곡 단위 정합 (§3-5 '곡 상태').
bool chordsMatchLyrics(String? chordText, String lyrics);

/// 표시용 페이지 짝 (§3-5 '표시'). 결과 길이 = lyrics 페이지 수, 짝 없는 페이지는 null.
List<String?> matchedChordPages(String? chordText, String lyrics);

/// 편집 창 경고용.
enum ChordIssueKind { unreadableBracket, fixableCase, trailingChordOnlyPage, nestedBracket }
class ChordIssue {
  const ChordIssue(this.kind, this.page, this.start, this.end, {this.suggestion});
  final ChordIssueKind kind;
  final int page;          // 0부터
  final int start, end;    // 그 페이지 글 안 UTF-16 범위
  final String? suggestion; // fixableCase 일 때 '[G]'
}
List<ChordIssue> validateChordText(String chordText);

/// 코드 개수 (요약 줄).
int countChords(String chordText);

/// 커서 나누기 위치를 토큰·'\[' 밖으로 당긴다 (§3-7).
int snapSplitOffset(String chordPage, int offset);

// ── 조 ─────────────────────────────────────────────
/// 'G' 'Bb' 'F#m' 처럼 조 이름(장 12 + 단 12)인지.
bool isKeyName(String key);

/// 원래 조 추정 (§3-6). 코드가 없으면 null.
String? estimateKey(String chordText);

/// n 반음 옮긴 조 이름 (표기 규칙 §3-10).
String keyAfter(String key, int semitones, {ChordAccidental accidental = ChordAccidental.auto});

/// from → to 반음 차 (−5..+6). 장·단조가 다르거나 이름이 틀리면 null.
int? semitonesBetween(String fromKey, String toKey);

/// 코드 이름 하나 / 코드 글 전체 옮기기. 문법 밖 이름·N.C. 는 그대로. semitones == 0 이면 입력 그대로.
String transposeChordName(String name, int semitones,
    {ChordAccidental accidental = ChordAccidental.auto, String? targetKey});
String transposeChordText(String chordText, int semitones,
    {ChordAccidental accidental = ChordAccidental.auto, String? originalKey});

/// 싱어·발표 보기 머리줄 표시. 조가 그대로면 ''.  예) 'A (원래 G, +2)', 'A (원래 G (추정), +2)'
String keyLabel({required String? originalKey, required bool estimated, required int semitones,
    ChordAccidental accidental = ChordAccidental.auto});

/// −11..11 로 돌리기 (12 → 0, −12 → 0, 13 → 1).
int wrapTranspose(int semitones);

// ── 다시 맞추기·변환 ─────────────────────────────────
class ChordRealign {
  const ChordRealign(this.chordText, {required this.kept, required this.moved,
      required this.dropped, required this.confident});
  final String chordText;
  final int kept, moved, dropped;
  final bool confident;   // §3-5 자동 저장 조건
}
ChordRealign realignChords(String oldChordText, String newLyrics);

/// '코드 줄 + 가사 줄' 쌍이 2쌍 이상이면 인라인 코드 글로, 아니면 null (한글 폭 2칸).
String? chordOverLyricsToInline(String pasted);
```

```dart
// lib/src/features/praise/domain/praise_song.dart  (바뀌는 것만)

typedef LyricsPage = ({String korean, String english, String extra, String chord}); // chord: '' = 없음

class PraiseSong {
  // ...기존 필드...
  final String? chordLyrics;              // null = 코드 없음. DB praise_songs.chord_lyrics / 콘티 song_chord_lyrics
  final String? chordKey;                 // null = 모름(추정). DB chord_key / 콘티 song_chord_key
  final int chordTranspose;               // 기본 0, −11..11. 콘티 스냅샷 전용 (DB praise_songs 엔 없음) / 콘티 song_transpose
  final ChordAccidental chordAccidental;  // 기본 auto. 콘티 스냅샷 전용 / 콘티 song_chord_accidental

  bool get hasChords => chordLyrics != null && chordLyrics!.isNotEmpty;

  // copyWith: 네 필드 모두 (chordLyrics·chordKey 는 null 로 지울 수 있게 sentinel/별도 플래그)
  // toMap(): 네 필드 모두 넣지 않는다 (H2)
  // fromMap(): chord_lyrics, chord_key 를 읽는다 (없으면 null)
  // pairedPages: chord 칸 = matchedChordPages(chordLyrics, lyrics)[i] ?? ''
}

// SongStagingItem: 새 필드 없음 (조 값은 song.chordTranspose — 항목을 새로 만드는 곳이 많아 빠뜨리지 않게)
```

```dart
// lib/src/features/praise/data/praise_repository.dart
Future<void> saveChords(int songId, {required String? chordLyrics, required String? chordKey});
// '' 는 null 로 저장. 바뀐 게 없으면 아무것도 안 한다. chord_updated_at = _after(old, now).

// lib/src/features/praise/presentation/singer_view_data.dart
class SingerPage {
  // ...기존...
  final List<ChordLine>? chordLines;  // JSON 'chord_lines' (null/빈 = 키 생략)
  final String keyLabel;              // JSON 'key_label' (기본 '')
}

// lib/src/features/praise/presentation/conti_text_import_dialog.dart  (H4)
typedef ContiTextPick = ({PraiseSong song, int transpose}); // transpose: 체크 끔·적용 불가면 0
static Future<List<ContiTextPick>?> show(...);
// _importContiText 는 pick.song.copyWith(chordTranspose: pick.transpose) 로 담는다 (_withSubLyrics 뒤)
```

계약 규칙:
- 프론트는 코드 글을 **직접 정규식으로 풀지 않는다**. 위 함수만 쓴다.
- 렌더러(HTML·Swift)는 `chord_lines` 만 읽고 ChordPro 를 풀지 않는다(QA M3).
- `_SlideInfo.chordText` 는 `transposeChordText(pairs[j].chord, song.chordTranspose, accidental: song.chordAccidental, originalKey: song.chordKey ?? estimateKey(...))` 결과다. 관객 쪽 `SlidePageData` 를 만드는 함수에는 넘기지 않는다.

---

## 6. 위험·미확인 사항

| 구분 | 내용 | 대응 |
|---|---|---|
| 위험 | `replaceAllSongs` 가 코드를 지움 | §3-4, B3 테스트 |
| 위험 | 코드만 저장이 사라짐(`updateSong` 의 unchanged return) | `saveChords` 따로(§3-4), B3 테스트 |
| 위험 | '콘티도 바꿀까요'가 조 값을 0 으로 되돌림 | §3-9, F1 테스트 |
| 위험 | 문법 밖 대괄호가 관객 화면에 글자로 나감 | 편집 창 경고(설계상 받아들임) |
| 위험 | `realignChords` 가 코드를 엉뚱한 글자에 붙임 | `confident` 일 때만 자동이고 나머지는 사람이 확인한다. 페이지 검사는 글자만 보므로 위치 틀림은 못 잡는다 |
| 위험 | 렌더러 세 곳(Swift HTML, 휴대폰 HTML, Flutter) 수치가 어긋남 | §3-11 표 하나. 휴대폰을 먼저 만들고 Swift 가 그 CSS·JS 를 옮긴다 |
| 위험 | 옛 앱으로 내려가기 — `openDatabase` 에 `onDowngrade` 가 없다. sqflite 동작은 **미확인**. 옛 앱이 전체 교체를 하면 코드가 사라진다 | 사람 확인 테스트 항목. 사용 설명서에 "코드 쓰는 PC 는 모두 새 버전으로" |
| 미확인 | 사용자 DB 에 대괄호 든 가사가 얼마나 있는지 | B0 에서 센다(이스케이프로 손실은 막혀 있다) |
| 미확인 | 코드 줄이 끼면 싱어 글자가 실제로 얼마나 작아지는지(어림 0.65~0.75배) | F3 에서 측정 |
| 미확인 | Pretendard·WKWebView 기본 글꼴의 ♯·♭ 글리프 | 1차는 ASCII `#`·`b` |
| 미확인 | 한글 2칸 가정 '코드 위 가사' 변환이 실제 카톡·웹 악보에 맞는지 | 미리보기 + 되돌리기 |
| 미확인 | D4-A 코드 보기를 조작자가 실제로 쓰는지 | 안 쓰면 S4 2순위 대안 |
| 미확인 | macOS 싱어 창 실제 모습 | 리눅스에서 실행 불가. PR CI 컴파일 + 사람 확인 |
| 미확인 | 실제 가사에 NFD 한글이 있으면 diff·비교가 흔들리는지 | 같은 출처 글끼리 비교라 영향이 적다고 보지만 확인 전 |
