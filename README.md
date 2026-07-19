# Codex CC Switch state synchronizer

`codex-ccswitch.bat` keeps Codex's live configuration, CC Switch provider
templates, common configuration, runtime paths, and official ChatGPT login
restore references consistent on Windows.

The BAT file contains an embedded Python program and requires Python 3 on
`PATH`.

## Configuration boundaries

The common CC Switch configuration contains settings that are safe to share
across providers, such as desktop preferences, feature flags, privacy settings,
plugins, and MCP definitions without secret environment tables.

The following remain provider-specific or machine-local and are not copied into
the common configuration:

- model, provider, reasoning effort, model catalog, service tier, and personality
- provider URLs, bearer tokens, API keys, and authentication restrictions
- project trust, hook trust state, profiles, and MCP environment tables
- Node REPL runtime paths

Project and hook trust tables are mirrored directly from live config into each
local provider template, but never enter the common configuration. An empty
live trust set clears stale provider copies.

Known model defaults are only used when the current value is missing or invalid:

| Model | Allowed effort | Repair default |
| --- | --- | --- |
| GPT-5.6 Sol / Terra | low through ultra | max |
| GPT-5.5 | low through xhigh | xhigh |
| Grok 4.5 | low, medium, high | high |

Valid provider-specific values are preserved. In particular, `max` is never
rewritten to `ultra`. Catalog discovery only considers catalog-shaped files
with trusted model-catalog names and non-empty reasoning capabilities. The
catalog is repaired before the effort is validated.

## Commands

```bat
codex-ccswitch.bat status
codex-ccswitch.bat dry-run
codex-ccswitch.bat all
codex-ccswitch.bat sync
codex-ccswitch.bat sync-live
codex-ccswitch.bat repair-runtime
codex-ccswitch.bat capture-auth
codex-ccswitch.bat capture-auth-force
codex-ccswitch.bat restore-auth
codex-ccswitch.bat restore-auth-force
codex-ccswitch.bat self-check
```

Running without a command is equivalent to `all`. It captures a current
official login before any operation that may restart CC Switch, synchronizes
public configuration, then repairs runtime paths. Before auth or runtime work
restarts CC Switch, the current public and local trust state is merged into the
proxy recovery snapshot so an older snapshot cannot roll back `config.toml`.
Automatic source selection only publishes a live config that still contains
the expected approval, sandbox, desktop, and features sections; otherwise it
falls back to the canonical snapshot. `sync-live` applies the same completeness
check.

Automatic restore is intentionally disabled. `restore-auth` refuses to replace
a different live official login or use an expired backup. The `-force` command
is an explicit emergency rollback and can still require a new browser login.
Likewise, normal `capture-auth` refuses to overwrite a newer or ambiguous DB
credential; `capture-auth-force` is reserved for a deliberate choice to keep
the current live ChatGPT login. If live auth is not official, `all`, `sync`,
`sync-live`, and `repair-runtime` stop before changing CC Switch state.

Every database write stops `cc-switch.exe`, creates a rollback backup, commits
the scoped changes, verifies the result, and restarts CC Switch. Text files are
replaced atomically. Backups live under `~/.codex/.tmp`; database and auth
operations can contain credentials, so that directory must remain local and
must never be committed or copied to a public repository.

SQLite and `config.toml` cannot share one filesystem transaction. The script
holds an immediate database transaction while atomically replacing the file
and performs compensating rollback on ordinary failures. After a power loss or
forced process termination during a write, use the newest operation backup for
manual recovery before running the script again.

## Current CC Switch limitation

CC Switch 3.17.0 crash recovery restores a non-empty auth snapshot verbatim and
does not apply `preserveCodexOfficialAuthOnSwitch` on that path. Its generated
model catalog can also flatten official reasoning levels. Until upstream fixes
are released, keep the official auth restore snapshot current and use an
external model catalog with the full supported effort list.

- [CC Switch #5501](https://github.com/farion1231/cc-switch/issues/5501)
- [CC Switch PR #5535](https://github.com/farion1231/cc-switch/pull/5535)
- [OpenAI Codex #33233](https://github.com/openai/codex/issues/33233)

## Tests

```powershell
python -m unittest discover -s tests -v
```

Tests extract the embedded Python into a temporary HOME and use a synthetic
SQLite database and synthetic credentials. They do not access the user's real
Codex or CC Switch state.
