#!/bin/bash
# ============================================================
# transcribe.sh — 회의 녹음 → 스크립트(전사) + 회의록(정리본) 자동 생성
#
# 사용법:
#   transcribe <오디오파일>
#     - 절대/상대 경로, 또는 ~/Desktop/meeting-notes/recordings/ 안의 파일명
#     - 음성메모 .m4a 포함 ffmpeg이 읽는 모든 포맷 지원
#
# 파이프라인:
#   1) ffmpeg     : 16kHz mono WAV 변환
#   2) whisper    : large-v3 한국어 전사 → transcripts/*.txt, *.srt
#   3) Claude Opus: 용어집 교정 + 양식 기반 회의록 → minutes/*.md
#
# 환경변수:
#   WHISPER_MODEL  다른 모델 파일 사용 시 경로 지정
#                  (예: 양자화 모델 ggml-large-v3-q5_0.bin 으로 교체)
# ============================================================

set -euo pipefail

BASE="$HOME/Desktop/meeting-notes"
RECORDINGS="$BASE/recordings"
TRANSCRIPTS="$BASE/transcripts"
MINUTES="$BASE/minutes"
MODEL="${WHISPER_MODEL:-$BASE/models/ggml-large-v3.bin}"
GLOSSARY="$BASE/config/glossary.txt"
TEMPLATE="$BASE/config/template.md"

# whisper --prompt 주입 한도 (~224토큰 안전선)
PROMPT_MAX_TERMS=40
PROMPT_MAX_CHARS=350

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\033[1;31m[오류]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
사용법: transcribe <오디오파일>

  <오디오파일>: 경로 또는 ~/Desktop/meeting-notes/recordings/ 안의 파일명
    예) transcribe 주간회의.m4a
        transcribe ~/Downloads/녹음.m4a

  결과물:
    ~/Desktop/meeting-notes/transcripts/  스크립트 원본 (.txt, .srt)
    ~/Desktop/meeting-notes/minutes/      회의록 정리본 (.md)

  긴 녹음(30분 이상)은 전사에 수 시간 걸릴 수 있습니다. 백그라운드 실행 권장:
    nohup transcribe 파일명.m4a > ~/Desktop/meeting-notes/transcripts/작업로그.log 2>&1 &
EOF
  exit 1
}

[ $# -ge 1 ] || usage
case "$1" in -h|--help) usage ;; esac

# ---------- 0. 사전 점검 ----------
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg 미설치. 실행: brew install ffmpeg"
command -v whisper-cli >/dev/null 2>&1 || die "whisper-cli 미설치. 실행: brew install whisper-cpp"

CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
if [ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.npm-global/bin/claude" ]; then
  CLAUDE_BIN="$HOME/.npm-global/bin/claude"
fi
[ -n "$CLAUDE_BIN" ] || die "claude CLI를 찾을 수 없습니다."

if [ ! -f "$MODEL" ]; then
  die "whisper 모델이 없습니다: $MODEL
  다운로드: curl -L -o '$BASE/models/ggml-large-v3.bin' \\
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin'"
fi

# ---------- 1. 입력 파일 해석 ----------
INPUT="$1"
if [ ! -f "$INPUT" ]; then
  if [ -f "$RECORDINGS/$INPUT" ]; then
    INPUT="$RECORDINGS/$INPUT"
  else
    die "파일을 찾을 수 없습니다: $1 (recordings/ 안에서도 못 찾음)"
  fi
fi
INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"

NAME="$(basename "$INPUT")"
NAME="${NAME%.*}"
MEET_DATE="$(stat -f '%Sm' -t '%Y-%m-%d' "$INPUT")"
MEET_DATETIME="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$INPUT")"

DUR_SEC="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT" 2>/dev/null | cut -d. -f1 || echo 0)"
DUR_MIN=$(( (DUR_SEC + 59) / 60 ))

log "입력: $INPUT (길이 약 ${DUR_MIN}분, 녹음일 $MEET_DATETIME)"
if [ "$DUR_SEC" -gt 1800 ]; then
  log "※ large-v3는 이 Intel CPU에서 느립니다. ${DUR_MIN}분 녹음은 수 시간 걸릴 수 있음 — 백그라운드 실행 권장 (transcribe --help 참고)"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
WAV="$WORKDIR/audio.wav"

# ---------- 2. ffmpeg 변환 ----------
log "1/3 ffmpeg: 16kHz mono WAV 변환 중..."
ffmpeg -y -hide_banner -loglevel error -i "$INPUT" -ar 16000 -ac 1 -c:a pcm_s16le "$WAV"

# ---------- 3. whisper 전사 ----------
# glossary 상단부터 1번째 칸(올바른 표기)을 추출해 초기 프롬프트로 주입
PROMPT_TERMS=""
TERM_COUNT=0
if [ -f "$GLOSSARY" ]; then
  while IFS= read -r line; do
    term="${line%%|*}"
    term="$(printf '%s' "$term" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -z "$term" ] || [ "${term#\#}" != "$term" ]; then continue; fi
    if [ -n "$PROMPT_TERMS" ]; then
      candidate="$PROMPT_TERMS, $term"
    else
      candidate="$term"
    fi
    if [ "${#candidate}" -gt "$PROMPT_MAX_CHARS" ]; then break; fi
    PROMPT_TERMS="$candidate"
    TERM_COUNT=$((TERM_COUNT + 1))
    if [ "$TERM_COUNT" -ge "$PROMPT_MAX_TERMS" ]; then break; fi
  done < "$GLOSSARY"
fi

OUT_BASE="$TRANSCRIPTS/${MEET_DATE}_${NAME}"
WHISPER_ARGS=(-m "$MODEL" -l ko -otxt -osrt -of "$OUT_BASE")
if [ -n "$PROMPT_TERMS" ]; then
  WHISPER_ARGS+=(--prompt "$PROMPT_TERMS" --carry-initial-prompt)
  log "용어집 프롬프트 주입: ${TERM_COUNT}개 용어"
fi

log "2/3 whisper 전사 시작 (large-v3, 한국어) — 진행되는 대로 문장이 출력됩니다"
START_TS=$(date +%s)
if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -i whisper-cli "${WHISPER_ARGS[@]}" "$WAV"
else
  whisper-cli "${WHISPER_ARGS[@]}" "$WAV"
fi
log "전사 완료 ($(( ($(date +%s) - START_TS) / 60 ))분 소요) → ${OUT_BASE}.txt / .srt"

[ -s "${OUT_BASE}.txt" ] || die "전사 결과가 비어 있습니다: ${OUT_BASE}.txt"

# ---------- 4. Claude Opus 회의록 작성 ----------
MINUTES_FILE="$MINUTES/회의록_${MEET_DATE}_${NAME}.md"
if [ -e "$MINUTES_FILE" ]; then
  MINUTES_FILE="$MINUTES/회의록_${MEET_DATE}_${NAME}_$(date +%H%M%S).md"
fi

log "3/3 Claude(Opus) 회의록 작성 중..."
{
  cat <<EOF
너는 회의록 작성 담당자다. 아래 [회의 스크립트]는 whisper 음성 전사 원문이라 잘못 전사된 단어가 섞여 있을 수 있다.

작성 규칙:
1. [용어집]을 참고해 오전사된 용어를 올바른 표기로 교정해 반영하라. (형식: 올바른 표기 | 흔한 오전사 | 설명)
2. [회의록 양식]의 구조를 그대로 따라 회의록을 작성하라.
   - {회의명}: 스크립트 내용에서 유추하되, 불명확하면 "$NAME" 사용
   - {날짜}: $MEET_DATETIME
3. 스크립트에 없는 내용을 지어내지 마라. 참석자를 알 수 없으면 "(수기 기입)"으로 남기고,
   결정사항·액션 아이템이 스크립트에 없으면 해당 표에 "해당 없음"이라고 적어라.
4. 출력은 완성된 회의록 마크다운 본문만. 코드펜스(\`\`\`)나 앞뒤 설명 문구를 붙이지 마라.

[회의록 양식]
$(cat "$TEMPLATE")

[용어집]
$(cat "$GLOSSARY")

[회의 스크립트]
$(cat "${OUT_BASE}.txt")
EOF
} | "$CLAUDE_BIN" -p --model opus > "$MINUTES_FILE"

[ -s "$MINUTES_FILE" ] || die "회의록 생성 실패(빈 출력). 전사 원본은 보존됨: ${OUT_BASE}.txt"

log "완료!"
echo ""
echo "  스크립트 원본 : ${OUT_BASE}.txt"
echo "                  ${OUT_BASE}.srt (타임스탬프)"
echo "  회의록 정리본 : $MINUTES_FILE"
