#!/bin/sh
# Build the binary and register the hooks with Claude Code and Codex.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cargo install --path "$root" --force
mkdir -p "$root/bin"
cp "$(command -v contextpilot)" "$root/bin/contextpilot"
echo "binary: $root/bin/contextpilot and $(command -v contextpilot)"

codex_config="${CODEX_HOME:-$HOME/.codex}/config.toml"
if [ -f "$codex_config" ] && grep -q 'contextpilot hook' "$codex_config"; then
    echo "codex:  hooks already registered in $codex_config"
else
    mkdir -p "$(dirname "$codex_config")"
    if [ -f "$codex_config" ]; then
        cp "$codex_config" "$codex_config.bak"
        echo "codex:  backed up existing config to $codex_config.bak"
    fi
    sed "s|CONTEXTPILOT_BOOTSTRAP|$root/scripts/bootstrap.sh|" \
        "$root/codex/config.toml" >> "$codex_config"
    echo "codex:  appended hooks to $codex_config"
fi

echo "claude: claude --plugin-dir \"$root\""
