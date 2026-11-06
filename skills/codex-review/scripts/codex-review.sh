#!/usr/bin/env bash
# codex-review.sh — Claude Code가 구현한 작업을 Codex CLI에 읽기 전용으로 검토 요청하는 브리지.
#
# 사용:
#   codex-review.sh preflight
#   codex-review.sh init     --task <slug> [--dir <project>]
#   codex-review.sh template --task <slug> [--dir <project>] > request.md
#   codex-review.sh review   --task <slug> --request <file> [--dir <project>] [--max-rounds N] [--timeout SEC]
#   codex-review.sh status   --task <slug> [--dir <project>]
#   codex-review.sh resume   --task <slug> [--dir <project>]   # 중단 잠금 해제(잠긴 상태 + 사전 점검 통과 시에만)
#
# 종료 코드:
#   0  통과(pass)
#   10 수정 필요(changes_requested)
#   11 사용자 판단 필요(user_decision_needed)
#   20 라운드 한도 초과 (미해결 상태)
#   21 codex 실행 오류 / 타임아웃
#   22 로그인·사용량·권한 문제
#   23 응답이 비었거나 해석 불가
#   24 같은 쟁점이 이전 라운드와 반복됨 (판정 기준 재검토 필요)
#   25 중단 잠금 — 재시도 예산 소진 또는 로그인·사용량 문제 이후 잠김. 사람이 원인을 해결하고 resume 해야 함
#   2  스크립트 사용법 오류
# 0 이외는 모두 "통과 아님"으로 취급할 것.

set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE="$SCRIPT_DIR/response-schema.json"
STORE_ROOT="${CODEX_REVIEW_HOME:-$HOME/.claude/codex-reviews}"
DEFAULT_MAX_ROUNDS=3
DEFAULT_TIMEOUT=900
DIFF_LINE_LIMIT=1500

# 비밀 파일: diff에서 제외하고 Codex에게도 읽지 말라고 지시한다.
SECRET_GLOBS=(
  '**/.env' '**/.env.*' '**/*.pem' '**/*.key' '**/*.p12' '**/*.pfx'
  '**/*id_rsa*' '**/auth.json' '**/.netrc' '**/.npmrc' '**/.pypirc'
  '**/credentials' '**/credentials.*' '**/secrets.*' '**/.aws/**'
  '**/service-account*.json' '**/*.keystore' '**/.git-credentials'
)

err()  { printf '%s\n' "$*" >&2; }
die()  { err "오류: $1"; exit "${2:-2}"; }
note() { printf '%s\n' "$*"; }

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#[^a-z0-9._/-]+#-#g; s#/#_#g; s#^-+##; s#-+$##; s#-{2,}#-#g'
}

project_slug() {
  local dir="$1" base short
  base="$(slugify "$(basename "$dir")")"
  [ -z "$base" ] && base="root"
  short="$(printf '%s' "$dir" | shasum -a 1 | cut -c1-8)"
  printf '%s-%s' "$base" "$short"
}

# 인자로 들어온 텍스트에서 흔한 비밀값 형태를 가린다.
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

# ---------- 공통 인자 파싱 ----------
TASK=""; PROJECT_DIR=""; REQUEST_FILE=""
MAX_ROUNDS="$DEFAULT_MAX_ROUNDS"; TIMEOUT="$DEFAULT_TIMEOUT"

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --task)       TASK="${2:-}"; shift 2 ;;
      --dir)        PROJECT_DIR="${2:-}"; shift 2 ;;
      --request)    REQUEST_FILE="${2:-}"; shift 2 ;;
      --max-rounds) MAX_ROUNDS="${2:-}"; shift 2 ;;
      --timeout)    TIMEOUT="${2:-}"; shift 2 ;;
      *) die "알 수 없는 인자: $1" ;;
    esac
  done
  [ -z "$PROJECT_DIR" ] && PROJECT_DIR="$PWD"
  PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || die "프로젝트 경로를 찾을 수 없음: $PROJECT_DIR"
  [ -z "$TASK" ] && die "--task <slug> 가 필요함"
  TASK="$(slugify "$TASK")"
  [ -z "$TASK" ] && die "--task 값이 slug 로 변환되지 않음"
  TASK_DIR="$STORE_ROOT/$(project_slug "$PROJECT_DIR")/$TASK"
  STATE_FILE="$TASK_DIR/state.json"
}

# ---------- git 베이스라인 ----------
git_in_repo() { git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; }

git_snapshot_json() {
  if ! git_in_repo; then
    printf '{"is_git":false}'
    return
  fi
  local head branch dirty
  head="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "")"
  branch="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  dirty="$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | jq -R . | jq -s .)"
  jq -n --arg head "$head" --arg branch "$branch" --argjson dirty "$dirty" \
    '{is_git:true, head:$head, branch:$branch, dirty:$dirty}'
}

# baseline 과 현재를 비교해 사람이 읽을 텍스트를 만든다.
changed_context() {
  local base_head base_branch
  if ! git_in_repo; then
    printf '이 프로젝트는 git 저장소가 아니다. 변경 파일 구분과 드리프트 감지를 할 수 없으니, 아래 "변경 파일" 목록은 Claude Code가 직접 적은 내용이며 검증되지 않았다.\n'
    return
  fi
  base_head="$(jq -r '.baseline.head // ""' "$STATE_FILE" 2>/dev/null)"
  base_branch="$(jq -r '.baseline.branch // ""' "$STATE_FILE" 2>/dev/null)"
  local cur_head cur_branch
  cur_head="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "")"
  cur_branch="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

  printf '브랜치: %s / HEAD: %s\n' "$cur_branch" "${cur_head:0:12}"
  if [ -n "$base_head" ] && [ "$base_head" != "$cur_head" ]; then
    printf '\n[주의] 작업 시작 시점(baseline)의 HEAD(%s)와 현재 HEAD(%s)가 다르다. 커밋·리베이스·다른 세션의 변경이 끼어들었을 수 있어 검토 기준이 달라졌다.\n' "${base_head:0:12}" "${cur_head:0:12}"
  fi
  if [ -n "$base_branch" ] && [ "$base_branch" != "$cur_branch" ]; then
    printf '\n[주의] baseline 브랜치(%s) != 현재 브랜치(%s).\n' "$base_branch" "$cur_branch"
  fi

  local base_list cur_list
  base_list="$TASK_DIR/.baseline-dirty.txt"
  cur_list="$TASK_DIR/.current-dirty.txt"
  jq -r '.baseline.dirty[]? ' "$STATE_FILE" 2>/dev/null | sed -E 's/^...//' | sort -u > "$base_list"
  git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | sed -E 's/^...//' | sort -u > "$cur_list"

  printf '\n## 이번 작업에서 생긴 미커밋 변경 (검토 대상)\n'
  comm -13 "$base_list" "$cur_list" | sed 's/^/  - /' | grep . || printf '  (없음)\n'

  printf '\n## 작업 시작 전부터 있던 미커밋 변경 (검토 대상 아님, 참고만)\n'
  comm -12 "$base_list" "$cur_list" | sed 's/^/  - /' | grep . || printf '  (없음)\n'

  local vanished
  vanished="$(comm -23 "$base_list" "$cur_list")"
  if [ -n "$vanished" ]; then
    printf '\n[주의] baseline 에 있던 미커밋 변경이 사라졌다(커밋/되돌림/stash 가능성). 다른 세션의 개입일 수 있다:\n'
    printf '%s\n' "$vanished" | sed 's/^/  - /'
  fi
}

scoped_diff() {
  git_in_repo || { printf '(git 저장소가 아니라 diff 없음)\n'; return; }
  local excl=() g
  for g in "${SECRET_GLOBS[@]}"; do excl+=( ":(exclude,glob)$g" ); done
  {
    printf '### git diff HEAD --stat\n'
    git -C "$PROJECT_DIR" diff HEAD --stat -- . "${excl[@]}" 2>/dev/null
    printf '\n### untracked (내용 미포함)\n'
    git -C "$PROJECT_DIR" ls-files --others --exclude-standard -- . "${excl[@]}" 2>/dev/null | sed 's/^/  ? /'
    printf '\n### git diff HEAD (비밀 파일 제외)\n'
    git -C "$PROJECT_DIR" diff HEAD -- . "${excl[@]}" 2>/dev/null | head -n "$DIFF_LINE_LIMIT"
    if [ "$(git -C "$PROJECT_DIR" diff HEAD -- . "${excl[@]}" 2>/dev/null | wc -l | tr -d ' ')" -gt "$DIFF_LINE_LIMIT" ]; then
      printf '\n…(diff가 %s줄을 넘어 잘림. 나머지는 파일을 직접 열어 확인할 것)\n' "$DIFF_LINE_LIMIT"
    fi
  } | mask_secrets
}

# ---------- 서브커맨드 ----------
cmd_preflight() {
  local rc=0
  if ! command -v codex >/dev/null 2>&1; then
    err "codex CLI 없음"; return 22
  fi
  note "codex: $(command -v codex) / $(codex --version 2>&1 | head -1)"
  local login
  login="$(codex login status 2>&1 | head -3)"
  note "로그인: $login"
  case "$login" in
    *"Logged in using ChatGPT"*) : ;;
    *"API key"*|*"api key"*)
      err "[경고] API 키 인증 상태로 보인다. 이 브리지는 구독(ChatGPT) 로그인만 사용한다. 'codex login' 으로 구독 로그인할 것."
      rc=22 ;;
    *"Not logged in"*|*"not logged in"*)
      err "로그인되어 있지 않다. 'codex login' 실행 필요."; rc=22 ;;
    *) err "[경고] 로그인 상태를 해석하지 못했다."; rc=22 ;;
  esac
  command -v jq >/dev/null 2>&1 || { err "jq 없음"; rc=22; }
  [ -f "$SCHEMA_FILE" ] || { err "스키마 파일 없음: $SCHEMA_FILE"; rc=22; }
  return $rc
}

cmd_init() {
  mkdir -p "$TASK_DIR"
  local snap; snap="$(git_snapshot_json)"
  if [ -f "$STATE_FILE" ]; then
    local rounds; rounds="$(jq -r '.rounds | length' "$STATE_FILE" 2>/dev/null || echo 0)"
    err "[알림] 같은 task 의 기존 기록이 있다(라운드 $rounds). baseline 을 새로 잡고 라운드를 0부터 다시 센다. 이전 기록은 $TASK_DIR/archive-* 로 옮긴다."
    local arch="$TASK_DIR/archive-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$arch"
    find "$TASK_DIR" -maxdepth 1 -name 'round-*' -exec mv {} "$arch"/ \; 2>/dev/null
    mv "$STATE_FILE" "$arch/state.json" 2>/dev/null
  fi
  jq -n --arg project "$PROJECT_DIR" --arg task "$TASK" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson baseline "$snap" \
    '{project:$project, task:$task, created_at:$created, baseline:$baseline, rounds:[], errors:[],
      retry:{transient_used:0, halted:false, halt_reason:"", halted_at:""}}' > "$STATE_FILE"
  note "baseline 기록: $STATE_FILE"
  if [ "$(jq -r '.baseline.is_git' "$STATE_FILE")" = "true" ]; then
    note "  HEAD $(jq -r '.baseline.head[0:12]' "$STATE_FILE") / 기존 미커밋 $(jq -r '.baseline.dirty | length' "$STATE_FILE")건"
  else
    note "  git 저장소 아님 — 변경 구분·드리프트 감지 비활성"
  fi
}

cmd_template() {
  cat <<'TPL'
<!-- Codex 검토 요청서. 아래 항목을 Claude Code가 채운다. 비밀값·인증정보는 절대 넣지 않는다. -->

## 1. 사용자 목표
(사용자가 실제로 요청한 것. 원문에 가깝게.)

## 2. 이번 작업 범위
(했다 / 하지 않았다 의 경계. 범위 밖은 명시.)

## 3. 적용한 규칙·제약
(프로젝트 지침, CLAUDE.md/AGENTS.md, 사용자가 건 제약, 기존 코드 관행 등.)

## 4. 변경 내용과 의도
(파일별로: 무엇을 왜 바꿨는가. 설계 결정과 대안이 있으면 이유까지.)

## 5. 검증 결과
(실제로 돌린 명령과 결과. 안 돌린 것은 "미검증"이라고 적는다. 추정으로 통과라고 쓰지 않는다.)

## 6. 남은 질문 / 확신 없는 부분
(검토자에게 특히 봐달라고 할 지점.)
TPL
}

build_prompt() {
  local round="$1" out="$2" prev_summary="$3"
  {
    cat <<HDR
너는 이 프로젝트의 코드 검토자다. 역할은 읽기 전용 검토이며, 파일을 수정하거나 명령으로 시스템을 바꾸지 않는다.

# 검토 대상
- 프로젝트 루트: $PROJECT_DIR
- 작업 식별자: $TASK
- 검토 회차: $round / 최대 $MAX_ROUNDS

# 지켜야 할 것
1. 아래 보고서만 믿지 말고, 프로젝트 루트에서 실제 변경 파일을 직접 열어 확인한 뒤 판단해라. 읽은 파일은 reviewed_files 에 적어라.
2. 근거 없는 지적은 하지 마라. 각 지적에는 파일·라인·실제 인용 근거를 붙이고, 추측이면 confidence 를 낮추고 추측이라고 명시해라.
3. 사용자 목표와 작업 범위를 기준으로 판단해라. 범위 밖 개선 제안은 severity 를 nit/minor 로 하고 required_action 에 "선택 사항"이라고 적어라.
4. 스타일 취향만으로 changes_requested 를 내지 마라. 동작·정확성·보안·요구사항 미충족·명백한 유지보수 위험일 때만 blocker/major 다.
5. 다음 파일은 열지 마라: .env 및 .env.*, *.pem, *.key, auth.json, credentials*, secrets*, ~/.aws, ~/.codex/auth.json 등 인증·비밀 파일. 필요하면 "확인 불가"로 남겨라.
6. 판정은 셋 중 하나다.
   - pass: 이 범위에서 고칠 것이 없다(nit 만 남은 경우 포함).
   - changes_requested: 코드나 문서를 고쳐야 한다. 무엇을 고쳐야 하는지 구체적으로.
   - user_decision_needed: 요구사항 자체가 모호하거나 트레이드오프라 구현자가 정할 수 없다. open_questions 를 채워라.
7. 출력은 지정된 JSON 스키마를 따른다. 설명 문장을 JSON 밖에 쓰지 마라. 한국어로 써라.

HDR

    if [ -n "$prev_summary" ]; then
      printf '# 이전 회차에서 네가 지적한 내용과 구현자의 대응\n%s\n\n' "$prev_summary"
      printf '이번 회차에서는 (a) 그 지적들이 실제로 해소되었는지 파일을 열어 확인하고, (b) 구현자가 근거를 들어 반박한 항목은 그 근거가 타당한지 재검토해라. 같은 지적을 근거 없이 되풀이하지 마라. 네 판단이 틀렸다면 그렇다고 인정해라.\n\n'
    fi

    printf '# Git 상태 (스크립트가 자동 수집)\n'
    changed_context
    printf '\n'
    printf '# 변경 diff (스크립트가 자동 수집, 비밀 파일 제외)\n```diff\n'
    scoped_diff
    printf '\n```\n\n'
    printf '# 구현자(Claude Code)의 보고서\n'
    mask_secrets < "$REQUEST_FILE"
  } > "$out"
}

run_codex() {
  local prompt_file="$1" out_msg="$2" raw="$3" errlog="$4"

  if [ -n "${CODEX_REVIEW_MOCK_RESPONSE:-}" ]; then
    : > "$raw"
    printf '%s' "${CODEX_REVIEW_MOCK_STDERR:-}" > "$errlog"
    if [ -f "$CODEX_REVIEW_MOCK_RESPONSE" ]; then
      cat "$CODEX_REVIEW_MOCK_RESPONSE" > "$out_msg"
    else
      : > "$out_msg"
    fi
    return "${CODEX_REVIEW_MOCK_EXIT:-0}"
  fi

  # OPENAI_API_KEY 등이 있어도 API 과금으로 넘어가지 않도록 환경에서 제거한 뒤 실행한다.
  env -u OPENAI_API_KEY -u OPENAI_BASE_URL -u OPENAI_ORGANIZATION \
    codex exec \
      --cd "$PROJECT_DIR" \
      --sandbox read-only \
      --skip-git-repo-check \
      -c 'approval_policy="never"' \
      -c 'preferred_auth_method="chatgpt"' \
      --output-schema "$SCHEMA_FILE" \
      --output-last-message "$out_msg" \
      --color never \
      - < "$prompt_file" > "$raw" 2> "$errlog" &
  local pid=$! rc=0
  ( sleep "$TIMEOUT"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watcher=$!
  wait "$pid"; rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return $rc
}

classify_failure() {
  local errlog="$1" raw="$2"
  local blob
  blob="$(cat "$errlog" "$raw" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  case "$blob" in
    *"not logged in"*|*"unauthorized"*|*401*|*"authentication"*|*"login"*) return 22 ;;
    *"rate limit"*|*"usage limit"*|*"quota"*|*429*|*"too many requests"*)   return 22 ;;
    *"insufficient"*|*"billing"*|*"payment"*)                              return 22 ;;
    *) return 21 ;;
  esac
}

# 실패를 기록하고 재시도 예산·중단 잠금을 갱신한 뒤, 실제로 돌려줄 종료 코드를 반환한다.
#  - 22(로그인·사용량·권한): 재시도 없이 즉시 잠근다.
#  - 21/23(일시적 오류): 작업당 1회만 재시도 허용. 두 번째부터는 25로 잠근다.
# 잠금은 resume 으로만 풀리고, resume 은 사전 점검을 통과해야 동작한다 → 무한 재시도가 생기지 않는다.
register_failure() {
  local kind="$1" why="$2" round="$3"
  local used halted_now="false" reason="" final="$kind" now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  used="$(jq -r '.retry.transient_used // 0' "$STATE_FILE" 2>/dev/null || echo 0)"
  case "$kind" in
    22)
      halted_now="true"; reason="로그인·사용량·권한 문제 ($why)"
      err "→ 로그인·사용량·권한 문제다. 재시도하지 않고 이 작업의 검토를 즉시 중단한다."
      err "   API 결제로 우회하지 말 것. 사용자가 원인을 해결한 뒤 아래로 재개한다:"
      err "   codex-review.sh resume --task $TASK --dir $PROJECT_DIR"
      ;;
    21|23)
      used=$((used + 1))
      if [ "$used" -gt 1 ]; then
        halted_now="true"; reason="일시적 오류 재시도 예산(1회) 소진 ($why)"; final=25
        err "→ 이 작업에서 일시적 오류가 두 번째다. 재시도 예산(작업당 1회)을 소진해 중단한다."
        err "   원인을 확인해 사용자에게 보고하고, 해결 후 아래로 재개한다:"
        err "   codex-review.sh resume --task $TASK --dir $PROJECT_DIR"
      else
        err "→ 일시적 오류다. 이 작업에 남은 재시도는 1회. 같은 명령을 한 번만 다시 실행할 수 있다."
      fi
      ;;
  esac
  jq --argjson r "$round" --argjson k "$kind" --arg d "$now" --arg why "$why" \
     --argjson used "$used" --argjson h "$halted_now" --arg reason "$reason" \
    '.errors = ((.errors // []) + [{attempted_round:$r, at:$d, exit:$k, kind:$why}])
     | .retry = ((.retry // {}) + {
         transient_used: $used,
         halted: $h,
         halt_reason: (if $h then $reason else (.retry.halt_reason // "") end),
         halted_at:   (if $h then $d      else (.retry.halted_at // "") end)})' \
    "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  return "$final"
}

finding_keys() { jq -r '[.findings[]? | ((.file // "-") + "|" + ((.issue // "") | ascii_downcase | gsub("[^a-z0-9가-힣]";"") | .[0:48]))] | .[]' "$1" 2>/dev/null | sort -u; }

cmd_review() {
  [ -z "$REQUEST_FILE" ] && die "--request <file> 가 필요함"
  [ -f "$REQUEST_FILE" ] || die "요청서 파일 없음: $REQUEST_FILE"
  [ -s "$REQUEST_FILE" ] || die "요청서가 비어 있음: $REQUEST_FILE"
  if [ ! -f "$STATE_FILE" ]; then
    err "[경고] baseline 이 없다. 지금 상태를 baseline 으로 잡는다 — 기존 미커밋 변경과 이번 작업 변경을 구분할 수 없다. 다음부터는 작업 시작 전에 'init' 을 먼저 실행할 것."
    cmd_init
  fi

  # 중단 잠금 상태면 Codex 를 아예 호출하지 않는다.
  if [ "$(jq -r '.retry.halted // false' "$STATE_FILE" 2>/dev/null)" = "true" ]; then
    err "이 작업의 검토는 중단 잠금 상태다: $(jq -r '.retry.halt_reason // "사유 미기록"' "$STATE_FILE")"
    err "잠긴 시각: $(jq -r '.retry.halted_at // "-"' "$STATE_FILE")"
    err "사용자가 원인을 해결한 뒤 'resume --task $TASK --dir $PROJECT_DIR' 로 풀어야 한다. 그 전에는 Codex 를 호출하지 않는다."
    return 25
  fi

  local done_rounds round
  done_rounds="$(jq -r '.rounds | length' "$STATE_FILE")"
  round=$((done_rounds + 1))
  if [ "$round" -gt "$MAX_ROUNDS" ]; then
    err "라운드 한도 초과: 이미 $done_rounds 회 검토했다(한도 $MAX_ROUNDS)."
    err "미해결로 남은 지적:"
    jq -r '.rounds[-1].findings[]? | "  [\(.severity)] \(.file):\(.lines) — \(.issue)"' "$STATE_FILE" >&2 2>/dev/null
    err "더 돌리지 말고 사용자에게 미해결 내용을 보고할 것."
    return 20
  fi

  local rdir="$TASK_DIR/round-$round"
  mkdir -p "$rdir"
  cp "$REQUEST_FILE" "$rdir/request.md"

  local prev_summary=""
  if [ "$done_rounds" -gt 0 ]; then
    prev_summary="$(jq -r '
      .rounds[-1] as $r |
      "- 이전 판정: \($r.verdict)\n- 총평: \($r.summary)\n" +
      ([$r.findings[]? | "- [\(.severity)/\(.confidence)] \(.file):\(.lines) — \(.issue) → 요구 조치: \(.required_action)"] | join("\n"))
    ' "$STATE_FILE" 2>/dev/null)"
    if [ -f "$TASK_DIR/round-$done_rounds/rebuttal.md" ]; then
      prev_summary="$prev_summary

## 구현자의 대응(수정 또는 반박)
$(cat "$TASK_DIR/round-$done_rounds/rebuttal.md")"
    fi
  fi

  build_prompt "$round" "$rdir/prompt.md" "$prev_summary"

  local out_msg="$rdir/response.json" raw="$rdir/raw.jsonl" errlog="$rdir/stderr.log"
  : > "$out_msg"
  local start_ts rc
  start_ts=$(date +%s)
  note "Codex 검토 요청 중 (라운드 $round/$MAX_ROUNDS, 타임아웃 ${TIMEOUT}s)…"
  run_codex "$rdir/prompt.md" "$out_msg" "$raw" "$errlog"
  rc=$?
  local elapsed=$(( $(date +%s) - start_ts ))

  if [ "$rc" -ne 0 ]; then
    local kind
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
      err "codex 실행이 ${TIMEOUT}s 타임아웃으로 중단됨. 통과로 처리하지 말 것."
      kind=21
    else
      classify_failure "$errlog" "$raw"; kind=$?
      err "codex 실행 실패 (exit $rc). stderr 앞부분:"
      head -c 800 "$errlog" >&2; err ""
      [ "$kind" = "22" ] && err "→ 로그인·사용량·권한 문제로 보인다. 통과로 처리하지 말 것."
    fi
    # 실행 실패는 검토를 받지 못한 것이므로 라운드(검토 횟수)를 소모하지 않는다.
    # 대신 재시도 예산과 중단 잠금으로 제한한다.
    err "이 시도는 검토 횟수(라운드)로 세지 않는다."
    register_failure "$kind" "실행 실패" "$round"
    return $?
  fi

  record_bad_response() {
    err "이 시도는 검토 횟수(라운드)로 세지 않는다."
    register_failure 23 "$1" "$round"
    BAD_RESPONSE_EXIT=$?
  }
  if [ ! -s "$out_msg" ]; then
    err "Codex 응답이 비어 있다. 통과로 처리하지 말 것. (raw: $raw)"
    record_bad_response "빈 응답"
    return $BAD_RESPONSE_EXIT
  fi
  # 코드펜스가 붙어 오는 경우 정리
  if ! jq -e . "$out_msg" >/dev/null 2>&1; then
    sed -E '1{/^```/d}; ${/^```$/d}' "$out_msg" > "$out_msg.clean" && mv "$out_msg.clean" "$out_msg"
  fi
  if ! jq -e '.verdict and (.findings|type=="array")' "$out_msg" >/dev/null 2>&1; then
    err "Codex 응답을 JSON으로 해석할 수 없다. 통과로 처리하지 말 것. 원문 앞부분:"
    head -c 800 "$out_msg" >&2; err ""
    record_bad_response "JSON 해석 불가"
    return $BAD_RESPONSE_EXIT
  fi
  local verdict; verdict="$(jq -r '.verdict' "$out_msg")"
  case "$verdict" in
    pass|changes_requested|user_decision_needed) : ;;
    *) err "알 수 없는 판정값: $verdict — 통과로 처리하지 말 것."; record_bad_response "알 수 없는 판정값"; return $BAD_RESPONSE_EXIT ;;
  esac

  # pass 인데 blocker/major 가 남아 있으면 신뢰하지 않는다.
  local hard; hard="$(jq -r '[.findings[]? | select(.severity=="blocker" or .severity=="major")] | length' "$out_msg")"
  if [ "$verdict" = "pass" ] && [ "$hard" -gt 0 ]; then
    err "[경고] 판정은 pass 인데 blocker/major 지적이 ${hard}건 있다. 모순이므로 changes_requested 로 취급한다."
    verdict="changes_requested"
  fi

  # 같은 쟁점 반복 감지
  local repeat_note="" repeated=""
  if [ "$done_rounds" -gt 0 ] && [ -f "$TASK_DIR/round-$done_rounds/response.json" ]; then
    repeated="$(comm -12 <(finding_keys "$TASK_DIR/round-$done_rounds/response.json") <(finding_keys "$out_msg"))"
  fi

  jq --argjson r "$round" --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg v "$verdict" \
     --slurpfile resp "$out_msg" \
    '.rounds += [{round:$r, status:"ok", at:$d, verdict:$v,
                  summary:$resp[0].summary, findings:$resp[0].findings,
                  open_questions:$resp[0].open_questions,
                  reviewed_files:($resp[0].reviewed_files // [])}]' \
    "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

  # ---- 사람이 읽을 요약 ----
  note ""
  note "=== Codex 검토 결과 (라운드 $round/$MAX_ROUNDS, ${elapsed}s) ==="
  note "판정: $verdict"
  note "총평: $(jq -r '.summary' "$out_msg")"
  local nfiles; nfiles="$(jq -r '.reviewed_files | length' "$out_msg" 2>/dev/null || echo 0)"
  if [ "${nfiles:-0}" -eq 0 ]; then
    note "[주의] Codex가 읽은 파일을 하나도 보고하지 않았다. 보고서만 보고 판단했을 수 있으니 지적의 근거를 더 엄격히 따질 것."
  else
    note "읽은 파일($nfiles): $(jq -r '.reviewed_files | join(", ")' "$out_msg")"
  fi
  note ""
  if [ "$(jq -r '.findings | length' "$out_msg")" -eq 0 ]; then
    note "지적 없음."
  else
    jq -r '.findings[] | "[\(.severity)/확신 \(.confidence)] \(.file):\(.lines)\n  문제: \(.issue)\n  근거: \(.evidence)\n  조치: \(.required_action)\n"' "$out_msg"
  fi
  if [ "$(jq -r '.open_questions | length' "$out_msg")" -gt 0 ]; then
    note "사용자 판단이 필요한 질문:"
    jq -r '.open_questions[] | "  - " + .' "$out_msg"
  fi
  note ""
  note "기록: $rdir"

  if [ -n "$repeated" ]; then
    err ""
    err "[중단 권고] 이전 라운드와 같은 쟁점이 반복된다:"
    printf '%s\n' "$repeated" | sed 's/^/  - /' >&2
    err "논쟁이 수렴하지 않으므로 더 돌리지 말고 사용자에게 판정 기준을 물을 것."
    return 24
  fi

  note "다음 단계:"
  case "$verdict" in
    pass) note "  통과. 검토 종료."; return 0 ;;
    changes_requested)
      note "  각 지적을 근거로 검증한 뒤 (a) 수정하거나 (b) 반박 근거를 $rdir/rebuttal.md 에 적고 재검토 요청."
      return 10 ;;
    user_decision_needed)
      note "  사용자에게 위 질문을 그대로 전달하고 답을 받은 뒤 진행."
      return 11 ;;
  esac
}

# 중단 잠금 해제. 사전 점검(codex 설치·구독 로그인·jq)을 통과해야만 풀린다.
cmd_resume() {
  [ -f "$STATE_FILE" ] || die "기록이 없다: $TASK_DIR"
  local halted; halted="$(jq -r '.retry.halted // false' "$STATE_FILE")"
  # 잠기지 않은 상태에서 예산만 되살리는 것을 허용하면 resume→review 반복으로
  # "작업당 1회" 제한을 무한히 우회할 수 있다. 그래서 잠금 상태에서만 동작한다.
  if [ "$halted" != "true" ]; then
    err "이 작업은 중단 잠금 상태가 아니다. resume 은 잠금 해제 전용이며 재시도 예산만 되살릴 수 없다."
    err "현재 일시적 오류 재시도 사용: $(jq -r '.retry.transient_used // 0' "$STATE_FILE")/1"
    err "예산을 새로 받으려면 작업 자체를 다시 시작해야 한다(init 으로 baseline 재설정)."
    return 2
  fi
  note "중단 사유: $(jq -r '.retry.halt_reason // "-"' "$STATE_FILE")"
  note "재개 전 사전 점검:"
  if ! cmd_preflight; then
    err "사전 점검 실패 — 재개하지 않는다. 로그인·도구 문제를 먼저 해결할 것."
    return 22
  fi
  jq '.retry = ((.retry // {}) + {transient_used:0, halted:false, halt_reason:"", halted_at:""})' \
    "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  note "재개했다. 일시적 오류 재시도 예산 1회가 복구됐다. (검토 라운드 수는 그대로다)"
}

cmd_status() {
  [ -f "$STATE_FILE" ] || { note "기록 없음: $TASK_DIR"; return 0; }
  jq -r '
    "프로젝트: \(.project)\n작업: \(.task)\n시작: \(.created_at)\n" +
    (if .baseline.is_git then "baseline HEAD: \(.baseline.head[0:12]) (\(.baseline.branch)), 기존 미커밋 \(.baseline.dirty|length)건"
     else "git 저장소 아님" end) + "\n라운드 \(.rounds|length)회:\n" +
    ([.rounds[] | "  #\(.round) \(.at) — \(.verdict // .status) / 지적 \(.findings|length)건"] | join("\n")) +
    (if (.retry.halted // false) then "\n[중단 잠금] \(.retry.halt_reason // "-") — resume 필요\n" else "" end) +
    "일시적 오류 재시도 사용: \(.retry.transient_used // 0)/1\n" +
    (if ((.errors // []) | length) > 0 then "\n실패한 시도(라운드 미소모) \((.errors|length))회:\n" + ([.errors[] | "  - \(.at) exit \(.exit) — \(.kind)"] | join("\n")) else "" end)
  ' "$STATE_FILE"
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    preflight) cmd_preflight ;;
    init)      parse_args "$@"; cmd_init ;;
    template)  parse_args "$@"; cmd_template ;;
    review)    parse_args "$@"; cmd_review ;;
    status)    parse_args "$@"; cmd_status ;;
    resume)    parse_args "$@"; cmd_resume ;;
    ""|-h|--help|help)
      awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "${BASH_SOURCE[0]}"
      ;;
    *) die "알 수 없는 서브커맨드: $sub" ;;
  esac
}
main "$@"
