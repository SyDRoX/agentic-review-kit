# agentic-review-kit

Code review run by a headless coding agent, sized to the change and held inside your plan limits.

`ark` reviews a commit range or your working tree in four steps:

1. **Size.** It buckets the diff into prod, test, generated and doc lines, checks for signals that outrank line count (a contract surface,
   a dependency pin, a schema migration, a hot path), and picks an effort level.
2. **Find.** One to three finder passes, each a separate headless agent session with read-only tools and its own lens.
3. **Refute.** Every finding goes to a second, cheaper session whose only job is to prove the failure cannot happen. A finding it refutes
   with a quoted guard is marked, and a fix round skips it.
4. **Record.** One findings file per review, in the repository under `.review-kit/runs/`.

Before every step it checks the budget: the provider's 5-hour and weekly use, a spend cap for providers that report nothing, and a cap for
the run. It waits for a 5-hour reset, and stops at the weekly threshold you set.

The agent harness is [pi](https://pi.dev). The models are whatever pi is logged in to. Nothing in the review loop needs a pull request, a
hosted service or a particular model vendor.

## Requirements

- PowerShell 7 (`pwsh`), Git.
- pi, logged in to at least one provider.
- Optional: the [CodeRabbit CLI](https://docs.coderabbit.ai/cli) as a second finder.
- Tests: Pester 5.5 or newer.

Developed and run on Windows. The scripts avoid Windows-only calls, but macOS and Linux are not tested.

## Install

```powershell
git clone https://github.com/SyDRoX/agentic-review-kit
cd agentic-review-kit
./install.ps1
```

This writes the `ark-review` skill into `~/.agents/skills` (pi, Codex) and `~/.claude/skills` (Claude Code), and creates
`~/.agentic-review-kit/budget.json`. The skill points back at the checkout, so `git pull` updates it.

## Use

```powershell
$ark = "<checkout>/ark.ps1"

pwsh -File $ark init -Repo C:/code/my-game          # write .review-kit/profile.json and profile.md
pwsh -File $ark assess -Repo C:/code/my-game        # size the change, print the plan, run no model
pwsh -File $ark review -Repo C:/code/my-game        # review it
pwsh -File $ark usage                               # plan limits and kit spend
```

In an agent session, `/skill:ark-review` does the same and reports the findings.

| Command | What it does |
|---|---|
| `review` | Review a change. `-Base <ref>`, `-Head <ref>`, `-Level`, `-Backend pi\|coderabbit\|both`, `-Model`, `-RefuteModel`, `-NoRefute`, `-Wait`, `-Full`, `-DryRun`. |
| `assess` | `review -DryRun`. |
| `audit-plan` | Divide the current code into chunks by folder. `-Paths <glob,...>`, `-MaxLines 800`, `-IncludeTests`, `-Force`. Runs no model. |
| `audit` | Audit the next chunk of the plan as the code is now. `-Count <n>`, `-All`, `-Chunk <id>`, `-Level`, `-NoWait`. Or `-Paths <glob,...>` for a one-off list. |
| `baseline` | Mark the current head as reviewed, so later reviews start from here. |
| `sweep` | Review every repository in `targets.json` that has unreviewed work, inside the budget. Made to run unattended. |
| `usage` | What is known about each provider's limits, and the kit's own spend. |
| `init` | Write a profile from a template: `unity`, `ts-worker`, `python`, `generic`. The type is detected when you do not pass one. |
| `fix <file>` | Print the prompt that applies a findings file in an agent session. |

### What is reviewed

Without `-Head`, the working tree: committed and uncommitted work together. With `-Head`, exactly that commit.

Without `-Base`, the range starts at the head of the previous review of the same branch. On the first review it starts at the merge-base with
the default branch. `-Full` ignores the previous review. A range over 4000 prod lines is refused unless you type a level: it is nearly always
a wrong base. Use `-Base`, or `baseline` to start from the current head.

### Auditing code that already exists

`review` reads a diff and reports what the change broke. A backlog that was never reviewed needs the opposite: the code as it is now, with
no history, where a defect counts however old it is. That is `audit`.

```powershell
pwsh -File $ark audit-plan -Repo C:/code/my-game     # chunks by folder, at most 800 lines each
pwsh -File $ark audit -Repo C:/code/my-game          # run the next chunk
pwsh -File $ark audit -Repo C:/code/my-game -All     # run until the plan is done or the budget stops it
```

`audit-plan` lists tracked source files, leaves out tests, vendor code, generated files and docs, and divides the rest along the folder
tree: a folder that fits is one chunk, a larger one is split into its subfolders, small neighbours are joined. Chunks that hold contract
code run first, then hot paths, then the rest. It also prints the largest folders, so third-party code that slipped in can be added to
`vendor` in the profile before any model runs.

The plan is `.review-kit/runs/audit-plan.json`. Each chunk records its findings file, counts and tokens, so a stopped run resumes at the
next open chunk, and the plan prints a measured tokens-per-line rate once one chunk is done. A chunk always reads the working tree at the
time it runs.

An audit costs more per line than a review: the finder must read every listed file in full. Run one chunk, read the rate, then decide how
many to run. `-Level` caps the depth when the automatic level is more than the budget allows.

### Levels

| Level | Finder passes | Depth |
|---|---|---|
| low | correctness | hunks and enclosing functions |
| medium | correctness | enclosing files, direct callers |
| high | correctness, boundaries | enclosing modules, every call site |
| xhigh | correctness, boundaries, lifecycle | the same, plus callers of callers where a contract propagates |
| max | as xhigh, with more reasoning | as xhigh |

The level is picked from prod lines (50 / 300 / 800 / 2000) and lifted by signals. Within 10% above a threshold and with no signal, the lower
level is used, so the same diff gets the same depth on every run. A level you type is run as typed; the kit prints `UNDERKILL` or `OVERKILL`
when it disagrees.

## Budget

`~/.agentic-review-kit/budget.json`:

```json
{
  "five_h_pause": 0.80,
  "week_stop": 0.70,
  "quiet": [["2026-01-12T09:00:00", "2026-01-12T18:00:00"]],
  "run": { "max_usd": 3.0, "max_tokens": null, "max_minutes": 120 },
  "self_metered": { "xai": { "five_h_usd": 5.0, "week_usd": 25.0 } },
  "models": { "finder": "openai-codex/<model>", "refute": "xai/<model>", "thinking": null },
  "coderabbit": { "per_hour": 3 },
  "cursor": { "applies_to": [] }
}
```

| Key | Meaning |
|---|---|
| `five_h_pause` | At this share of the 5-hour window, wait for the reset (`-Wait`, `sweep`) or stop. |
| `week_stop` | At this share of the weekly window, stop. The rest of the week stays yours. |
| `quiet` | Local time windows in which no step starts. |
| `run` | Caps for one `review` or one whole `sweep`. |
| `self_metered` | Spend caps, per provider, for providers that report no quota. |
| `models` | Default finder and refute models, as pi model ids. Unset: pi's default model. |
| `cursor.applies_to` | Providers whose quota is the Cursor subscription pool, for example `["xai"]`. Empty: the pool is reported, not enforced. |

How each provider is read:

| Provider (pi id) | Signal | Source |
|---|---|---|
| `openai-codex` (ChatGPT plan) | 5-hour and weekly percent used, with reset times | the plan's own usage endpoint, with pi's token |
| `xai` (SuperGrok, X Premium) | none found: the API reports only per-minute request and token limits | the kit's ledger against `self_metered` caps |
| `cursor` (Cursor Agent CLI login) | percent used of one billing period, with its reset time; no 5-hour window | the usage call the CLI itself makes, with the CLI's token |
| anything else | none | the kit's ledger; add a `self_metered` entry to cap it |

The Cursor reading is the subscription pool of the Cursor Agent login. `ark usage` always reports it when the CLI is logged in. It is
enforced as the quota of another provider only when you list that provider in `cursor.applies_to`: the kit cannot prove that two logins draw
on one allowance, so you decide. One way to check: note the percentage, run one chunk on the other provider, and read it again. The call is
not a documented interface and can change with any CLI release; when it fails, the line says so and nothing is assumed.

The kit never estimates a percentage. A provider without a quota signal is shown as "not reported", with the spend the kit itself recorded.
That spend is pi's API-equivalent price for the tokens, not a charge; on a subscription it is a relative measure only. A step that ends with
a usage-limit error from the provider stops the review whatever the ledger says.

`~/.agentic-review-kit/ledger.jsonl` holds one line per step. Create `~/.agentic-review-kit/STOP` to end a waiting run.

### Unattended runs

`~/.agentic-review-kit/targets.json` lists the repositories (see `targets.example.json`). `ark sweep` reviews each one that has work since its
last review, waits through 5-hour limits, ends at the weekly stop or the run cap, and writes a report under `~/.agentic-review-kit/sweeps/`.
Schedule it with Task Scheduler or cron.

A sweep only reads repositories and writes under `.review-kit/runs/`. It never edits, commits or pushes.

## Profiles

`.review-kit/profile.json` tells the kit about one repository:

```json
{
  "type": "unity",
  "base": "origin/main",
  "tests": ["Assets/**/Tests/**"],
  "contracts": ["Assets/**/Net/**"],
  "hot": ["Assets/**/*Controller.cs"],
  "conventions": ["AGENTS.md"],
  "counterparts": [{ "path": "../my-game-backend", "note": "REST API the game calls" }]
}
```

- `tests` adds to the built-in test detection. Test lines do not count as size.
- `vendor` globs mark third-party code (beyond the built-in `node_modules`, `Plugins`, `ThirdParty`, `Asset Packages`). It is not reviewed.
- `contracts` and `hot` are globs. A change that touches one raises the level.
- `conventions` are files the finder is told to read for project rules.
- `counterparts` are local clones that share a contract with this repository. The finder reads the other side when a contract file changes,
  and a contract change in a repository with a counterpart is reviewed at `xhigh`.

`.review-kit/profile.md` is free text for the finder: what a reviewer new to the repository must know. The templates carry a checklist per
stack. The Unity one covers per-frame allocation, `UnityEngine.Object` null checks, lifecycle order, subscriptions, serialization renames
and assembly boundaries.

Commit `.review-kit/profile.*`. The `runs/` folder is ignored.

## Findings file

```
Head: 4f2a9c1e...
Merge-base: 81d03b77...
Level: medium
Refute: 1 refuted, 1 confirmed, 0 unclear (xai/<model>)

## F1 src/scores.ts:42
Severity: medium
Summary: submitScore accepts a negative duration
Failure: A request with durationMs = -1 passes the type check and is stored, so the run sorts first on the fastest-time board.
Refute: CONFIRMED - src/scores.ts:42: only typeof is checked; the route in src/index.ts:118 passes the body through

## F2 src/scores.ts:77
Severity: low
Summary: page size is unbounded
Failure: limit=100000 returns every row in one response.
Refute: REFUTED - src/index.ts:96: `const limit = Math.min(Number(q.limit) || 20, 100)`
```

`ark fix <file>` prints a prompt that applies it: refuted findings are skipped, every other finding is checked against the current code first,
and nothing is committed.

## CodeRabbit

With `-Backend both` or `coderabbit`, the kit runs `coderabbit review --agent` on the same range and merges its findings into the file,
marked `[coderabbit]`. They go through the same refute pass. Each call is counted, and the backend is skipped once `coderabbit.per_hour` is
used. Sign in once with `coderabbit auth login`.

The kit does not pin CodeRabbit's output format: it takes every JSON object that names a file and a line. The raw output is kept beside the
findings file.

## Limits of the tool

- Treat the output as a list to check, never as a clearance. A review that finds nothing has not shown the change is correct.
- The finder prompt is new and its recall is not measured.
- Passes with different lenses can report one defect twice in different words; only reports within three lines of each other are merged.
- Refute removes findings that code disproves. It cannot judge intent: "this endpoint has no rate limit" stays confirmed whether or not you
  wanted one.
- Models that follow the reply format badly lose findings: a reply without a JSON array counts as a failed pass, and the file says so.

## Development

```powershell
Invoke-Pester -Path tests
```

Rules for changes are in `AGENTS.md`.

## License

MIT.
