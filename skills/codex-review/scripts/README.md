# codex-review — Claude Code ↔ Codex 교차 검토 브리지

Claude Code가 구현한 작업을 Codex CLI에 **읽기 전용**으로 검토시키고, 판정을 종료 코드로 돌려받는다.
Codex는 보고서만 보는 게 아니라 `--cd` 로 지정한 프로젝트에서 실제 파일을 열어 확인한다.

## 구성
| 경로 | 역할 |
|---|---|
| `codex-review.sh` | 브리지 스크립트 |
| `response-schema.json` | Codex 응답 JSON Schema (`--output-schema` 로 강제) |
| `~/.claude/commands/codex-review.md` | Claude Code용 슬래시 커맨드 `/codex-review` |
| `~/.claude/codex-reviews/<프로젝트>/<작업>/round-N/` | 회차별 요청·응답 기록 |

## 명령
```bash
CR=~/.claude/scripts/codex-review/codex-review.sh

$CR preflight                                      # codex 설치·구독 로그인·jq 확인
$CR init     --task <slug> --dir <프로젝트>          # 작업 시작 전 baseline 기록
$CR template --task <slug> > request.md            # 요청서 골격
$CR review   --task <slug> --dir <프로젝트> --request request.md
$CR status   --task <slug> --dir <프로젝트>          # 회차·판정·재시도·잠금 상태
$CR resume   --task <slug> --dir <프로젝트>          # 중단 잠금 해제 (잠긴 상태에서만, 사전 점검 통과 시)
```
옵션: `--max-rounds N`(기본 3), `--timeout SEC`(기본 900).

## 종료 코드
| 코드 | 뜻 |
|---|---|
| 0 | 통과 |
| 10 | 수정 필요 |
| 11 | 사용자 판단 필요 |
| 20 | 라운드 한도 초과 (미해결) |
| 21 | codex 실행 오류·타임아웃 |
| 22 | 로그인·사용량·권한 문제 |
| 23 | 빈 응답·해석 불가 |
| 24 | 같은 쟁점이 반복돼 수렴하지 않음 |
| 25 | 중단 잠금 — 사람이 원인을 해결하고 `resume` 해야 함 |

**0 이외는 전부 "통과 아님"이다.**

## 실패·재시도 처리
21·22·23은 검토를 **받지 못한** 것이므로 검토 라운드(기본 3회)를 소모하지 않는다. 대신 별도 예산으로 막는다.

| 상황 | 동작 |
|---|---|
| 22 로그인·사용량·권한 | 재시도 없이 **즉시 중단 잠금**. API 결제로 우회하지 않는다 |
| 21·23 일시적 오류 (실행 오류·타임아웃·빈 응답·해석 불가) | **작업당 1회만** 재시도 허용. 첫 번째는 21/23을 그대로 반환하며 "남은 재시도 1회"를 알리고, 두 번째부터는 25로 중단 잠금 |
| 잠금 상태에서 `review` | Codex 를 **호출하지 않고** 즉시 25 |

- 예산은 작업(task)당 1회이며, 성공한 라운드가 있어도 리셋되지 않는다.
- 잠금은 `resume` 으로만 풀린다. `resume` 은 **잠긴 상태에서만** 동작하고(잠기지 않았으면 exit 2),
  `preflight`(설치·구독 로그인·jq)를 통과해야 예산을 복구한다.
  → 자동으로 무한 재시도가 도는 경로가 없다. 사람의 개입과 사전 점검을 반드시 거친다.
- 예산을 완전히 새로 받으려면 `init` 으로 작업을 다시 시작해야 한다.
- 실패 이력은 `state.json` 의 `errors`, 잠금·예산은 `retry` 에 남고 `status` 로 볼 수 있다.

## 안전 설계
- 호출은 `codex exec --sandbox read-only --skip-git-repo-check -c approval_policy="never"`.
  권한 우회 옵션(`--dangerously-bypass-*`, `--approve-for-me`, `workspace-write`)은 쓰지 않는다.
- `-c preferred_auth_method="chatgpt"` + 실행 시 `OPENAI_API_KEY`/`OPENAI_BASE_URL` 제거 →
  구독 로그인만 쓰고 API 과금으로 넘어가지 않는다.
- 요청은 stdin(파일 내용)으로만 전달한다. Codex 응답을 셸로 실행하지 않는다.
- diff에서 비밀 파일 제외: `.env*`, `*.pem`, `*.key`, `*.p12`, `*id_rsa*`, `auth.json`,
  `.netrc`, `.npmrc`, `credentials*`, `secrets.*`, `.aws/**`, `service-account*.json` 등.
  프롬프트 전문에 `sk-…`, `ghp_…`, `xox…`, `AKIA…`, JWT, PEM 블록 마스킹을 한 번 더 건다.
  프롬프트 안에서도 Codex에게 해당 파일을 열지 말라고 지시한다.
- git push·배포는 이 흐름에 포함되지 않는다.

## 변경 구분 / 드리프트 감지
`init` 이 HEAD·브랜치·미커밋 목록을 baseline 으로 저장한다. `review` 마다 현재 상태와 비교해
프롬프트에 세 가지를 나눠 적는다.
- 이번 작업에서 생긴 미커밋 변경 (검토 대상)
- 작업 시작 전부터 있던 미커밋 변경 (참고만)
- HEAD·브랜치가 바뀌었거나 baseline 의 미커밋 변경이 사라진 경우 → **검토 기준이 달라졌다는 경고**

git 저장소가 아니면 구분·감지가 불가능하다는 사실을 프롬프트에 명시한다.

## 판정 신뢰성 장치
- 응답은 JSON Schema로 강제. 스키마를 벗어나거나 비면 exit 23 (통과로 치지 않음).
- `verdict: pass` 인데 blocker/major 지적이 남아 있으면 모순으로 보고 `changes_requested` 로 낮춘다.
- `reviewed_files` 가 비면 "보고서만 보고 판단했을 수 있다"고 경고한다.
- 이전 회차와 같은 (파일 + 지적 요지) 조합이 다시 나오면 exit 24.

## 반박 흐름
지적이 틀렸다고 판단하면 고치지 말고 해당 회차 폴더에 `rebuttal.md` 를 쓴다.
다음 회차 프롬프트에 이전 지적 + 그 반박이 함께 실리고, Codex는 반박의 타당성부터 재검토한다.

## 모의 테스트 (사용량 소모 없음)
```bash
CODEX_REVIEW_MOCK_RESPONSE=<응답.json>   # codex 호출 대신 이 파일을 응답으로 사용
CODEX_REVIEW_MOCK_EXIT=<n>              # codex 종료 코드 위조
CODEX_REVIEW_MOCK_STDERR="<text>"       # stderr 위조 (사용량 제한 등 분류 테스트)
CODEX_REVIEW_HOME=<dir>                 # 기록 저장 위치 변경
```
