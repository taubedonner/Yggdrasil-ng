#!/usr/bin/env bash
#
# migrate-from-go.sh
#
# Migrates a Debian/Ubuntu system from the upstream Go yggdrasil package to
# yggdrasil-ng (Rust rewrite):
#
#   1. Extracts PrivateKey, Peers, and Listen URLs from /etc/yggdrasil/yggdrasil.conf
#      (the HJSON-style config used by the Go implementation).
#   2. Stops the running yggdrasil service and removes the Go package.
#   3. Downloads and installs the yggdrasil-ng .deb.
#   4. Writes a new /etc/yggdrasil/yggdrasil.toml preserving the identity,
#      outbound peers, and listen addresses.
#   5. Prints the command to enable and start the new service.
#
# Usage:
#   sudo ./migrate-from-go.sh
#
# The old config is preserved at /etc/yggdrasil/yggdrasil.conf.bak.

set -euo pipefail

PKG_URL="https://github.com/Revertron/Yggdrasil-ng/releases/download/v0.1.4/yggdrasil-ng_0.1.4-1_amd64.deb"
OLD_CONF="/etc/yggdrasil/yggdrasil.conf"
NEW_CONF="/etc/yggdrasil/yggdrasil.toml"
BACKUP_CONF="/etc/yggdrasil/yggdrasil.conf.bak"

err() { echo "error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "must be run as root (try: sudo $0)"
[[ -r "$OLD_CONF" ]] || err "old config not found at $OLD_CONF — nothing to migrate"

command -v dpkg >/dev/null       || err "dpkg not found — this script requires a Debian-based system"
command -v apt-get >/dev/null    || err "apt-get not found — this script requires a Debian-based system"
command -v awk >/dev/null        || err "awk not found"

# Pick a downloader that's likely present.
if command -v curl >/dev/null; then
    DOWNLOAD=(curl -fL --retry 3 -o)
elif command -v wget >/dev/null; then
    DOWNLOAD=(wget -O)
else
    err "neither curl nor wget is installed"
fi

echo "==> Backing up $OLD_CONF to $BACKUP_CONF"
cp -a "$OLD_CONF" "$BACKUP_CONF"

echo "==> Parsing $OLD_CONF"

# Extract the hex private key (single line: `PrivateKey: <hex>`).
PRIVATE_KEY="$(awk '
    /^[[:space:]]*PrivateKey:[[:space:]]*/ {
        sub(/^[[:space:]]*PrivateKey:[[:space:]]*/, "")
        sub(/[[:space:]]+$/, "")
        print
        exit
    }
' "$OLD_CONF")"

[[ -n "$PRIVATE_KEY" ]] || err "failed to extract PrivateKey from $OLD_CONF"

# Extract the URIs inside a named block of the form:
#   Name: [
#     tcp://host:port
#     ...
#   ]
# Comments starting with '#' and blank lines are skipped. Any trailing comment
# on the same line as a URI is stripped. Output is one URI per line.
extract_block() {
    local name="$1"
    awk -v name="$name" '
        BEGIN { in_block = 0 }

        # Normalize the current record: strip leading whitespace.
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
        }

        # Opening of the block: matches `Name: [` (possibly with URIs on the same line).
        !in_block && line ~ ("^" name ":[[:space:]]*[[]") {
            rest = line
            sub("^" name ":[[:space:]]*[[]", "", rest)
            if (rest ~ /\]/) {
                # One-line form: `Name: [ uri1 uri2 ]`.
                sub(/\].*$/, "", rest)
                sub(/#.*$/, "", rest)
                n = split(rest, parts, /[[:space:],]+/)
                for (i = 1; i <= n; i++)
                    if (parts[i] != "") print parts[i]
                next
            }
            in_block = 1
            sub(/#.*$/, "", rest)
            sub(/,$/, "", rest)
            sub(/^[[:space:]]+/, "", rest)
            sub(/[[:space:]]+$/, "", rest)
            if (rest != "") print rest
            next
        }

        # Closing of the block: line starts with `]`.
        in_block && line ~ /^\]/ {
            in_block = 0
            next
        }

        # Body of the block: one URI per line, ignoring comments and commas.
        in_block {
            sub(/#.*$/, "", line)
            sub(/,$/, "", line)
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line != "") print line
        }
    ' "$OLD_CONF"
}

mapfile -t PEERS  < <(extract_block "Peers")
mapfile -t LISTEN < <(extract_block "Listen")

echo "    private key: ${PRIVATE_KEY:0:16}... (${#PRIVATE_KEY} chars)"
echo "    peers:       ${#PEERS[@]}"
echo "    listen:      ${#LISTEN[@]}"

echo "==> Stopping and removing the Go yggdrasil package"
systemctl stop yggdrasil 2>/dev/null || true
# `remove` (not `purge`) keeps the old config file on disk.
DEBIAN_FRONTEND=noninteractive apt-get remove -y yggdrasil || true

echo "==> Downloading $PKG_URL"
TMPDEB="$(mktemp --suffix=.deb)"
trap 'rm -f "$TMPDEB"' EXIT
"${DOWNLOAD[@]}" "$TMPDEB" "$PKG_URL"

echo "==> Installing $(basename "$TMPDEB")"
# dpkg may report missing dependencies; `apt-get install -f` resolves them.
if ! dpkg -i "$TMPDEB"; then
    echo "    resolving missing dependencies with apt-get install -f"
    DEBIAN_FRONTEND=noninteractive apt-get install -f -y
fi

echo "==> Writing $NEW_CONF"
mkdir -p "$(dirname "$NEW_CONF")"

# Emit a TOML array from a bash array of strings.
toml_array() {
    local -n arr="$1"
    if [[ ${#arr[@]} -eq 0 ]]; then
        printf '[]\n'
        return
    fi
    printf '[\n'
    local item
    for item in "${arr[@]}"; do
        # Escape backslashes and double quotes for TOML basic strings.
        item="${item//\\/\\\\}"
        item="${item//\"/\\\"}"
        printf '  "%s",\n' "$item"
    done
    printf ']\n'
}

{
    printf '# Yggdrasil-ng configuration — migrated from %s\n' "$OLD_CONF"
    printf '# Original file backed up at %s\n\n' "$BACKUP_CONF"

    printf 'private_key = "%s"\n\n' "$PRIVATE_KEY"

    printf 'peers = '
    toml_array PEERS
    printf '\n'

    printf 'listen = '
    toml_array LISTEN
    printf '\n'

    printf 'admin_listen = "tcp://localhost:9001"\n'
    printf 'if_name = "auto"\n'
    printf 'if_mtu = 65535\n\n'

    printf '[node_info]\n\n'

    printf '[[multicast_interfaces]]\n'
    printf 'filter = "*"\n'
    printf 'beacon = true\n'
    printf 'listen = true\n'
} >"$NEW_CONF"

chmod 600 "$NEW_CONF"

echo
echo "Migration complete."
echo "  new config:   $NEW_CONF"
echo "  old config:   $BACKUP_CONF (backup)"
echo
echo "Start the new service with:"
echo "  systemctl enable --now yggdrasil"
