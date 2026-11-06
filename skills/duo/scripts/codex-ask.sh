#!/usr/bin/env bash
# codex-ask.sh — Codex CLI 에게 읽기 전용으로 한 번 묻고 답(마지막 메시지)만 돌려받는다.
# Claude Code 의 duo 스킬이 쓴다.
#
# 사용:
#   codex-ask.sh [--dir <작업 폴더>] [--timeout SEC] [--file <질문 파일>] [--model <모델>] [--effort <강도>]
#   기본: 모델은 codex 설정값(환경변수 CODEX_ASK_MODEL 로 바꿀 수 있다), 추론 강도 medium.
#   강도는 low·medium·high·xhigh·max·ultra — 사용자가 올리라고 할 때만 올린다. max·ultra 는 --timeout 도 늘린다.
#   질문은 --file 이 없으면 stdin 으로 받는다.
#
# 종료 코드:
#   0  답을 받음 (stdout 에 답)
#   21 codex 실행 오류·타임아웃     → 한 번만 재시도
#   22 로그인·사용량·권한 문제       → 재시도하지 말고 사용자에게 알린다
#   23 답이 비었음                   → 한 번만 재시도
#   2  사용법 오류
#
# 기록: ~/.claude/codex-asks/<시각>-<pid>/ 에 prompt.md·answer.md·stderr.log 를 남긴다.

set -uo pipefail
IFS=$'\n\t'
# launchd 처럼 PATH 가 짧은 환경에서도 codex·node 를 찾게 한다.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

DIR="$PWD"; TIMEOUT=540; FILE=""; MODEL="${CODEX_ASK_MODEL:-}"; EFFORT="${CODEX_ASK_EFFORT:-medium}"
err() { printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     DIR="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --file)    FILE="${2:-}"; shift 2 ;;
    --model)   MODEL="${2:-}"; shift 2 ;;
    --effort)  EFFORT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) err "알 수 없는 인자: $1"; exit 2 ;;
  esac
done
[ -d "$DIR" ] || { err "폴더 없음: $DIR"; exit 2; }
case "$TIMEOUT" in ''|*[!0-9]*) err "--timeout 은 초 단위 숫자"; exit 2 ;; esac

mask_secrets() {
  sed -E \
    -e 's/(sk-[A-Za-z0-9_-]{8})[A-Za-z0-9_-]{8,}/\1<REDACTED>/g' \
    -e 's/(sk-ant-[A-Za-z0-9_-]{8})[A-Za-z0-9_-]{8,}/\1<REDACTED>/g' \
    -e 's/(gh[pousr]_[A-Za-z0-9]{6})[A-Za-z0-9]{10,}/\1<REDACTED>/g' \
    -e 's/(xox[abprs]-[A-Za-z0-9-]{6})[A-Za-z0-9-]{10,}/\1<REDACTED>/g' \
    -e 's/AKIA[0-9A-Z]{16}/AKIA<REDACTED>/g' \
    -e 's/(eyJ[A-Za-z0-9_-]{10})[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+/\1<REDACTED-JWT>/g' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/<REDACTED-PRIVATE-KEY>/g'
}

command -v codex >/dev/null 2>&1 || { err "codex CLI 없음"; exit 22; }
case "$(codex login status 2>&1 | head -3)" in
  *"Logged in using ChatGPT"*) : ;;
  *) err "codex 가 ChatGPT 구독으로 로그인돼 있지 않다 (API 키 과금 방지를 위해 중단). 사용자가 'codex login' 해야 한다."; exit 22 ;;
esac

STORE="${CODEX_ASK_HOME:-$HOME/.claude/codex-asks}/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$STORE"
PROMPT="$STORE/prompt.md"; ANSWER="$STORE/answer.md"; ERRLOG="$STORE/stderr.log"
QUESTION="$STORE/question.md"

if [ -n "$FILE" ]; then cat "$FILE"; else cat; fi | mask_secrets > "$QUESTION"
[ -n "$(tr -d '[:space:]' < "$QUESTION")" ] || { err "질문이 비었다"; exit 2; }

{
  cat <<'EOF'
[역할] 너는 다른 AI(Claude)와 함께 일하는 두 번째 의견 제공자다. 읽기 전용이다.
- 파일을 만들거나 고치지 않는다. 필요한 파일은 읽어서 근거로 쓴다.
- .env, auth.json, *.pem, credentials 같은 비밀 파일은 열지 않는다.
- 한국어로 답한다. 맞장구보다 틀린 점·빠진 점·더 나은 대안을 우선한다.
- 확인한 사실과 추정을 구분해 쓴다. 근거가 된 파일은 경로:줄번호로 적는다.

EOF
  cat "$QUESTION"
} > "$PROMPT"

env -u OPENAI_API_KEY -u OPENAI_BASE_URL -u OPENAI_ORGANIZATION \
  codex exec \
    --cd "$DIR" \
    --sandbox read-only \
    --skip-git-repo-check \
    ${MODEL:+--model=$MODEL} \
    ${EFFORT:+-c model_reasoning_effort="$EFFORT"} \
    -c 'approval_policy="never"' \
    -c 'preferred_auth_method="chatgpt"' \
    --output-last-message "$ANSWER" \
    --color never \
    - < "$PROMPT" > /dev/null 2> "$ERRLOG" &
pid=$!
( sleep "$TIMEOUT"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
watcher=$!
wait "$pid"; rc=$?
kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null

if [ $rc -ne 0 ]; then
  blob="$(tr '[:upper:]' '[:lower:]' < "$ERRLOG" 2>/dev/null)"
  case "$blob" in
    *"not logged in"*|*"unauthorized"*|*401*|*"rate limit"*|*"usage limit"*|*"quota"*|*429*|*"billing"*)
      err "로그인·사용량 문제 (기록: $ERRLOG)"; exit 22 ;;
  esac
  err "codex 실행 실패 rc=$rc (타임아웃 ${TIMEOUT}s 일 수 있음, 기록: $ERRLOG)"; exit 21
fi
[ -s "$ANSWER" ] || { err "빈 답 (기록: $STORE)"; exit 23; }

cat "$ANSWER"; echo
