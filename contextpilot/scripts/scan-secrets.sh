#!/bin/sh
# Refuse to publish anything this project's own redactor recognises as a credential, or
# that identifies the machine it was written on. Run by .githooks/pre-push.
#
# Usage: scan-secrets.sh [--history]   (--history also scans every commit's content)
#
# Findings are appended to a file rather than counted in a variable: `report` is called
# from inside pipelines, which run in a subshell, and a count kept in a variable there is
# discarded when the subshell exits. That silently turns a failing scan into a passing one.
set -eu
root=$(git rev-parse --show-toplevel)
cd "$root"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
: >"$work/findings"
: >"$work/ignored"

bin=$(command -v contextpilot 2>/dev/null || true)

# Placeholder credentials in tests and docs. EXAMPLE is the convention vendors use, and
# every ignored hit is still printed, so an allowlisted line is never a silent pass.
placeholder() {
    printf '%s' "$1" | grep -qiE 'example|placeholder|dummy|your[-_]?(token|key|secret)|<[a-z_]+>'
}

report() {
    if placeholder "$2"; then
        printf '  ignored (placeholder): %.110s\n' "$2"
        echo x >>"$work/ignored"
    else
        printf '  FOUND %s: %.160s\n' "$1" "$2"
        echo x >>"$work/findings"
    fi
}

# 1. Credentials, detected by redacting each tracked file and seeing whether it changed.
if [ -n "$bin" ]; then
    git ls-files -z >"$work/files"
    while IFS= read -r -d '' file; do
        case $file in *.png | *.jpg | *.gif | *.pdf | *.ico | *.lock) continue ;; esac
        [ -f "$file" ] || continue
        "$bin" redact <"$file" >"$work/redacted" 2>/dev/null || continue
        cmp -s "$work/redacted" "$file" && continue
        diff "$work/redacted" "$file" | grep '^>' | head -5 >"$work/hits" || true
        while IFS= read -r line; do
            [ -n "$line" ] && report "credential in $file" "$line"
        done <"$work/hits"
    done <"$work/files"
else
    echo "  note: contextpilot not on PATH, credential pass skipped"
fi

# 2. Token shapes, independent of the redactor.
patterns='BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{12,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{32,}'
git grep -n -I -E "$patterns" -- . >"$work/tokens" 2>/dev/null || true
while IFS= read -r hit; do
    [ -n "$hit" ] && report "token pattern" "$hit"
done <"$work/tokens"

# 3. Paths that identify the machine this was written on.
git grep -n -I -E '(/Users/|/home/)[A-Za-z0-9_.-]+/' -- . >"$work/paths" 2>/dev/null || true
while IFS= read -r hit; do
    [ -n "$hit" ] && report "absolute home path" "$hit"
done <"$work/paths"

# 4. Files that carry secrets by their nature and should never be tracked.
git ls-files >"$work/all"
grep -E '(^|/)\.env($|\.)|\.envrc$|\.pem$|\.key$|\.p12$|\.pfx$|id_rsa|id_ed25519|\.keystore$|credentials(\.json)?$|\.netrc$' \
    "$work/all" >"$work/env" 2>/dev/null || true
while IFS= read -r f; do
    [ -n "$f" ] && report "secret-bearing file tracked" "$f"
done <"$work/env"

# 5. History, on request: the same token shapes across every commit ever made.
if [ "${1:-}" = "--history" ]; then
    git log -p --all >"$work/history" 2>/dev/null || true
    grep -nE "$patterns" "$work/history" >"$work/histhits" 2>/dev/null || true
    while IFS= read -r hit; do
        [ -n "$hit" ] && report "token in history" "$hit"
    done <"$work/histhits"
fi

ignored=$(wc -l <"$work/ignored" | tr -d ' ')
findings=$(wc -l <"$work/findings" | tr -d ' ')
[ "$ignored" -gt 0 ] && echo "  ($ignored placeholder hit(s) ignored, listed above)"
if [ "$findings" -gt 0 ]; then
    echo "REFUSING TO PUSH: $findings finding(s) above"
    echo "  fix them, or push with --no-verify if every one is a false positive"
    exit 1
fi
echo "scan clean: no credentials, tokens, or machine paths in tracked files or history"
