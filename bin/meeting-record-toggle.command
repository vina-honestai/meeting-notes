#!/bin/bash
# ============================================================
# meeting-record-toggle.command — 터치바 '회의 녹음' 중계 실행기
#
# 왜 이 파일이 바탕화면이 아니라 여기(~/bin)에 있나:
#   macOS는 바탕화면·문서·다운로드 폴더를 보호한다. 터치바 워크플로우를
#   실행하는 건 애플 시스템 프로그램(platform binary)인데, 이런 프로그램에는
#   TCC가 권한 팝업조차 띄우지 않고 그냥 거부한다.
#   → 바탕화면에 있는 스크립트를 직접 부르면 '조용히 아무 일도 안 일어남'.
#      (커널 로그: System Policy: bash deny(1) file-read-data .../Desktop/...)
#   이 파일은 보호구역 밖이라 실행기가 읽을 수 있다. 여기서 터미널을 거쳐
#   실제 토글 스크립트를 돌린다 — 터미널은 바탕화면·마이크 권한을 이미 갖고 있다.
#
# 호출 경로: 터치바 → 워크플로우(open -a Terminal) → 이 파일 → tb-record-toggle.sh
# ============================================================

export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.npm-global/bin:$PATH"

TOGGLE="$HOME/Desktop/meeting-notes/bin/tb-record-toggle.sh"
MYTTY="$(tty)"

notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }

if [ ! -x "$TOGGLE" ]; then
  notify "회의 녹음" "토글 스크립트를 찾을 수 없습니다: ${TOGGLE/#$HOME/~}"
  echo "오류: $TOGGLE 이(가) 없거나 실행권한이 없습니다."
  echo "(오류 메시지를 볼 수 있도록 이 창은 자동으로 닫지 않습니다)"
  exit 1
fi

# 녹음·전사를 터미널에서 완전히 분리해 실행.
#
# 왜 nohup 만으로는 부족한가:
#   터미널은 '그 창에 매달린 프로세스가 하나라도 있으면' 창을 닫지 않는다.
#   nohup/disown 은 신호와 잡 목록만 떼어낼 뿐 제어터미널(ctty) 연결은 그대로라,
#   ffmpeg 가 녹음하는 내내 창이 busy 로 남아 자동 닫기가 조용히 실패한다.
#   → setsid 로 새 세션을 만들어 ctty 자체를 끊는다. macOS엔 setsid 명령이 없어 python3 사용.
#
# nohup 도 함께 유지: SIGHUP 무시는 exec 후에도 자식에 상속되므로
# 이 아래로 이어지는 ffmpeg·whisper·claude 까지 전부 보호된다.
nohup /usr/bin/python3 -c '
import os, sys
try:
    os.setsid()          # 새 세션 = 터미널 창과의 연결을 끊는다
except OSError:
    pass                 # 이미 세션 리더면 그대로 진행
os.execv(sys.argv[1], [sys.argv[1]])
' "$TOGGLE" >/dev/null 2>&1 &
disown

# 이 창을 스스로 닫는다 — 내 tty를 가진 터미널 창을 찾아서 close.
# 1초 대기: 셸이 먼저 종료되게 해서 '종료하시겠습니까' 확인창이 뜨는 걸 막는다.
(
  sleep 1
  /usr/bin/osascript <<OSA
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if tty of t is "$MYTTY" then close w
      end try
    end repeat
  end repeat
end tell
OSA
) >/dev/null 2>&1 &
disown

echo "회의 녹음 토글 실행됨 — 이 창은 곧 자동으로 닫힙니다."
exit 0
