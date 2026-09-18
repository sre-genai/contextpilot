# ContextPilot

A local command-line tool for classifying tasks, redacting common secret formats, reducing tool output, and caching omitted details. It makes no network or model calls at runtime.

## Build and run

```bash
cargo build --release
./target/release/contextpilot --help
```

Optionally copy the release binary to a directory on your PATH.

## What installing this brings

Installing ContextPilot installs its companions too. On the first session, `SessionStart` runs
`scripts/bootstrap.sh`, which builds this plugin's binary with `cargo` when no copy is on
`PATH`, indexes the current project when it has no index yet, and installs whichever of RTK,
ponytail and caveman are missing. Hooks resolve the binary from the plugin data directory, a
bundled `bin/`, then `PATH`.

Everything past the binary runs in the background, logged to `install.log` in the data
directory, because building RTK from source takes minutes and a session must not wait on it.
The first session reports what it started as a `systemMessage`, so the notice reaches the
terminal rather than the model's context.

Running the script repeatedly, or in several sessions at once, does the work once:

| Step | What makes it repeatable |
|---|---|
| Build the binary | Skipped when a binary is already on `PATH` or in the data directory |
| Index the project | Skipped when `.contextpilot/graph.json` exists; the index is written to a staging file and renamed, so a reader never sees half of one and two indexers racing leave one whole file |
| Install a companion | Skipped when it is present, when its installer is absent, or when it was attempted before. Delete `attempted-<name>` in the data directory to ask again |
| Concurrent sessions | Each step is claimed with `mkdir`, which is atomic; a session that loses the race skips that step rather than duplicating it |

Set `CONTEXTPILOT_NO_AUTOINSTALL=1` to install nothing but this plugin's own binary. Each
companion stays optional at runtime: no RTK means the character-budget path, no style plugin
means a self-contained profile, no index means no dependency facts.

Installing this plugin therefore fetches software from three other projects, one of them by
running `npx` against a GitHub repository. That is a supply chain your users inherit from this
plugin, and the opt-out above is the only thing that prevents it.

## Routing to style plugins

Four tools cut four different pools of tokens, and the classifier decides which apply:

| Layer | Reduces | Handled by |
|---|---|---|
| Behaviour in | building and exploring beyond the request | ponytail |
| Prose out | the assistant's own reply | caveman |
| Tool output in | command noise | RTK, then this tool |
| Discovery | repeated grep and file reads | the code graph |

At prompt time the `UserPromptSubmit` hook issues one short directive per **installed** style
plugin, at the level the complexity implies: simple work gets the laziest setting, involved
work keeps room to investigate, and terse prose is skipped for heavy tasks where the
explanation carries the result. Nothing is issued for a plugin that is not installed, so the
agent is never told to apply tooling it does not have; with none installed, a self-contained
profile is sent instead.

When the policy calls for the graph and the request names an indexed symbol, the hook also
attaches its callers and callees:

```text
> refactor the classify function across services
Apply ponytail at full intensity. Known dependencies: classify: called by [hook, main,
process, ...]; uses []
```

That replaces the grep-and-read loop the agent would otherwise run to learn the same thing. It
reads a stored index only, never scanning on the fly, so run `graph index` first; symbols and
edges are capped so the addition stays a line or two.

## RTK

[RTK](https://github.com/rtk-ai/rtk) filters output per command: it knows what `cargo test`
and `git status` mean, where a character budget only knows how long they are. When `rtk` is on
`PATH`, the hook routes commands it has a filter for, and the result still passes through
redaction, the budget and the cache. Measured here with `cl100k_base`:

| command | raw | ContextPilot | RTK | both |
|---|---|---|---|---|
| `cargo test` | 263 | 262 | 61 | 38 |
| `cargo build --verbose` | 1,033 | 591 | 29 | 29 |
| `git status` | 58 | 58 | 18 | 18 |
| `ls -laR` | 424,987 | 710 | 292 | 292 |

Only the first word of a command is considered, so compound commands like
`cd src && cargo test` are left alone rather than quietly changing meaning. Commands RTK has no
filter for, such as `terraform plan`, take the character-budget path instead.

Do not run `rtk init`: it installs its own `PreToolUse` hook, and two hooks rewriting the same
command would nest. Installing the binary is enough.

## Use as a plugin

The same binary serves Claude Code and Codex: both report shell calls as `tool_name: "Bash"`
with a string `command`, and both accept `updatedInput` from a `PreToolUse` hook.

```bash
./scripts/install.sh
```

That builds the release binary, places it in `bin/` and on `PATH`, and appends the Codex hook
block to `$CODEX_HOME/config.toml` (default `~/.codex/config.toml`), backing up any existing
file and skipping the append when the hooks are already registered.

For Claude Code, install from the marketplace defined at the repository root:

```bash
claude plugin marketplace add ./path/to/repository
claude plugin install contextpilot@contextpilot
```

`claude --plugin-dir ./contextpilot` loads it for a single session instead. The hooks resolve
the binary from the plugin directory first and `PATH` second, and do nothing if neither exists,
so a partial install degrades to no behavior change rather than to failing commands. Disable
with `claude plugin disable contextpilot`.

Two hooks do the work. `UserPromptSubmit` stashes the current task text under the session id in
the temporary directory; `PreToolUse` rewrites each Bash command to capture its combined output
to a temporary file and feed that through `process`, using the stashed task for classification.
Output reduction therefore happens before the model sees anything, which `PostToolUse` cannot
do in Claude Code: that event can only append context.

The rewrite preserves working-directory changes and exit status:

```bash
__cp_out=$(mktemp); {
<original command>
} >"$__cp_out" 2>&1; __cp_rc=$?; "<binary>" process '<task>' <"$__cp_out"; rm -f "$__cp_out"; (exit $__cp_rc)
```

The brace group runs in the calling shell, so `cd` still persists, and `(exit N)` restores the
status without terminating that shell. Commands containing `exit` or `exec`, backgrounded
commands, and commands already mentioning `contextpilot` are left untouched, because their
output cannot be captured this way. Rewriting merges stderr into stdout.

## Execution policy

`classify` turns a prompt into an execution policy using deterministic string rules, so it
costs no model tokens and no model call:

```json
{
  "task": ["debug", "devops"],
  "complexity": "heavy",
  "behavior_profile": "heavy",
  "codegraph": true,
  "rtk": true,
  "caveman": true,
  "context_cache": true,
  "context_budget": 30000,
  "output_budget": 8000,
  "search_depth": 5,
  "secret_guard": true
}
```

Tasks are `question`, `code_change`, `debug`, `refactor`, `architecture`, `devops`, `test` and
`search`; a prompt can carry several. Weighted signals produce a complexity score that selects
lite, normal or heavy, and debug or devops work never lands in the tightest budget, because
those tasks read long tool output even when the prompt is short.

Every field now drives something:

| Field | Effect |
|---|---|
| `output_budget`, `caveman`, `context_cache` | Drive `process`; compression additionally requires the output to exceed its budget |
| `secret_guard` | Always true. Redaction is unconditional and no prompt can switch it off |
| `task`, `complexity` | Select the budgets, and `complexity` selects the behaviour profile |
| `behavior_profile` | Delivered to the agent at prompt time by the `UserPromptSubmit` hook |
| `rtk` | Reported; the `PreToolUse` hook routes each command on its own evidence, see below |
| `codegraph` | Reported; `graph query` resolves callers and callees on demand |
| `search_depth` | Caps how many files `guard` returns |
| `context_budget` | Advisory. A local tool cannot enforce the agent's context window |

The budgets are ceilings rather than targets, and they count Unicode characters, not tokens.

## Process tool output

```bash
some-command 2>&1 | ./target/release/contextpilot process "investigate failing tests"
```

When `process` shortens output it returns JSON containing the execution policy, a `summary` of what the full output said, the reduced output, and a `cache_ref`; when nothing needed cutting it prints the redacted text as-is. It redacts first and applies an output budget of 1,200, 4,000, or 8,000 Unicode characters, depending on the task classification. These are character limits, not token counts. The context budget is advisory; this tool cannot control the calling application's context window. The output budget applies to the `output` field, excluding JSON escaping and metadata.

Any shortened output is cached, including for tasks whose classification does not otherwise recommend caching. No hooks are installed automatically: invoke the pipeline explicitly from your shell or tool runner.

### When piping pays off

`process` only emits JSON when it actually shortened something. If the redacted input already
fits the output budget, it prints that text directly, so the wrapper never costs tokens on
small output and no external size check is needed. When it does shorten, measured with
`cl100k_base` on real command output, the reduction is 75-99%: the result is capped at the
output budget regardless of input size.

Entries older than 30 days are removed whenever a new one is written, so the cache does not
grow without bound. `contextpilot clean` still prunes on demand with a different age.

```bash
./target/release/contextpilot retrieve ctx://ID
./target/release/contextpilot clean --older-than-days 30
```

Cache commands accept `--root DIRECTORY`; the default is `~/.contextpilot/cache`. New entries use full SHA-256 IDs. Retrieval also accepts existing 12-character IDs. Cleanup uses file modification time and only removes regular cache files with recognized ID names; `--older-than-days 0` removes all such entries. Reusing an entry does not renew its modification time. On Unix, cache directories use mode 0700 and files use 0600.

## Individual commands

```bash
./target/release/contextpilot classify "investigate timeout"
printf 'password="example secret"\n' | ./target/release/contextpilot redact
some-command 2>&1 | ./target/release/contextpilot compress --context 5 --max-chars 4000
some-command 2>&1 | ./target/release/contextpilot cache
./target/release/contextpilot graph index ./src
./target/release/contextpilot graph query classify ./src
./target/release/contextpilot guard "why does login fail" .
./target/release/contextpilot stats
./target/release/contextpilot install-policy --project .
```

Input that is not valid UTF-8 is read lossily rather than rejected, so a stray byte in a log cannot discard the whole output.

Compression keeps the beginning/end and neighborhoods around warning/error markers, then applies the character cap. A tight cap can still omit relevant details; use `process` for recoverable output. Standalone `compress` does not cache.

`graph index` scans the tree for symbol definitions and call sites and writes
`.contextpilot/graph.json`; `graph query SYMBOL` reports where a symbol is defined, what calls
it, and what it calls, building the index on the fly when none is stored. Definitions and calls
are found by pattern and each call is attributed to the nearest definition above it, which
resolves plain function and method names but not types, receivers or dynamic dispatch, so
same-named symbols across files collapse into one node. A 152-file tree indexes in about two
seconds.

`guard` ranks the files a request touches by term overlap, weighting filename matches, and
shows the last commit to each. It returns at most `search_depth` files, so a lite request gets
one and a heavy one gets five.

`stats` reports recorded runs: characters in and out, estimated tokens saved, cache use, median
latency and a count per complexity. Token figures are estimates at three characters per token,
measured across build logs, listings and test output; budgets themselves are enforced in
characters. Missing paths and unreadable files cause errors. Common build directories are
pruned, but project ignore files are not interpreted.

`install-policy` writes `.contextpilot/POLICY.md`. Existing policies are preserved unless `--force` is passed. Reference this file from your tool runner's project instructions if desired. This replaces the prototype's tool-specific installer; any earlier policy files remain untouched. Classification no longer includes the prototype's redundant internal policy label.

Redaction covers common credential assignments, quoted/JSON password fields, bearer/basic credentials, selected token formats, and private keys. Assignment matching allows prefixed names, so `DB_PASSWORD`, `MY_API_KEY`, and `AWS_SECRET_ACCESS_KEY` are covered. It is heuristic: arbitrary secrets can escape detection. Redacted output is intended for text inspection and may no longer be valid structured JSON. Use only a dedicated cache directory owned by your account. This is a local CLI, with no browser interface or background server.

## Verify

```bash
cargo test
cargo clippy --all-targets -- -D warnings
```
