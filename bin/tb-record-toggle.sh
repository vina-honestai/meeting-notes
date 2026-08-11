#!/bin/bash
# ============================================================
# tb-record-toggle.sh — 터치바 '회의 녹음' 토글 버튼
#
# 첫 실행  : 마이크 녹음 시작 → recordings/회의_<일시>.wav
# 재실행   : 녹음 종료 → transcribe.sh 자동 실행(백그라운드)
#            → transcripts/ 스크립트 + minutes/ 회의록
#
# 호출 주체: ~/Library/Services/회의 녹음.workflow (터치바 빠른 실행)
#           터미널에서 직접 실행해도 동일하게 동작.
# 상태/로그: .tb-rec/state, .tb-rec/ffmpeg.log
# ============================================================

set -u

# 워크플로우 러너는 PATH가 비어 있으므로 직접 지정
export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.npm-global/bin:$PATH"

BASE="$HOME/Desktop/meeting-notes"
RECORDINGS="$BASE/recordings"
STATE_DIR="$BASE/.tb-rec"
STATE="$STATE_DIR/state"            # 형식: <ffmpeg pid>|<파일경로>|<시작epoch>
FFLOG="$STATE_DIR/ffmpeg.log"
MIC_DEVICE=":MacBook Pro 마이크"    # avfoundation 입력 장치 (외장 마이크는 이름 변경)
MIN_SECS=10                         # 이보다 짧은 녹음은 전사 생략 (더블탭 오작동 방지)
INDICATOR="$HOME/bin/meeting-rec-indicator"   # 메뉴바 표시기 (없어도 녹음은 정상 동작)

notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }

mkdir -p "$STATE_DIR" "$RECORDINGS"

# ---------- 녹음 중이면: 종료 → 전사 ----------
if [ -f "$STATE" ]; then
  IFS='|' read -r PID FILE START < "$STATE"
  rm -f "$STATE"

  if kill -0 "$PID" 2>/dev/null; then
    kill -INT "$PID"                                  # SIGINT = ffmpeg 정상 종료(파일 마무리)
    for _ in $(seq 1 50); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$PID" 2>/dev/null && kill -9 "$PID"

    DUR=$(( $(date +%s) - START ))
    if [ "$DUR" -lt "$MIN_SECS" ]; then
      notify "회의 녹음" "종료 (${DUR}초) — 너무 짧아 전사 생략: $(basename "$FILE")"
      exit 0
    fi

    notify "회의 녹음" "종료 ($((DUR/60))분 $((DUR%60))초) — 전사 시작: $(basename "$FILE")"
    LOG="$BASE/transcripts/작업로그_$(basename "${FILE%.wav}").log"
    (
      "$BASE/bin/transcribe.sh" "$FILE" >"$LOG" 2>&1 &
      TPID=$!
      # 메뉴바 표시기가 읽는 전사 상태 파일:
      #   <전사 프로세스 pid>|<작업로그 경로>|<시작 epoch>|<녹음 길이 초>
      # 길이(DUR)를 넘겨야 표시기가 '전사 42%' 진행률을 계산할 수 있다.
      # ※ 서브셸 자신의 pid($BASHPID)는 macOS 기본 bash 3.2 에 없으므로
      #   전사 프로세스의 pid 를 쓴다 — 전사가 죽으면 표시기도 바로 알아챈다.
      echo "$TPID|$LOG|$(date +%s)|$DUR" > "$STATE_DIR/transcribing"
      if wait "$TPID"; then
        notify "회의 녹음" "회의록 완료 → minutes/"
      else
        notify "회의 녹음" "전사 실패 — 로그 확인: ${LOG/#$HOME/~}"
      fi
      rm -f "$STATE_DIR/transcribing"     # 표시기는 이게 사라지면 '완료' 후 스스로 종료
    ) &
    disown
    exit 0
  fi

  # pid가 죽어 있음(강제종료·재부팅 등) → 파일은 보존, 새 녹음으로 진행
  [ -s "$FILE" ] && notify "회의 녹음" "이전 녹음이 비정상 종료됨 — 파일 보존: $(basename "$FILE")"
fi

# ---------- 녹음 시작 ----------
FILE="$RECORDINGS/회의_$(date +%Y-%m-%d_%H%M%S).wav"
nohup ffmpeg -nostdin -hide_banner -f avfoundation -i "$MIC_DEVICE" \
      -ac 1 -ar 16000 "$FILE" >"$FFLOG" 2>&1 </dev/null &
PID=$!
disown

# 고아 프로세스 방지: 상태를 먼저 기록해 두고, 실패 시에만 회수
echo "$PID|$FILE|$(date +%s)" > "$STATE"

sleep 1.5
if kill -0 "$PID" 2>/dev/null; then
  notify "회의 녹음" "녹음 시작 — 다시 누르면 종료 후 회의록 생성"
  # 메뉴바 표시기 기동 (녹음 중 빨간 점멸 + 경과시간 → 이후 전사 진행률까지)
  # 표시 전용이라 실패해도 녹음에는 영향 없음. 중복 방지로 기존 것을 먼저 정리한다.
  pkill -f "$INDICATOR" 2>/dev/null
  [ -x "$INDICATOR" ] && { nohup "$INDICATOR" >/dev/null 2>&1 & disown; }
else
  rm -f "$STATE"
  notify "회의 녹음" "시작 실패 — 마이크 권한 또는 로그 확인: ${FFLOG/#$HOME/~}"
  exit 1
fi
