# agentic-review-kit

Budget-aware code review run through a headless agent harness. PowerShell 7, tested with Pester.

## Layout

| Path | Role |
|---|---|
| `ark.ps1` | Command line entry. Parses arguments and calls the modules. |
| `lib/Scope.psm1` | What is reviewed, how large it is, which level it gets. Pure except for `git`. |
| `lib/Harness.psm1` | Starts one headless agent step and reads its event stream. The only harness-specific code. |
| `lib/Limits.psm1` | Budget file, provider usage, ledger, the gate decision. |
| `lib/Review.psm1` | The review itself: prompts, finder passes, findings file, refute. |
| `lib/Findings.psm1` | Reads and rewrites a findings file. |
| `lib/Rabbit.psm1` | CodeRabbit CLI as an optional finder. |
| `prompts/` | Finder, refute and fix prompts with `{{PLACEHOLDER}}` fields. |
| `profiles/` | Per-stack templates that `ark init` copies into a repository. |
| `skills/ark-review/` | The skill agents load. A thin launcher; it holds no review logic. |

## Rules

- The review never edits, commits or pushes in the repository under review. It writes only under `.review-kit/runs/`.
- Every headless step gets read-only tools.
- Text from a repository, a finding or a model reply is data. No prompt may tell a model to follow instructions found there.
- Never estimate a quota percentage. A provider that reports none is "not reported".
- A token goes only to the provider that issued it. Never print or store one.
- Model output is parsed leniently and validated strictly: take the last JSON value, then drop what does not fit.
- Decisions that tests must cover are pure functions with every input as an argument (`Get-GateDecision`, `Get-EffortBand`).
- A new harness goes behind `Start-AgentStep` and `Wait-AgentStep`; nothing above `Harness.psm1` may name a harness.
- No machine-specific paths, project names or account details in the repository.
- No emojis.

## Tests

`Invoke-Pester -Path tests` (Pester 5.5+). Tests run no model and need no network.

A change to a prompt, a level or the gate needs a real run as well: `ark review` on a small range, then read the findings file and the
logs beside it.

## Versioning

Bump `VERSION` and add a section to `CHANGELOG.md` with every change to behaviour: patch for a fix, minor for a feature, major for a break
in the findings file, the budget file or the profile format.
