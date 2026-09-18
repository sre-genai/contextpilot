#!/bin/sh
# SessionStart: ensure the binary exists, then install missing companions in the background.
# Safe to run any number of times, and in several sessions at once: every step checks for
# what it would create, each companion is attempted at most once, and one lock keeps
# concurrent sessions from installing the same thing twice.
# Set CONTEXTPILOT_NO_AUTOINSTALL=1 to skip the companions entirely.
#
# Every test is written as an `if` condition rather than an `&&` list, so `set -e` cannot
# end the script on a check that simply answered "no".
set -eu
root=${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
# Codex sets no plugin-data variable, so fall back to a per-user directory rather than
# writing markers, locks and logs into the plugin's own checkout.
data=${CLAUDE_PLUGIN_DATA:-${XDG_DATA_HOME:-$HOME/.contextpilot}/plugin}
log="$data/install.log"
mkdir -p "$data"

have() { command -v "$1" >/dev/null 2>&1; }
# mkdir is atomic: whoever creates the directory owns that piece of work.
claim() { mkdir "$data/$1.lock" 2>/dev/null; }
release() { rmdir "$data/$1.lock" 2>/dev/null || true; }
installed() { # installed <name>: already present by any route?
    case $1 in
        rtk) if have rtk; then return 0; fi ;;
        ponytail|caveman)
            if have claude; then
                if claude plugin list 2>/dev/null | grep -q "$1"; then return 0; fi
            fi
            ;;
    esac
    return 1
}
installable() { # installable <name>: is the tool that installs it available?
    case $1 in
        rtk) have cargo ;;
        ponytail) have claude ;;
        caveman) have npx ;;
        *) return 1 ;;
    esac
}

# Keep the log from growing without bound across sessions.
if [ -f "$log" ]; then
    if [ "$(wc -c <"$log")" -gt 1048576 ]; then
        tail -c 262144 "$log" >"$log.tmp"
        mv "$log.tmp" "$log"
    fi
fi

# 1. This plugin's own binary, without which every other hook is a no-op.
bin=$(command -v contextpilot 2>/dev/null || true)
if [ -z "$bin" ]; then bin="$data/bin/contextpilot"; fi
if [ ! -x "$bin" ]; then
    if have cargo; then
        if claim build; then
            cargo install --path "$root" --root "$data" >>"$log" 2>&1 || true
            release build
        fi
    fi
fi

# 2. An index for this project, so dependency facts are available to the classifier.
if [ -x "$bin" ]; then
    if [ ! -f ".contextpilot/graph.json" ]; then
        if claim index; then
            ("$bin" graph index . >>"$log" 2>&1 || true; release index) &
        fi
    fi
fi

# 3. Companions. Each is attempted at most once: the marker is written before the attempt,
# so a tool that refuses to install is not retried every session. Delete the marker in the
# plugin data directory to ask for another attempt.
if [ -n "${CONTEXTPILOT_NO_AUTOINSTALL:-}" ]; then exit 0; fi
if ! claim companions; then exit 0; fi

wanted=""
for name in rtk ponytail caveman; do
    if [ -f "$data/attempted-$name" ]; then continue; fi
    if installed "$name"; then continue; fi
    if ! installable "$name"; then continue; fi
    : >"$data/attempted-$name"
    wanted="$wanted $name"
done

if [ -z "$wanted" ]; then
    release companions
    exit 0
fi

# One worker, installs in sequence, lock held until the last one finishes.
(
    for name in $wanted; do
        case $name in
            rtk)
                cargo install --git https://github.com/rtk-ai/rtk --locked >>"$log" 2>&1 || true
                ;;
            ponytail)
                claude plugin marketplace add DietrichGebert/ponytail >>"$log" 2>&1 || true
                claude plugin install ponytail@ponytail >>"$log" 2>&1 || true
                ;;
            caveman)
                npx -y skills add https://github.com/juliusbrussee/caveman --skill caveman >>"$log" 2>&1 || true
                ;;
        esac
    done
    release companions
) &

printf '{"systemMessage":"ContextPilot is installing in the background:%s. Progress: %s. Set CONTEXTPILOT_NO_AUTOINSTALL=1 to opt out."}\n' \
    "$wanted" "$log"
exit 0
