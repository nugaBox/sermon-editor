# 누가의 Sermon Editor

예배 실황 영상에서 **설교만 골라내고, 원고와 맞지 않는 이야기(광고·근황·시사 등)를 덜어낸 편집본**을 만들어 주는 macOS 앱입니다.
결과는 **Final Cut Pro 프로젝트(FCPXML)** 로 넘기거나 바로 **MP4** 로 내보낼 수 있습니다.

![첫 화면](docs-assets/welcome.png)

## 이렇게 씁니다

1. **영상 열기** — 예배 스트리밍 영상(.mp4 / .mov)을 끌어다 놓습니다.
2. **설교 구간 찾기** — [설교 구간 자동 찾기]가 화면 자막(성경 봉독·설교·봉헌)을 읽어 시작·끝을 추천합니다. I / O 키로 직접 고쳐도 됩니다.
3. **원고 선택** — 설교 원고(.hwp, .hwpx, .docx, .txt)를 고릅니다. 없어도 진행할 수 있습니다.
4. **분석** — 음성을 받아쓰고 원고와 맞춰, 원고에서 벗어난 구간을 삭제 후보로 표시합니다. [AI 판정]을 누르면 AI가 한 번 더 가려냅니다.
5. **확인·수정** — 전사문 목록에서 삭제/복원(D 키)하고 타임라인으로 편집점을 확인합니다.
6. **내보내기** — FCPXML(인트로·아웃트로·썸네일·챕터 포함) 또는 최종 MP4.

![설교 구간 선택](docs-assets/range-select.png)

![편집 화면](docs-assets/editor.png)

## 주요 기능

| 기능 | 설명 |
|---|---|
| 설교 구간 자동 찾기 | 화면 자막 OCR과 빠른 음성 인식으로 설교 시작·끝 후보 제시 |
| 원고 대조 | 음성 전사(whisper large-v3)와 원고 문장을 맞춰 원고 밖 구간 표시 |
| AI 탈선 판정 | 원고 밖 구간이 설교 부연인지, 광고·근황·시사 같은 탈선인지 판정 (DeepSeek · Claude · OpenAI 호환) |
| 자연스러운 편집점 | 말과 말 사이 쉼 안에서 자르고 1초 디졸브로 연결 |
| 타임라인 | 확대·축소(⌘+ / ⌘- / 핀치), 스키밍(S), 오디오 스키밍(⇧S) — Final Cut Pro와 같은 단축키 |
| 설교 목차 | 유튜브 챕터용 목차를 원고 소제목·화면 자막에서 자동 생성 |
| 썸네일 | 원고 제목·본문으로 유튜브 썸네일 자동 생성 (배경은 템플릿으로 교체) |
| 내보내기 | Final Cut Pro용 FCPXML, 프리뷰·최종 MP4 렌더 |

원본 영상은 읽기만 하고 절대 수정하지 않습니다. AI 판정 결과도 사용자가 확인한 뒤에만 반영됩니다.

## 설치 (다른 Mac에서)

Apple Silicon(M1 이상) Mac, macOS 14 이상이 필요합니다.

1. [Releases](https://github.com/nugaBox/sermon-editor/releases)에서 `SermonEditor-<버전>.dmg`를 내려받아 엽니다.
2. **누가의 Sermon Editor**를 **Applications** 폴더로 끌어다 놓습니다.
3. DMG 안의 **필수 구성요소 설치.command**를 더블클릭합니다.
   [Homebrew](https://brew.sh)로 ffmpeg·whisper-cpp를 설치하고 음성 인식 모델(약 3.2GB)을 내려받습니다. 처음 한 번만 하면 됩니다.
4. 앱을 처음 열 때 "Apple이 확인할 수 없음" 안내가 나오면
   **시스템 설정 → 개인정보 보호 및 보안** 맨 아래의 **[그래도 열기]** 를 누릅니다. (공증하지 않은 개인 배포 앱이라 처음 한 번 필요합니다)
5. AI 판정을 쓰려면 앱의 **설정(⌘,)** 에서 API 키를 넣습니다. 키는 Mac의 키체인에만 저장됩니다.

썸네일·인트로/아웃트로 템플릿(배경 이미지·음악·끝 화면)은 앱에 들어 있지 않습니다.
쓰던 Mac의 `~/Library/Application Support/SermonCut/templates` 폴더를 같은 위치로 복사하세요.

## 직접 빌드

```bash
scripts/build-app.sh release --install   # /Applications에 설치
scripts/make-dmg.sh                      # 배포용 DMG → build/
swift test                               # 단위 테스트
```

© 2026 NUGABOX. All rights reserved.
