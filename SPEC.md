# SermonCut — macOS 설교 영상 자동 컷편집 앱 개발 지시서

> 이 문서를 프로젝트 루트에 `SPEC.md`로 두고, Claude Code에게 "SPEC.md를 읽고 Phase 0부터 시작해"라고 지시한다.
> 동시에 `CLAUDE.md`를 생성해 아래 **개발 규칙** 섹션을 복사해 넣는다.

---

## 0. 한 줄 요약

예배 전체가 담긴 라이브 영상(60~120분)에서 **설교 구간만 먼저 타임라인으로 잘라내고**, 설교 원고(hwpx/docx/txt)와 대조해 **원고에 대응되지 않는 구간을 AI가 자동으로 삭제 후보로 마킹한 전사문**을 보여준 뒤, 사용자가 최종 확인하면 **FCPXML(Final Cut Pro 임포트용)** 또는 **ffmpeg 렌더 결과물**로 내보내는 macOS 네이티브 앱.

---

## 1. 사용자 워크플로우

```
[1단계] 영상 파일 선택 (.mov/.mp4, 예배 전체 60~120분, 3~4GB)
      └─ ffprobe: fps/해상도/duration/타임베이스 추출
      └─ 파형(waveform) 생성

[2단계] 구간 선택 화면  ★ 신규
      ├─ AVPlayer + 파형 타임라인 표시
      ├─ 사용자가 In/Out 마커로 설교 구간 지정
      │    (보통 "대표기도" 직후 ~ "봉헌기도" 직전:
      │     성경본문 낭독 + 설교)
      ├─ [자동 찾기] 버튼 — whisper base 모델로 전체 빠른 스캔 후
      │    "대표기도"/"봉헌" 키워드 위치를 후보로 제시 (선택 기능)
      └─ 확정 → sourceRange 저장

[3단계] 설교 원고 파일 선택 (.hwpx/.docx/.txt/.md) — 선택사항

[4단계] "분석 시작"
      ├─ ffmpeg: sourceRange 구간만 16kHz mono wav 추출
      ├─ whisper large-v3: 정밀 전사 (세그먼트 + 단어 타임스탬프)
      │    → 파싱 직후 모든 타임스탬프에 sourceRange.start를 더해
      │      원본 파일 기준으로 변환  ★ 중요
      ├─ ffmpeg silencedetect: 무음 구간 리스트
      └─ AI(Claude/DeepSeek): 원고 ↔ 전사문 정렬

[5단계] 전사문 편집 화면
      ├─ 원고와 매칭된 세그먼트   → 흰색 (유지)
      ├─ 원고에 없는 세그먼트     → 회색 (삭제 후보, 자동 마킹)
      └─ 사용자가 토글로 최종 조정

[6단계] 내보내기
      ├─ (A) FCPXML → Final Cut Pro에서 열기 (메인)
      └─ (B) ffmpeg 렌더 → 프리뷰 mp4 (검수용)
```

**원본 영상은 자르지 않는다.** 구간 선택은 In/Out 좌표만 저장하며, FCPXML과 ffmpeg 모두 원본 파일을 참조한다. 중간 파일을 만들면 2GB짜리 쓰레기가 매주 쌓이고 재인코딩 손실도 생긴다. 오디오만 해당 구간을 잘라 임시 wav로 뽑는다.

---

## 2. 기술 스택 (확정)

| 영역 | 선택 | 비고 |
|---|---|---|
| 앱 | **SwiftUI + AppKit**, macOS 14.0+ | Xcode 프로젝트 |
| 언어 | Swift 5.9+ (Swift Concurrency 사용) | `async/await`, `Actor` |
| 영상 프리뷰 | AVKit / AVFoundation | 대용량 파일 스트리밍 디코딩 |
| 미디어 분석 | `ffprobe` (번들 바이너리) | fps, timebase 정확도 필수 |
| 오디오/렌더 | `ffmpeg` (번들 바이너리) | `xfade`, `acrossfade`, `silencedetect` |
| STT | `whisper.cpp` (Metal) + `ggml-large-v3` | 별도 다운로드, 앱에서 경로 지정 |
| AI 정렬 | Claude API / DeepSeek API / OpenAI 호환 엔드포인트 | Provider 추상화 |
| 문서 파싱 | **hwpx / docx / txt / md** — 전부 자체 파싱 | hwpx·docx 모두 ZIP + XML 구조. 아래 6.0절 참고 |
| ZIP 해제 | `ZIPFoundation` (SPM) 또는 `libcompression` 직접 사용 | hwpx/docx 컨테이너 해제용 |
| 파형 생성 | `AVAssetReader` 또는 ffmpeg PCM 덤프 → 피크 다운샘플 | 구간 선택 화면용 |
| 설정 저장 | `UserDefaults` (일반) + **Keychain (API 키)** | `.env` 사용 금지 — 아래 3절 참고 |
| 프로젝트 파일 | `.sermoncut` (JSON) | 작업 중단/재개 |

### 외부 바이너리 처리
- `ffmpeg`, `ffprobe`, `whisper-cli`는 앱 번들의 `Resources/bin/`에 포함하거나, 설정에서 사용자가 경로를 지정(Homebrew 설치본 사용)할 수 있게 **둘 다** 지원한다.
- 1순위: 설정에 지정된 경로 → 2순위: 번들 경로 → 3순위: `/opt/homebrew/bin` → 없으면 에러 안내.
- 앱 샌드박스는 **끈다** (외부 프로세스 실행 + 임의 경로 파일 접근 필요). Hardened Runtime은 켜되 필요한 entitlement만 추가.

---

## 3. AI 연계 설계

### 3.1 API 키 저장 — `.env` 대신 Keychain
macOS 앱 번들에 `.env`를 넣으면 누구나 `Show Package Contents`로 열 수 있다. 다음 방식으로 구현한다.

- **설정 화면(⌘,)에서 API 키 입력** → `Security.framework`의 Keychain에 저장
  - Service: `com.nugabox.sermoncut.apikey`
  - Account: provider 식별자 (`claude`, `deepseek`, `openai-compatible`)
- 개발 편의를 위해 **환경변수 fallback**은 허용한다: `SERMONCUT_API_KEY`가 있으면 우선 사용 (CI/디버깅용).
- **API 키를 로그, 프로젝트 파일(.sermoncut), 커밋에 절대 기록하지 않는다.**

### 3.2 Provider 추상화

```swift
protocol AIProvider {
    var displayName: String { get }
    var defaultModel: String { get }
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}

struct ClaudeProvider: AIProvider    // https://api.anthropic.com/v1/messages
struct DeepSeekProvider: AIProvider  // https://api.deepseek.com/chat/completions (OpenAI 호환)
struct OpenAICompatibleProvider: AIProvider  // baseURL 사용자 입력 (Ollama/vLLM 등 로컬도 가능)
```

설정 화면 구성:
- Provider 선택 (Segmented)
- Base URL (OpenAI 호환일 때만 노출)
- Model 이름 (텍스트 필드, 기본값 제공)
- API Key (SecureField)
- **[연결 테스트]** 버튼 — 짧은 요청 1회로 검증

### 3.3 원고 ↔ 전사문 정렬 (이 앱의 핵심 로직)

**문제**: 설교 원고는 문어체 완성본, 전사문은 구어체 + 오인식 + 즉흥 발언 포함. 길이도 다르고 표현도 다르다.

**전략** — 2단계 하이브리드:

**1단계: 로컬 러프 정렬 (API 호출 전, 무료)**
- 원고를 문장 단위로 분할 (`.`, `!`, `?`, 줄바꿈 기준)
- 각 문장/세그먼트를 정규화: 공백·구두점 제거, 조사 제거는 하지 않음
- **문자 n-gram 유사도(bigram Jaccard)** 로 후보 매칭
- 매칭은 **단조 증가(monotonic)** 제약을 건다 — 설교는 원고 순서대로 진행되므로, i번째 원고 문장이 j번째 세그먼트에 매칭되면 i+1은 j 이후에서만 찾는다. (Needleman-Wunsch 계열 DP 정렬)
- 이 단계에서 이미 **70~80%는 확정**된다. 확신도 높은 매칭(유사도 > 0.6)은 AI에 보내지 않는다.

**2단계: AI 정렬 (애매한 구간만)**
- 1단계에서 확정된 매칭 사이의 **애매한 구간(gap)** 만 잘라서 AI에 보낸다
- 앞뒤 확정 앵커를 함께 제공해 컨텍스트 유지
- 요청당 원고 20문장 + 전사문 30세그먼트 이내로 청킹 (토큰 제어)
- **응답은 반드시 JSON만** 반환하도록 프롬프트에 명시

AI 프롬프트 템플릿:

```
system:
당신은 설교 원고와 음성 전사문을 정렬하는 도구입니다.
원고는 사전 작성된 문어체 텍스트이고, 전사문은 실제 설교 음성을 STT로 옮긴 것입니다.
전사문에는 원고에 없는 즉흥 발언, 인사말, 반복, 더듬음, STT 오인식이 포함됩니다.
반드시 JSON만 출력하고 설명이나 마크다운 코드펜스를 붙이지 마십시오.

user:
[원고 문장]
M1: ...
M2: ...

[전사문 세그먼트]
T14 (03:04): ...
T15 (03:09): ...

각 전사문 세그먼트에 대해 판정하십시오.
- 원고 문장에 대응되면: matched, 해당 원고 ID, confidence(0~1)
- 대응되지 않으면: unmatched, reason 중 하나
  (greeting | repetition | filler | improvised | misrecognized | unknown)

출력 형식:
{"results":[{"segment":"T14","status":"matched","manuscript":"M1","confidence":0.92},
            {"segment":"T15","status":"unmatched","reason":"filler"}]}
```

**3단계: 결과 적용**
- `matched` → 유지 (흰색)
- `unmatched` + reason이 `filler`/`repetition` → **자동 삭제 마킹** (회색)
- `unmatched` + reason이 `greeting`/`improvised` → 삭제 마킹하되 **노란 테두리로 "확인 필요"** 표시 (의도적으로 살릴 수 있는 내용)
- `misrecognized` → 유지 (STT 오류일 뿐 실제로는 원고 내용)
- confidence < 0.5 → 노란 테두리

**중요**: 자동 마킹은 **제안**일 뿐이며 사용자가 최종 결정한다. AI 결과를 그대로 렌더에 반영하지 않는다.

**실패 처리**: API 오류/타임아웃/JSON 파싱 실패 시 해당 청크는 "정렬 실패"로 두고 전부 유지 상태로 표시. 앱이 죽거나 작업 전체가 중단되면 안 된다. 재시도 버튼 제공.

**비용 표시**: 정렬 전에 예상 토큰 수와 대략적 호출 횟수를 사용자에게 보여주고 확인받는다.

---

## 4. 데이터 모델

```swift
struct SermonProject: Codable {
    var id: UUID
    var videoURL: URL              // 보안 스코프 북마크로 저장
    var manuscriptURL: URL?
    var media: MediaInfo
    var sourceRange: TimeRange     // ★ 설교 구간 (원본 파일 기준 초)
    var segments: [TranscriptSegment]
    var manuscriptSentences: [ManuscriptSentence]
    var silences: [TimeRange]
    var settings: ExportSettings
    var createdAt: Date
    var updatedAt: Date
}

struct TimeRange: Codable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
}
```

### ★ 타임스탬프 규약 — 어기면 전체가 어긋난다

> **프로젝트 내 모든 시간값은 예외 없이 "원본 영상 파일의 0초" 기준이다.**

- whisper는 잘라낸 wav를 받으므로 0초부터 시작하는 상대 시간을 돌려준다.
- `TranscriptParser`가 파싱하는 **바로 그 지점에서** `+ sourceRange.start`를 적용해 절대 시간으로 변환한다. 이후 코드 어디에서도 다시 보정하지 않는다.
- `silencedetect`도 동일하게 잘라낸 오디오를 쓰므로 같은 보정이 필요하다.
- UI에 표시하는 타임코드는 원본 기준(`00:23:14`)으로 보여준다. Final Cut에서 원본을 열었을 때 값이 일치해야 하기 때문이다.
- 단위 테스트를 반드시 작성한다: `sourceRange.start = 1234.5`일 때 전사 첫 세그먼트가 `1234.5 + whisper값`인지 검증.

```swift

struct MediaInfo: Codable {
    var durationSeconds: Double
    var frameRateNum: Int          // 예: 30000
    var frameRateDen: Int          // 예: 1001
    var timescale: Int             // FCPXML용, 예: 30000
    var width: Int
    var height: Int
    var hasAudio: Bool
}

struct TranscriptSegment: Codable, Identifiable {
    var id: String                 // "T14"
    var start: Double              // 초
    var end: Double
    var text: String
    var words: [WordTiming]?
    // 정렬 결과
    var matchedManuscriptID: String?
    var alignStatus: AlignStatus   // matched / unmatched / failed
    var unmatchedReason: UnmatchedReason?
    var confidence: Double?
    // 사용자 결정 (최종 권한)
    var isRemoved: Bool
    var userOverridden: Bool       // 사용자가 AI 제안을 뒤집었는지
}

struct ManuscriptSentence: Codable, Identifiable {
    var id: String                 // "M1"
    var text: String
    var order: Int
}

struct ExportSettings: Codable {
    var transitionDuration: Double = 1.0   // 초
    var padHead: Double = 0.25             // 컷 앞 여유
    var padTail: Double = 0.25
    var snapToSilence: Bool = true
    var silenceThresholdDB: Double = -35
    var minSilenceDuration: Double = 0.3
    var fallbackToHardCut: Bool = true      // 핸들 부족 시
    var audioGainDB: Double = 12            // Phase 0 실측: 매주 +12dB 적용
}
```

---

## 5. 모듈 구조

```
SermonCut/
├── App/
│   ├── SermonCutApp.swift
│   └── AppState.swift                  @Observable 전역 상태
├── Models/
│   ├── SermonProject.swift
│   ├── TranscriptSegment.swift
│   └── EditDecision.swift
├── Core/
│   ├── Binaries/
│   │   ├── BinaryLocator.swift         ffmpeg/ffprobe/whisper 경로 해석
│   │   └── ProcessRunner.swift         Process 래퍼, 진행률 파싱, 취소 지원
│   ├── Media/
│   │   ├── MediaProbe.swift            ffprobe → MediaInfo
│   │   ├── AudioExtractor.swift        ffmpeg → 16kHz wav (구간 지정)
│   │   ├── WaveformGenerator.swift     파형 피크 배열 생성 + 캐시
│   │   └── SilenceDetector.swift       ffmpeg silencedetect 파싱
│   ├── Transcribe/
│   │   ├── WhisperTranscriber.swift    whisper.cpp 실행 + JSON 파싱
│   │   ├── TranscriptParser.swift      ★ 여기서 sourceRange offset 적용
│   │   └── QuickScanner.swift          base 모델 전체 스캔 (구간 자동 찾기)
│   ├── Manuscript/
│   │   ├── ManuscriptLoader.swift      확장자 분기
│   │   ├── HwpxParser.swift            ★ hwpx (OWPML) 파싱
│   │   ├── DocxParser.swift
│   │   └── SentenceSplitter.swift      한국어 문장 분할
│   ├── Align/
│   │   ├── LocalAligner.swift          n-gram + 단조 DP 정렬
│   │   ├── AIAligner.swift             애매 구간만 AI 호출
│   │   └── AlignmentMerger.swift       1+2단계 결과 병합
│   ├── AI/
│   │   ├── AIProvider.swift            protocol
│   │   ├── ClaudeProvider.swift
│   │   ├── DeepSeekProvider.swift
│   │   ├── OpenAICompatibleProvider.swift
│   │   └── KeychainStore.swift
│   ├── Edit/
│   │   ├── EDLBuilder.swift            킵 구간 계산 (아래 6절 로직)
│   │   ├── FrameSnapper.swift          프레임 경계 양자화
│   │   └── HandleValidator.swift       디졸브 핸들 검증
│   └── Export/
│       ├── FCPXMLExporter.swift
│       └── FFmpegRenderer.swift
├── Views/
│   ├── WelcomeView.swift               파일 선택
│   ├── RangeSelectView.swift           ★ 설교 구간 선택 (파형 + In/Out)
│   ├── WaveformView.swift              Canvas 기반 파형 렌더
│   ├── ManuscriptPickerView.swift      원고 선택 + 미리보기
│   ├── AnalyzeProgressView.swift       단계별 진행률
│   ├── EditorView.swift                메인 (플레이어 + 전사문 리스트)
│   ├── SegmentRowView.swift
│   ├── TimelineStripView.swift
│   ├── ExportSheet.swift
│   └── SettingsView.swift              AI 설정, 바이너리 경로
└── Resources/bin/                      ffmpeg, ffprobe (선택적 번들)
```

---

## 6. 핵심 알고리즘 (정확도가 프로젝트 성패를 좌우)

### 6.0 설교 구간 선택 (RangeSelect)

예배 전체 영상에서 성경본문 낭독 + 설교 부분만 골라내는 단계. 통상 **"대표기도" 순서가 끝난 직후 ~ "봉헌기도" 시작 직전** 구간이다.

#### 파형 생성
```
AVAssetReader로 오디오 트랙을 읽어 PCM 샘플 → 픽셀당 min/max 피크로 다운샘플
→ [Float] 배열을 프로젝트 폴더에 캐시 (재실행 시 재계산 방지)
```
- 120분 영상도 백그라운드에서 수 초~수십 초 내 완료되어야 한다. 전체 디코딩이 느리면 `AVAssetReaderAudioMixOutput`의 샘플레이트를 8kHz로 낮춰서 읽는다.
- 진행률을 표시하고, 파형 생성이 끝나기 전에도 **AVPlayer 스크럽은 즉시 가능**해야 한다.

#### In/Out 지정 UI
| 조작 | 동작 |
|---|---|
| `I` | 현재 재생 위치를 In 으로 |
| `O` | 현재 재생 위치를 Out 으로 |
| 파형 드래그 | 구간 직접 드래그 선택 |
| 마커 드래그 | In/Out 미세 조정 |
| `←` / `→` | 1초 이동 |
| `Shift + ←/→` | 10초 이동 |
| `⌥ + ←/→` | 1프레임 이동 |
| `J` / `K` / `L` | 역재생 / 정지 / 배속재생 (Final Cut 습관 유지) |

선택 구간의 길이와 In/Out 타임코드를 항상 표시한다.

#### [자동 찾기] — 선택 기능
120분을 수동으로 스크럽하는 게 매주 반복되면 고통스럽다. 다음 흐름을 옵션으로 제공한다.

```
1. whisper base 모델(작고 빠름)로 전체 오디오를 저품질 전사
     — 정확도는 낮아도 "대표기도", "봉헌" 같은 명사는 잡힌다
2. 키워드 검색 (사용자가 설정에서 편집 가능, 기본값:
     시작 키워드 = ["대표기도", "대표 기도"]
     종료 키워드 = ["봉헌", "봉헌기도", "헌금"])
3. 매칭 위치를 후보로 제시 → 사용자가 클릭하면 해당 지점으로 이동
4. 사용자가 최종 확정
```
- **자동으로 구간을 확정하지 않는다.** 후보 제시까지만 한다.
- base 모델 전사 결과는 버리지 않고 캐시해두면 재실행 시 즉시 후보를 띄울 수 있다.
- 이 기능은 Phase 2 이후에 붙인다. 없어도 앱은 동작해야 한다.

#### 여유 마진
설교 시작/끝에서 딱 맞춰 자르면 앞뒤가 답답하다. 확정된 In/Out에 기본 **앞 2초, 뒤 3초** 여유를 자동으로 더하되, 설정에서 조정 가능하게 한다. (인트로 디졸브가 들어갈 공간이기도 하다.)

---

### 6.0b hwpx 원고 파싱

설교 원고는 대부분 **hwpx** 파일이다. hwpx는 한글의 XML 기반 개방형 문서 포맷(OWPML)으로, 실체는 **ZIP 아카이브**다.

#### 예상 구조
```
sermon.hwpx
├── mimetype
├── version.xml
├── settings.xml
├── META-INF/
│   ├── container.xml
│   └── manifest.xml
├── Contents/
│   ├── content.hpf        ← 섹션 목록(매니페스트)
│   ├── header.xml         ← 스타일/글꼴 정의
│   ├── section0.xml       ← 본문 (여러 개일 수 있음)
│   ├── section1.xml
│   └── ...
└── BinData/               ← 이미지 등
```

본문 텍스트는 `Contents/section*.xml` 안에 문단(`<hp:p>`) → 런(`<hp:run>`) → 텍스트(`<hp:t>`) 계층으로 들어있는 것으로 알려져 있다.

#### 구현 방침
```
1. ZIP 해제 → Contents/content.hpf 를 먼저 읽어 섹션 파일 목록과 순서를 확보
   (section0, section1... 이름을 가정하지 말 것. 실제 매니페스트를 따른다)
2. 각 섹션 XML을 순서대로 XMLParser로 순회
3. 문단 요소를 만나면 문단 경계로 기록, 텍스트 노드를 이어붙임
4. 문단 단위 문자열 배열 → SentenceSplitter로 문장 분할
5. 스타일/글꼴/이미지/표는 전부 무시 (텍스트만 필요)
```

#### ★ 반드시 실제 파일로 검증할 것
네임스페이스 접두사(`hp:`, `hs:` 등)와 정확한 요소명은 한글 버전에 따라 다를 수 있다. **추측해서 구현하지 말고**, 사용자가 제공하는 실제 설교 원고 hwpx를 받아 다음을 먼저 수행한다.

```bash
unzip -o sermon.hwpx -d /tmp/hwpx_dump
find /tmp/hwpx_dump -type f | sort
xmllint --format /tmp/hwpx_dump/Contents/section0.xml | head -100
```

결과를 보고 실제 요소 구조를 확인한 뒤 파서를 작성하고, 그 결과를 `docs/hwpx-structure.md`로 남긴다.

#### 폴백
파싱에 실패하면 앱을 중단시키지 말고 사용자에게 안내한다.
> "hwpx 파일을 읽지 못했습니다. 한글에서 '다른 이름으로 저장 → 서식 없는 텍스트(.txt)'로 저장한 뒤 다시 시도하거나, 원고 없이 진행할 수 있습니다."

원고 없이 진행하면 AI 정렬을 건너뛰고 전사문만 표시한다. **원고는 어디까지나 보조 입력이며 필수가 아니다.**

#### 원고 전처리
설교 원고에는 본문과 무관한 요소가 섞여 있다. 문장 분할 전에 다음을 제거하거나 별도 표시한다.
- 제목, 부제, 설교자명, 날짜, 본문 성구 표기(`요한복음 3:16`)
- 대괄호/괄호 메모(`[찬송]`, `(잠시 침묵)`)
- 페이지 번호, 머리말/꼬리말성 짧은 줄
- 빈 문단

단, **성경 본문 낭독 부분은 남긴다.** 영상에도 낭독이 포함되므로 정렬에 필요하다.

---

### 6.1 EDL 계산 순서 — 이 순서를 지킬 것

```
1. isRemoved == false 인 세그먼트만 추출
2. 인접(간격 < 0.5초)한 세그먼트끼리 병합 → keepRanges
3. 각 range에 패딩 적용: start -= padHead, end += padTail
4. snapToSilence가 켜져 있으면:
     각 경계를 ±1.0초 내 가장 가까운 무음 구간 중앙으로 이동
5. ★ sourceRange 밖으로 벗어나지 않게 클램프
     첫 range.start = max(start, sourceRange.start)
     마지막 range.end = min(end, sourceRange.end)
6. 디졸브 핸들 검증 (6.2 참고)
7. 프레임 경계로 양자화 (6.3 참고)
8. 최종 EDL 확정
```

**주의**: 5번을 빠뜨리면 패딩이나 무음 스냅 때문에 설교 시작 전(대표기도 끝부분)이나 봉헌기도 앞부분이 결과물에 딸려 들어간다. 사용자가 구간 선택 단계에서 배제한 내용이므로 반드시 잘라내야 한다.

### 6.2 디졸브 핸들 검증 — 가장 흔한 버그 지점

Final Cut의 Cross Dissolve와 ffmpeg의 `xfade`는 **둘 다 편집점 양쪽의 소재를 끌어다 쓴다.** 1초 디졸브면 앞 클립 뒤 0.5초 + 뒤 클립 앞 0.5초가 겹쳐 재생된다. 그 0.5초는 **원래 삭제하려던 구간**일 수 있다.

```
각 컷 지점마다:
  availableHeadHandle = (다음 keepRange.start) - (직전 keepRange.end)
  필요량 = transitionDuration
  if availableHeadHandle < 필요량:
      if fallbackToHardCut: 이 지점만 하드컷 처리 + UI에 ⚠️ 표시
      else: transitionDuration을 availableHeadHandle * 0.8로 축소
```

결과물 총 길이:
- **FCPXML**: 트랜지션은 핸들을 끌어 쓰므로 길이가 줄지 않는다 → `클립 길이 합계` (Phase 0 실측, `docs/fcpxml-reference.md` §5)
- **ffmpeg xfade 렌더**: `클립 길이 합계 − (클립수 − 1) × transitionDuration`
UI의 "예상 최종 길이"는 FCPXML 기준으로 표시한다.

### 6.3 프레임 스냅

Whisper 타임스탬프는 초 단위 float(`184.32`)이지만, FCPXML은 `24024/24000s` 같은 유리수 표기를 쓴다.

```swift
func snapToFrame(_ seconds: Double, info: MediaInfo) -> (num: Int, den: Int) {
    let fps = Double(info.frameRateNum) / Double(info.frameRateDen)
    let frame = (seconds * fps).rounded()
    // timescale 기준 유리수로 변환
    let num = Int(frame) * info.frameRateDen
    return (num, info.frameRateNum / ... )  // 실제 구현 시 기약분수 처리
}
```

**모든** 시간값(클립 offset, duration, transition offset)을 동일 timescale로 통일한다. 하나라도 어긋나면 FCP 임포트 시 DTD 검증에 실패한다.

### 6.4 FCPXML 출력

FCP 10.6+ 기준 구조. `<transition>`은 spine 안에서 두 `<asset-clip>` 사이에 위치하며, 양쪽 클립과 겹친다:

```xml
<spine>
  <asset-clip ref="r2" offset="0s" start="..." duration="..."/>
  <transition name="Cross Dissolve" offset="..." duration="30030/30000s">
    <filter-video ref="rX" name="Cross Dissolve"/>
    <filter-audio ref="rY" name="Audio Crossfade"/>
  </transition>
  <asset-clip ref="r2" offset="..." start="..." duration="..."/>
</spine>
```

**구현 방법 (중요)**: 사양 문서를 추측해서 짜지 말 것. **Phase 0에서 Final Cut Pro로 직접 "클립 3개 + 디졸브 2개" 샘플 프로젝트를 만들어 XML로 내보내고, 그 파일을 템플릿으로 역설계**한다. `effect` 리소스의 `uid`는 FCP 버전마다 다를 수 있으므로 실제 내보낸 파일에서 가져온다.

### 6.5 ffmpeg 프리뷰 렌더

```bash
# 세그먼트 N개 → xfade 체이닝
ffmpeg -i input.mov \
  -filter_complex "
    [0:v]trim=start=0:end=182.4,setpts=PTS-STARTPTS,fps=30000/1001,format=yuv420p[v0];
    [0:a]atrim=start=0:end=182.4,asetpts=PTS-STARTPTS[a0];
    ...
    [v0][v1]xfade=transition=dissolve:duration=1:offset=181.4[vx1];
    [a0][a1]acrossfade=d=1[ax1];
    ..." \
  -map "[vN]" -map "[aN]" -c:v libx264 -crf 28 -preset veryfast -s 960x540 preview.mp4
```

- 프리뷰는 **저해상도/저품질로 빠르게** (컷 타이밍 검수용이므로)
- `xfade`는 두 입력의 해상도·픽셀포맷·프레임레이트·타임베이스가 **완전히 동일**해야 동작하므로, 각 trim 뒤에 `fps`, `format`, `settb=AVTB`를 반드시 붙인다
- 세그먼트가 40~50개면 filter_complex가 매우 길어지므로 **파일로 써서 `-filter_complex_script`로 전달**한다 (명령행 길이 제한 회피)
- 진행률은 `-progress pipe:1` 출력을 파싱해 UI에 표시

### 6.6 설교 목차 (유튜브 챕터) 자동 생성  ★ Phase 0 이후 추가 요구

사용자는 매주 완성본을 들으며 대지(소제목) 시작 시간을 손으로 따서 유튜브 설명란에 넣는다.

```
03:45 1. 위기의 순간 드러나는 참신앙
18:15 2."죽으면 죽으리이다"의 각오로
28:14 3. 죽기를 각오한 기도
31:06 4. 죽고자 하면 사는 역설의 신앙
```

이 목록을 앱이 **제안**하고 사용자가 확인·수정 후 복사한다. 시간은 **출력 타임라인 기준**(인트로 10초 포함)이다.

#### 신호원 (확신도 높은 순, 결과를 교차 검증)
1. **원고 소제목 + 정렬** — hwpx의 `** 소제목` 문단이 곧 목차 제목이다(실측: 글자까지 동일). 각 소제목 **바로 다음 원고 문장**이 매칭된 전사 세그먼트의 시작 시간 = 대지 시작(원본 기준).
2. **화면 목차 오버레이 (OBS)** — 녹화 원본 우하단에 목차 박스가 있고 현재 대지가 흰색, 나머지가 회색이다. 1초 간격 프레임을 `Vision`(`VNRecognizeTextRequest`, 한국어)으로 읽어 **강조 줄이 바뀌는 시점**과 제목 텍스트를 얻는다. 원고가 없어도 동작한다. 영역 좌표는 설정값(기본 x1320 y540 w600 h340 @1080p).
3. **AI 제안** — 원고도 오버레이도 없을 때만. 전사문을 주고 대지 구분 후보를 받는다.

#### 원본 시간 → 출력 시간 변환
최종 EDL(6.1 결과)로 매핑: 원본 시간 t가 킵 구간 i 안에 있으면 `출력 = introDuration + offset_i + (t − start_i)`. 삭제 구간 안에 떨어지면 **다음 킵 구간 시작**으로 민다. 편집점 ±1초 이내면 편집점에 붙이고, 아니면 초 단위 내림.

#### 출력 형식
- `MM:SS 번호. 제목` (1시간 이상이면 `H:MM:SS`)
- 유튜브 챕터는 **첫 항목이 00:00**이어야 활성화된다 → 옵션으로 `00:00 성경 봉독`(또는 사용자가 정한 문구) 자동 삽입 체크박스 제공
- FCPXML에도 같은 위치에 `<chapter-marker>`를 넣는 옵션 (FCP 공유 시 챕터 유지)
- UI: 에디터 우측에 "목차" 탭 — 각 항목 클릭 시 해당 위치 재생, 시간 ±1초 미세조정, [복사] 버튼

### 6.7 썸네일 자동 생성  ★ Phase 0 이후 추가 요구

템플릿: `2026-주일낮예배 설교-Title.psd` (2560×1440, Photoshop 2022). 텍스트 레이어:
- `제목` 그룹 안 `제목 1줄` / `제목 2줄` (둘 중 하나만 표시)
- `강해내용 | 설교본문` — 예: `에스더 4장 1~17절`
- 예배 구분 레이어들 (`주일낮예배 설교`, `특별예배 설교 / 부활절` 등 — 표시 여부로 선택)
- 글꼴: SF함박눈(제목), Pretendard (시스템에 설치됨)

제목·본문은 **hwpx 원고의 `제  목 :` / `본  문 :` 줄에서 자동으로 채운다** (시리즈 번호 `(7)`은 제거, 사용자 수정 가능).

구현 방식 (Phase 6에서 결정):
- **A안 (권장, 원본과 100% 동일)**: 설치된 Photoshop을 AppleScript `do javascript`로 구동 → PSD 열기 → 텍스트 교체, 1줄/2줄 그룹 토글 → JPG 2560×1440 저장 → 닫기(원본 PSD 저장 안 함). 외부 프로세스 실행이므로 `ProcessRunner`(`osascript`) 경유.
- **B안 (Photoshop 없이)**: PSD에서 배경(텍스트 제외 합성본)을 1회 PNG로 뽑아 두고, CoreText로 같은 글꼴·위치에 글자를 그린다. 레이어 효과(그림자 등) 재현 정도는 확인 필요.
- 제목 줄바꿈(1줄/2줄)은 글자 폭을 재서 자동 결정하되 사용자가 바꿀 수 있게 한다.

---

## 7. UI 설계

### 7.0 구간 선택 화면 (1단계)

```
┌───────────────────────────────────────────────────────────────┐
│ 20260920_주일예배.mov │ 1:48:32 │ 1920x1080 │ 29.97fps        │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│                      AVPlayer (프리뷰)                        │
│                                                               │
├───────────────────────────────────────────────────────────────┤
│         ▌I                                      O▐            │
│ ▁▃▅▂▁▇▅▃▁▂▅█▇▅▃▂▅▇█▆▄▂▃▅▇█▇▅▃▂▁▃▅▂▁▇▅▃▁▂▅█▇▅▃▂▁▃▅▂▁▇▅▃▁    │
│ 0:00        30:00        1:00:00       1:30:00               │
│              └────── 선택 구간 (하이라이트) ──────┘            │
├───────────────────────────────────────────────────────────────┤
│ In 00:24:13   Out 01:16:48   길이 52:35                       │
│ 여유 앞[2.0]초 뒤[3.0]초                                       │
│ [🔍 설교 구간 자동 찾기]              [다음 → 원고 선택]       │
└───────────────────────────────────────────────────────────────┘
```

자동 찾기 실행 시 파형 위에 후보 마커를 표시한다.
```
  ▼대표기도 후보(00:22:40)          ▼봉헌 후보(01:17:02)
 ▁▃▅▂▁▇▅▃▁▂▅█▇▅▃▂▅▇█▆▄▂▃▅▇█▇▅▃▂▁▃▅▂▁▇▅▃▁▂▅█▇▅▃▂▁▃▅▂▁▇▅▃▁
```

### 7.1 메인 에디터

```
┌───────────────────────────────────────────────────────────────┐
│ 20260920_주일설교.mov  │ 50:12 │ 1920x1080 │ 29.97fps        │
├─────────────────────────┬─────────────────────────────────────┤
│                         │ 🔍 [검색............]  [전체][삭제만]│
│                         │ ┌─────────────────────────────────┐ │
│      AVPlayer           │ │ 03:04  우리는 은혜를 베풀어…    │ │
│      (현재 위치 하이라이트)│ ├─────────────────────────────────┤ │
│                         │ │ 03:09  어… 그러니까 저기…  [필러]│ │← 회색
│                         │ ├─────────────────────────────────┤ │
│                         │ │ 03:14  오늘 날씨가 참…   ⚠즉흥 │ │← 회색+노랑
├─────────────────────────┤ ├─────────────────────────────────┤ │
│ ▓▓▓░░▓▓▓▓░▓▓▓▓▓▓▓▓▓▓▓▓ │ │ 03:22  하나님께서는 우리를…    │ │
│ 타임라인 (회색=삭제)     │ └─────────────────────────────────┘ │
├─────────────────────────┴─────────────────────────────────────┤
│ 유지 42개 / 삭제 18개 │ 예상 38:24 (−11:48) │ ⚠핸들 부족 2곳  │
│ 디졸브 [1.0]초  ☑무음스냅  패딩[0.25]초                       │
│                    [FCPXML 내보내기]  [프리뷰 렌더]            │
└───────────────────────────────────────────────────────────────┘
```

### 7.2 필수 인터랙션
| 동작 | 키/조작 |
|---|---|
| 세그먼트 선택 이동 | ↑ / ↓ |
| 삭제/복원 토글 | `D` 또는 `Delete` |
| 현재 세그먼트 재생 | `Space` |
| 다중 선택 | `Shift + 클릭` / `⌘ + 클릭` |
| 선택 일괄 삭제 | `⌘ + Delete` |
| 실행 취소 | `⌘ + Z` (**Undo 스택 필수**) |
| 저장 | `⌘ + S` |

50분 영상을 훑는 작업이라 **마우스 없이 키보드만으로 완주 가능**해야 한다. 이게 실사용 품질을 결정한다.

### 7.3 세그먼트 행 시각 규칙
| 상태 | 표현 |
|---|---|
| 유지 | 흰 배경, 검정 텍스트 |
| 삭제 (AI 자동) | 회색 배경, 취소선, 우측에 사유 뱃지 |
| 삭제 (사용자) | 회색 배경, 취소선, 뱃지 없음 |
| 확인 필요 | 회색 + 노란 좌측 보더 |
| 현재 재생 위치 | 파란 좌측 보더 |
| 정렬 실패 | 흰 배경 + 회색 점선 보더 |

---

## 8. 개발 규칙 (→ `CLAUDE.md`에 복사)

### 8.1 커밋
- **모든 커밋 메시지는 한국어로 작성한다.**
- 형식: `<타입>: <한국어 요약>`
  - 타입: `기능`, `수정`, `리팩터`, `문서`, `설정`, `테스트`, `성능`
  - 예: `기능: 원고-전사문 로컬 정렬 알고리즘 구현`
  - 예: `수정: 디졸브 핸들 부족 시 하드컷 폴백 처리`
- 본문이 필요하면 빈 줄 후 한국어로 `- ` 불릿 나열.
- **기능 단위가 완성될 때마다 커밋**한다. 파일 하나 고칠 때마다 커밋하지 말고, 빌드가 통과하고 동작이 검증된 시점에 커밋한다.
- Phase가 완료되면 태그를 단다: `v0.1-phase1` 형식.

### 8.2 코드
- Swift Concurrency 사용. 완료 핸들러 콜백 패턴 금지.
- 외부 프로세스 실행은 전부 `ProcessRunner`를 경유한다. 각 호출부에서 `Process`를 직접 만들지 않는다.
- 모든 장시간 작업은 **취소 가능**해야 한다 (`Task.checkCancellation()`).
- 에러는 삼키지 않는다. `SermonCutError` enum으로 정의하고 사용자에게 **한국어 메시지**로 표시한다.
- 강제 언래핑(`!`) 금지. `guard let` / `throws` 사용.
- 시간 계산에 `Double`을 쓰되, **출력 직전 반드시 프레임 양자화**를 거친다.

### 8.3 금지 사항
- API 키를 코드, 로그, 프로젝트 파일, 테스트 픽스처에 하드코딩 금지.
- `.env` 파일을 앱 번들에 포함 금지 (Keychain 사용).
- 원본 영상 파일을 **절대 수정하거나 이동하지 않는다.** 읽기 전용으로만 접근.
- AI 정렬 결과를 사용자 확인 없이 렌더에 직접 반영 금지.

### 8.4 진행 방식
- Phase를 건너뛰지 않는다. 각 Phase 완료 시 **실제 50분 영상으로 검증**하고 결과를 보고한다.
- 불확실한 사양(FCPXML 구조 등)은 추측하지 말고 **실제 파일을 만들어 확인**한다.
- 새 서드파티 의존성 추가 전에 반드시 물어본다.

---

## 9. 구현 단계

### Phase 0 — 검증 (다른 것보다 먼저)
- [x] ~~샘플 프로젝트~~ → 실제 09/13 완성 편집본(클립 6개 + 디졸브 5개 + 인트로/아웃트로) FCPXML 1.14로 대체
- [ ] 생성한 XML(`samples/fcpxml/roundtrip-test.fcpxml`) 임포트 → 의도대로 반영되는지 확인
- [x] 결과를 `docs/fcpxml-reference.md`로 정리 (effect uid, timescale, transition 위치 규칙)
- [ ] 여기서 막히면 진행 중단하고 보고

### Phase 0b — hwpx 구조 분석
- [x] 사용자에게 실제 설교 원고 hwpx 파일을 요청
- [x] `unzip`으로 해제해 내부 구조 확인 (6.0b절 명령 참고)
- [x] `docs/hwpx-structure.md` 작성 — 실제 요소명/네임스페이스 기록
- [ ] Phase 0과 병행 가능

### Phase 1 — CLI 프로토타입
- [ ] `ProcessRunner`, `BinaryLocator`
- [ ] `MediaProbe`, `AudioExtractor`(구간 지정), `SilenceDetector`
- [ ] `WhisperTranscriber` + `TranscriptParser` (**sourceRange offset 적용 + 단위 테스트**)
- [ ] `ManuscriptLoader` / `HwpxParser` / `DocxParser` / `SentenceSplitter`
- [ ] `LocalAligner` (AI 없이 n-gram DP 정렬만)
- [ ] `EDLBuilder` + `FrameSnapper` + `HandleValidator` (sourceRange 클램프 포함)
- [ ] `FCPXMLExporter`
- [ ] 이 단계에서 구간은 CLI 인자로 하드코딩 (`--in 00:24:13 --out 01:16:48`)
- [ ] **검증**: 실제 이번 주 예배 영상 + hwpx 원고로 end-to-end 실행, FCP 임포트 성공
- 태그: `v0.1-phase1`

### Phase 2 — SwiftUI 앱 (구간 선택 포함)
- [ ] `WelcomeView` — 영상 파일 선택
- [ ] `WaveformGenerator` + `WaveformView` — 파형 렌더 및 캐시
- [ ] `RangeSelectView` — In/Out 마커, J/K/L, 프레임 단위 이동
- [ ] `ManuscriptPickerView` — hwpx/docx/txt 선택 + 파싱 결과 미리보기
- [ ] `AnalyzeProgressView` — 단계별 진행률, 취소
- [ ] `EditorView` — 세그먼트 리스트, 토글, 키보드 단축키, Undo
- [ ] 타임라인 스트립
- [ ] 프로젝트 저장/불러오기 (`.sermoncut`)
- 태그: `v0.2-phase2`

### Phase 3 — AI 정렬
- [ ] 설정 화면 + Keychain
- [ ] `AIProvider` 3종 + 연결 테스트
- [ ] `AIAligner` (청킹, 재시도, 실패 격리)
- [ ] 자동 마킹 + 사유 뱃지 UI
- [ ] 예상 비용 표시
- 태그: `v0.3-phase3`

### Phase 4 — 출력 완성
- [ ] `FFmpegRenderer` (프리뷰, 진행률, 취소)
- [ ] FCPXML 내보내기 후 FCP 자동 실행 옵션
- [ ] 핸들 부족 경고 UI
- 태그: `v0.4-phase4`

### Phase 5 — 구간 자동 찾기
- [ ] `QuickScanner` — whisper base 모델 전체 스캔 + 결과 캐시
- [ ] 키워드 설정 UI (기본값: 대표기도 / 봉헌)
- [ ] 파형 위 후보 마커 표시
- 태그: `v0.5-phase5`

### Phase 5b — 설교 목차 (6.6절)
- [ ] `ChapterBuilder` — 원고 소제목 + 정렬 결과 → 원본 시간
- [ ] `OverlayChapterDetector` — Vision OCR로 화면 목차 강조 변화 검출
- [ ] EDL 기반 원본→출력 시간 변환 + 편집점 스냅
- [ ] 목차 탭 UI, 복사, FCPXML `chapter-marker` 옵션
- **검증**: 09/13 영상으로 사용자 수작업 목차(03:45 / 18:15 / 28:14 / 31:06)와 ±1초 일치

### Phase 6 — 인트로/아웃트로/썸네일
실제 구조(Phase 0 실측, `docs/fcpxml-reference.md` §3):
- 인트로: 썸네일 jpg 10.067초 + 연결 오디오 `갓피플NCB-ToTheLord-10s.mp3`, 맨 앞 교차 디졸브(페이드인), 설교 첫 클립과 **색상으로 페이드** 2.467초
- 아웃트로: 마지막 설교 클립 끝부분에 연결 오디오 `갓피플NCB-Hope-15s.mp3`, **색상으로 페이드** 1.6초 → `end-poster-YYYY.jpg` 14.7초 → 끝 교차 디졸브(페이드아웃)
- 설교 오디오 **+12dB** (`ExportSettings.audioGainDB`)
- 데이터 모델에 `headClip`, `tailClip`, `bgmTrack` 필드를 **Phase 1부터 미리 넣어둔다** (값은 nil 허용).
- 에셋(mp3, end-poster)은 설정에 "템플릿 폴더"로 등록. end-poster는 매년 바뀌므로 파일 선택 가능하게.
- [ ] 썸네일 자동 생성 (6.7절)
- [ ] 최종 mp4 렌더 옵션: Compressor 설정과 동일하게 H.264 Main 5,000kbps / AAC 128k / 썸네일 커버 첨부 (`docs/fcpxml-reference.md` §8)

---

## 10. Claude Code 시작 프롬프트

아래를 그대로 Claude Code에 입력한다.

```
이 저장소에서 macOS 앱 "SermonCut"을 개발한다.

먼저 SPEC.md를 처음부터 끝까지 읽어라. 그 다음 SPEC.md의 8절
"개발 규칙"을 CLAUDE.md로 복사해 저장하고, .gitignore를 생성해라
(.env, *.xcuserdatad, DerivedData, *.sermoncut 샘플, 대용량 미디어 제외).

그리고 Phase 0과 Phase 0b부터 시작한다. 두 단계 모두 내가 직접 파일을
줘야 하는 작업이니, 내가 무엇을 해야 하는지 구체적인 단계로 알려주고
대기해라.

- Phase 0: 내가 Final Cut Pro에서 샘플 프로젝트를 만들어 FCPXML을 준다
           → docs/fcpxml-reference.md 작성
- Phase 0b: 내가 실제 설교 원고 hwpx 파일을 준다
           → unzip해서 구조 분석 후 docs/hwpx-structure.md 작성

규칙:
- 커밋 메시지는 한국어, 기능 단위로만
- Phase를 건너뛰지 말 것
- 불확실한 사양(FCPXML 구조, hwpx 내부 XML)은 추측하지 말고
  실제 파일을 확인한 뒤 구현할 것
- 타임스탬프는 무조건 원본 영상 0초 기준 (SPEC.md 4절 규약 준수)
- 새 의존성 추가 전 승인받을 것
```

---

## 11. 알려진 불확실 요소 (구현 중 확인 필요)

| 항목 | 확인 방법 |
|---|---|
| FCPXML DTD 버전 및 `effect` uid | Phase 0에서 실제 내보낸 파일로 확인 |
| **hwpx 내부 XML의 정확한 요소명/네임스페이스** | Phase 0b에서 실제 원고 파일을 `unzip`해 확인. 문서의 구조 설명은 일반적으로 알려진 형태이며 한글 버전별 차이가 있을 수 있음 |
| 120분 영상의 파형 생성 소요 시간 | Phase 2에서 실측. 너무 느리면 샘플레이트를 낮추거나 ffmpeg PCM 덤프로 전환 |
| whisper base 모델이 "대표기도"/"봉헌"을 잡아내는지 | Phase 5에서 실측. 못 잡으면 small 모델로 상향하거나 이 기능 자체를 폐기 |
| whisper large-v3 한국어 설교 정확도 | Phase 1에서 실측. 성경 인명/지명 오인식은 예상되나 **컷 위치 인덱스 용도이므로 허용 범위** |
| Apple SpeechAnalyzer(macOS 26) 한국어 지원 | `SpeechTranscriber.supportedLocales`를 런타임에 출력해 확인. 지원되면 whisper 대체 검토 (모델 번들 불필요해짐) |
| DeepSeek API의 JSON 강제 출력 안정성 | Phase 3에서 실측. 불안정하면 파싱 실패 시 재시도 + 폴백 로직 강화 |
| 50분 전사문 정렬 시 실제 API 비용 | Phase 3에서 로컬 정렬로 걸러진 후 남는 청크 수로 실측 |
