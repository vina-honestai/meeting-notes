# 회의 녹음 자동화 (meeting-notes)

macOS 음성메모 녹음(.m4a)을 명령어 하나로 **스크립트(원본 전사)** + **회의록(정리본)** 으로 변환.
전 과정 로컬 동작(녹음이 외부로 나가지 않음) — 회의록 작성 단계만 Claude API 사용.

## 사용법

```bash
# 1) 음성메모 앱에서 녹음 → 파일을 recordings/ 로 내보내기 (드래그 또는 공유→파일에 저장)
# 2) 터미널에서:
transcribe 파일명.m4a            # recordings/ 안의 파일명 또는 아무 경로나 가능

# 긴 녹음(30분 이상)은 백그라운드 실행 권장 (수 시간 걸릴 수 있음):
nohup transcribe 파일명.m4a > ~/Desktop/meeting-notes/transcripts/작업로그.log 2>&1 &
tail -f ~/Desktop/meeting-notes/transcripts/작업로그.log   # 진행 확인
```

## 터치바 버튼 (녹음까지 자동)

터치바 '빠른 실행' 안의 **회의 녹음** 버튼: 1탭=녹음 시작, 재탭=종료 후 전사·회의록 자동 생성.
(10초 미만 녹음은 더블탭 오작동으로 보고 전사를 생략)

누를 때마다 터미널 창이 잠깐 떴다가 **약 3초 뒤 스스로 닫힌다** — 정상이다. 이유:

- macOS는 바탕화면·문서·다운로드를 보호구역으로 막는다. 터치바 워크플로우를 실행하는 건
  애플 시스템 프로그램이라, 이런 프로그램엔 TCC가 권한 팝업조차 안 띄우고 그냥 거부한다.
- 그래서 바탕화면의 스크립트를 직접 부르면 **아무 일도 안 일어난다**(에러도 알림도 없음).
  커널 로그: `System Policy: bash deny(1) file-read-data .../Desktop/...`
- 우회: 버튼 → `~/bin/meeting-record-toggle.command`(보호구역 밖) → 터미널 → 실제 스크립트.
  터미널은 바탕화면·마이크 권한을 이미 갖고 있어 통과한다.

창이 스스로 닫히는데도 녹음이 안 죽는 이유: 터미널은 창에 매달린 프로세스가 하나라도 있으면
창을 닫지 않으므로, 실행기가 `setsid`(python3 경유)로 새 세션을 만들어 창과의 연결을 끊고
`nohup`으로 SIGHUP까지 무시시킨다. 그래서 창이 닫혀도 녹음기·whisper·claude 가 계속 돈다.

호출 경로를 바꾸려면 `~/Library/Services/회의 녹음.workflow` 의 `COMMAND_STRING`.

## 메뉴바 표시기 (지금 뭐가 돌고 있는지)

녹음을 시작하면 메뉴바에 표시기가 뜬다. 녹음이 끝나도 사라지지 않고 전사 진행 상황으로 바뀐다.

| 표시 | 상태 |
|------|------|
| ⏺ `12:34` (빨간 점멸) | 녹음 중 + 경과시간 |
| 〰 `전사 42%` | 받아쓰기 중 — 오디오의 몇 %까지 진행됐는지 |
| 〰 `전사 중 02:15` | 받아쓰기 중 (%를 못 구할 때는 경과시간) |
| 📄 `회의록 작성 중` | Claude 가 회의록 정리 중 |
| ✓ `회의록 완료` | 완료 — 8초 뒤 스스로 사라짐 |

아이콘을 클릭하면 메뉴가 열린다: 녹음 중엔 **녹음 종료**(터치바를 다시 누른 것과 동일),
전사 중엔 **작업 로그 열기 / 회의록 폴더 열기**.

**%가 항상 나오지는 않는다.** whisper 는 출력이 파일로 가면 stdout 을 약 4KB씩 모아 쓰기 때문에,
짧은 녹음은 끝날 때까지 진행 줄이 한 줄도 안 나온다. 그럴 때는 `전사 중 M:SS` 로 경과시간을 보여준다.
(긴 회의는 버퍼가 차면서 %가 갱신된다 — 정작 진행률이 필요한 쪽은 긴 회의다.)

- 실행파일: `~/bin/meeting-rec-indicator` (소스 `.swift` 가 옆에 있음, 빌드법은 파일 상단 주석)
- 표시 전용이라 이게 죽어도 녹음·전사는 멀쩡하다. 반대로 녹음이 비정상 종료되면
  표시기가 상태파일을 보고 스스로 사라지므로 '녹음 중' 인 채로 박혀 있지 않는다.

## 결과물

| 위치 | 내용 |
|------|------|
| `transcripts/<날짜>_<파일명>.txt` | 스크립트 원본 (whisper 전사) |
| `transcripts/<날짜>_<파일명>.srt` | 타임스탬프 자막 |
| `minutes/회의록_<날짜>_<파일명>.md` | 회의록 정리본 (Claude Opus, 양식 기반) |

## 파이프라인

```
마이크 → ~/bin/meeting-recorder (16kHz mono WAV)   ← 터치바 버튼으로 녹음할 때
recordings/*.wav|*.m4a
  → 손실 자가점검 (녹음 시간 vs 파일 길이가 5% 이상 어긋나면 경고)
  → ffmpeg (형식 변환만: 16kHz mono WAV)
  → whisper-cli large-v3, 한국어 (-mc 0 : 직전 문장을 다음 구간 힌트로 물려주지 않음)
  → 반복 자가점검 (같은 문장 반복 고장이면 여기서 중단)
  → claude -p --model opus (template.md 양식 + glossary 전체로 오전사 교정)
```

**마이크 녹음에는 ffmpeg 을 쓰지 않는다**(형식 변환에는 계속 쓴다). ffmpeg 의 avfoundation 입력은 마이크 버퍼를 한 칸만 들고
있어서, 읽기가 조금만 늦으면 그 버퍼를 통째로 버린다 — CPU 가 놀고 있어도 소리가 조용히 샌다.
2026-08-11 실측으로 같은 조건 40초 비교에서 **`meeting-recorder` 100.0% vs ffmpeg 91.8%** 였고,
실제 회의에서는 16분 23초를 녹음했는데 파일엔 15분 13초(70초 증발)만 담겼다. 빠진 자리는
그냥 이어붙어서 **재생하면 멀쩡하게 들리지만 단어 조각이 실제로 없다.** `-thread_queue_size`
를 키우거나 리샘플링을 빼도 그대로다 — ffmpeg 옵션으로는 못 고친다.
경위는 `bin/meeting-recorder.swift` 머리말 참고.

**whisper 에 용어집을 힌트(`--prompt`)로 넣지 않는다.** 넣으면 전사가 같은 문장만 끝없이
복사하는 고장에 빠진다 — 2026-08-11 에 15분 회의 전사가 서로 다른 문장 3개로만 채워졌다.
경위와 A/B 재현 결과는 `bin/transcribe.sh` 의 3번 절 주석에 적어 뒀다. 용어 교정은
마지막 Claude 단계가 용어집 전체를 보고 하므로 정확도 손해는 없다.

## 설정 파일

- **`config/glossary.txt`** — 회사 용어집. 형식: `올바른 표기 | 흔한 오전사 | 설명`
  - Claude 후처리 교정에만 사용됨 (순서·개수 제한 없음)
  - **2번째 칸(흔한 오전사)을 채워둘수록 교정이 정확해짐**
- **`config/template.md`** — 회의록 양식(표준형). 수정하면 다음 실행부터 바로 반영.

## 속도가 너무 느리면 (양자화 모델 옵션)

large-v3 풀버전은 Intel CPU에서 느림. 정확도 손실이 미미한 q5_0 양자화 모델로 교체 가능:

```bash
curl -L -o ~/Desktop/meeting-notes/models/ggml-large-v3-q5_0.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"

# 일회성 사용:
WHISPER_MODEL=~/Desktop/meeting-notes/models/ggml-large-v3-q5_0.bin transcribe 파일명.m4a
# 기본값으로 쓰려면 bin/transcribe.sh 의 MODEL 기본 경로를 바꾸면 됨
```

## 이 저장소에서 다시 설치하기 (새 맥 / 복원)

저장소에는 **도구만** 들어 있다. 회의 내용(`recordings/` `transcripts/` `minutes/`)과
2.9GB 음성인식 모델은 `.gitignore` 로 제외돼 있다.

```bash
# 1) 이 폴더를 ~/Desktop/meeting-notes 에 둔다 (스크립트가 이 경로를 기준으로 동작)

# 2) 의존 도구
brew install ffmpeg whisper-cpp        # claude CLI 는 별도 설치·로그인

# 3) 음성인식 모델 내려받기 (~3GB)
curl -L -o models/ggml-large-v3.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"

# 4) 터치바용 실행기·녹음기·메뉴바 표시기를 '바탕화면 밖'에 설치 — ⚠ 이 위치가 중요하다
mkdir -p ~/bin
cp bin/meeting-record-toggle.command ~/bin/ && chmod +x ~/bin/meeting-record-toggle.command
swiftc -O -o ~/bin/meeting-recorder bin/meeting-recorder.swift          # 마이크 녹음기 (필수)
cp bin/meeting-rec-indicator.swift ~/bin/
swiftc -O -o ~/bin/meeting-rec-indicator ~/bin/meeting-rec-indicator.swift

# 5) transcribe 명령 등록
echo 'alias transcribe="$HOME/Desktop/meeting-notes/bin/transcribe.sh"' >> ~/.zshrc
```

**4번을 `~/bin` 이 아닌 바탕화면 안에 두면 터치바 버튼이 조용히 먹통이 된다.**
이유는 위 '터치바 버튼' 절 참고 — macOS 가 바탕화면 접근을 막고 권한 팝업조차 띄우지 않는다.

터치바 빠른 동작(`~/Library/Services/회의 녹음.workflow`)은 이 저장소에 없다.
Automator 로 '빠른 동작'을 만들어 셸 스크립트 실행 액션에 아래를 넣고,
Info.plist 에 `NSRequiredContext > NSPresentationModes = [TouchBar, ServicesMenu]` 를 선언하면 된다.

```bash
open -a Terminal "$HOME/bin/meeting-record-toggle.command"
```

## 문제 해결

- `whisper 모델이 없습니다` → 에러 메시지에 나오는 curl 명령으로 모델(~3GB) 재다운로드
- 회의록이 비어 있음 → `claude` CLI 로그인 상태 확인 (`claude` 실행해 확인)
- 전사 품질 낮음 → glossary.txt에 해당 용어 추가(흔한 오전사 칸까지 채우면 효과 큼)
- `전사가 '같은 문장 반복' 고장에 빠졌습니다` → 자가점검이 걸러낸 것. 회의록은 만들지 않고
  전사 원본만 남는다. `transcripts/*.txt` 를 열어 확인하고, 대개는 녹음이 너무 작거나
  잡음이 큰 게 원인이므로 마이크 위치·입력 볼륨부터 점검할 것
- `⚠ 소리 N% 빠짐` 알림 → 녹음기가 소리를 흘리고 있다는 뜻(재생해선 알 수 없다).
  `~/bin/meeting-recorder` 가 설치돼 있는지 먼저 확인(`ls -l ~/bin/meeting-recorder`).
  없으면 ffmpeg 대체 경로로 녹음된 것이므로 위 4번 빌드 명령으로 녹음기를 설치할 것
- 전사 결과가 부정확함 → 녹음 소리가 작으면(말소리가 배경소음보다 15dB 미만) 정확도가 크게
  떨어진다. 마이크를 화자 쪽으로 두고 시스템 설정 > 사운드 > 입력 볼륨을 올릴 것
