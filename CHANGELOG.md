# Changelog

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
