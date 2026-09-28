#!/bin/sh
# SessionStart: build this plugin's own binary, index the project, and name any optional
# companion that is missing.
#
# Companions are NOT installed for you. Each one is other people's software, and deciding
# to run it belongs to whoever owns the machine. Set CONTEXTPILOT_AUTOINSTALL=1 to have
# this script install the ones it can, pinned to a known release.
#
# Safe to run any number of times, and in several sessions at once: every step checks for
# what it would create, and one lock keeps concurrent sessions off the same work. Every
# test is an `if` condition rather than an `&&` list, so `set -e` cannot end the script on
# a check that simply answered "no".
set -eu
root=${CLAUDE_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
data=${CLAUDE_PLUGIN_DATA:-${XDG_DATA_HOME:-$HOME/.contextpilot}/plugin}
log="$data/install.log"
mkdir -p "$data"

# Pinned: an unpinned build installs whatever the default branch happens to be today.
RTK_TAG=v0.50.0

have() { command -v "$1" >/dev/null 2>&1; }
claim() { mkdir "$data/$1.lock" 2>/dev/null; }
release() { rmdir "$data/$1.lock" 2>/dev/null || true; }
installed() {
    case $1 in
        rtk) if have rtk; then return 0; fi ;;
        ponytail | caveman)
            if have claude; then
                if claude plugin list 2>/dev/null | grep -q "$1"; then return 0; fi
            fi
            ;;
    esac
    return 1
}

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

# 3. Companions: reported by default, installed only on request.
missing=""
for name in rtk ponytail caveman; do
    if ! installed "$name"; then missing="$missing $name"; fi
done
if [ -z "$missing" ]; then exit 0; fi

if [ -z "${CONTEXTPILOT_AUTOINSTALL:-}" ]; then
    # Named once per installation, on the terminal rather than in the model's context.
    if [ ! -f "$data/advised" ]; then
        : >"$data/advised"
        printf '{"systemMessage":"ContextPilot is active. Optional, not installed:%s. Install all with: claude plugin install contextpilot-full@contextpilot  |  or individually: cargo install --git https://github.com/rtk-ai/rtk --tag %s  /  claude plugin marketplace add DietrichGebert/ponytail && claude plugin install ponytail@ponytail  /  npx skills add https://github.com/juliusbrussee/caveman --skill caveman"}\n' \
            "$missing" "$RTK_TAG"
    fi
    exit 0
fi

# Opt-in path. Only what can be pinned and audited is automated here; caveman installs by
# running a fetched npm package, so it stays a command the user runs deliberately.
if ! claim companions; then exit 0; fi
wanted=""
for name in $missing; do
    if [ -f "$data/attempted-$name" ]; then continue; fi
    case $name in
        rtk) if ! have cargo; then continue; fi ;;
        ponytail) if ! have claude; then continue; fi ;;
        caveman) continue ;;
    esac
    : >"$data/attempted-$name"
    wanted="$wanted $name"
done

if [ -z "$wanted" ]; then
    release companions
    exit 0
fi

(
    for name in $wanted; do
        case $name in
            rtk)
                cargo install --git https://github.com/rtk-ai/rtk --tag "$RTK_TAG" --locked >>"$log" 2>&1 || true
                ;;
            ponytail)
                claude plugin marketplace add DietrichGebert/ponytail >>"$log" 2>&1 || true
                claude plugin install ponytail@ponytail >>"$log" 2>&1 || true
                ;;
        esac
    done
    release companions
) &

printf '{"systemMessage":"ContextPilot is installing in the background:%s (CONTEXTPILOT_AUTOINSTALL=1). Progress: %s"}\n' \
    "$wanted" "$log"
exit 0
