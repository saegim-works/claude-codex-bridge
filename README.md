# claude-codex-bridge

Use **OpenAI Codex CLI as a read-only second brain** inside Claude Code.
Claude does the work; Codex reviews, disagrees, or double-checks — and Claude verifies every point against the real files before acting on it.

[한국어](#한국어)

## Skills

| Skill | What it does |
|---|---|
| `/codex-bridge:codex-review <task>` | Claude implements the task, then asks Codex for a read-only review. Each finding is fixed, rebutted with evidence, or escalated to you. Up to 3 rounds. Exit codes drive the flow, not prose. |
| `/codex-bridge:duo [의견\|아이디어\|확인] <request>` | **Opinion**: both answer blind, then critique each other, Claude synthesizes. **Idea**: Codex proposes 2–3 plans, Claude picks and builds. **Verify**: Codex re-derives Claude's numbers/conclusions from the sources. |

## Safety by design

- Codex always runs with `--sandbox read-only` and `approval_policy="never"` — it can read, never write.
- ChatGPT **subscription login only**. If Codex is on API-key auth, the skills stop instead of spending money.
- Login/usage errors (exit 22) stop immediately. Transient errors get exactly one retry, then lock.
- Claude never pipes Codex's suggested commands into the shell, and never pushes/deploys inside the review loop.

## Requirements

- [Claude Code](https://claude.com/claude-code)
- [Codex CLI](https://github.com/openai/codex) logged in with ChatGPT: `codex login`
- `bash`, `git`, `jq`

## Install

```
/plugin marketplace add 9gwf2zqhjs-arch/claude-codex-bridge
/plugin install codex-bridge@codex-bridge
```

## Configuration (optional)

| Env var | Default | Meaning |
|---|---|---|
| `CODEX_ASK_MODEL` | Codex config | Model used by `duo` |
| `CODEX_ASK_EFFORT` | `medium` | Reasoning effort for `duo` |
| `CODEX_ASK_HOME` | `~/.claude/codex-asks` | Where `duo` keeps prompts/answers |
| `CODEX_REVIEW_HOME` | `~/.claude/codex-reviews` | Where `codex-review` keeps rounds |

Skill instructions are written in Korean; Claude follows them fine and replies in your language.

---

## 한국어

Claude Code 안에서 **Codex CLI 를 읽기 전용 두 번째 머리**로 쓰는 플러그인이다.
일은 Claude 가 하고, Codex 는 검토·반대 의견·재확인을 맡는다. Claude 는 Codex 지적을 실제 파일로 확인한 뒤에만 반영한다.

- `/codex-bridge:codex-review <작업>` — 구현 → Codex 검토 → 지적마다 수정/반박/사용자 질문 → 최대 3회.
- `/codex-bridge:duo [의견|아이디어|확인] <요청>` — 각자 답하고 서로 비판(의견), Codex 안을 Claude 가 구현(아이디어), Claude 결론을 Codex 가 재계산(확인).

설치는 위 Install 절의 두 줄. Codex 는 `codex login`(ChatGPT 구독)으로 로그인해 둔다. API 키 인증이면 돌지 않는다.

## License

MIT
