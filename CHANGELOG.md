# Changelog

## 0.4.0

- `allocation` in budget.json: a per-provider total the kit may spend, in percentage points of the weekly allowance or in ledger USD,
  counted from the first gated step and kept through 5-hour and weekly resets.
- `role_takeover`: when one role's provider has spent its allocation, the other role's model does both roles inside its own allocation.
- `ark allocation` prints the counts; `ark allocation reset` starts a new count.
- A points allocation on a provider that reports no quota stops the run instead of running unmeasured.

## 0.3.0

- `ark usage` reports the subscription pool of the Cursor Agent CLI login: percent used, remaining, period length and reset time.
- `cursor.applies_to` in budget.json makes that pool the enforced quota of another provider.
- The gate handles a provider with one billing period and no 5-hour window.
## 0.2.0

- `ark audit-plan` and `ark audit`: review the current code by folder chunks instead of by diff. Old defects count; history is not read.
- Audit finder prompt, and a resumable plan file with a measured tokens-per-line rate.
- Fix: an empty `quiet` list in budget.json stopped every run with a date conversion error.
## 0.1.0

- `ark review`: sizes a change, runs finder passes and a refute pass as headless pi sessions, writes a findings file.
- Budget gate before every step: 5-hour and weekly use of a ChatGPT plan, self-metered caps for providers that report no quota, run caps,
  quiet windows.
- `ark sweep` for unattended reviews of several repositories inside the budget.
- `ark assess`, `ark baseline`, `ark usage`, `ark init`, `ark fix`.
- Profiles for Unity, TypeScript workers and Python backends.
- CodeRabbit CLI as an optional second finder with an hourly allowance.
