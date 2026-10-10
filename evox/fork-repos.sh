#!/usr/bin/env bash
#
# Fork the T812 source repositories into your GitHub account with the gh CLI
# and point evox/manifests/*.xml at the forks.
#
#   gh auth login                 # once
#   ./evox/fork-repos.sh          # fork, verify pinned commits, rewrite manifests
#   ./evox/fork-repos.sh --org my-org --no-rewrite
#
# All branches are copied (not only the default one), so lineage-23.2,
# lineage-24.0, sixteen, seventeen, ... stay available.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"

# Remote name in the manifests -> upstream owner.
declare -A REMOTE_OWNER=(
    [diggieman]="diggieman"
    [millennium]="MillenniumOSS"
)

ORG=""
REWRITE=1

usage() {
    cat <<EOF
Usage: $(basename "$0") [--org ORG] [--no-rewrite]

  --org ORG       fork into an organization instead of your user account
  --no-rewrite    only fork and verify, leave the manifests untouched
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --org)        ORG="${2:?}"; shift 2 ;;
        --no-rewrite) REWRITE=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v gh >/dev/null || { echo "gh is not installed: https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "run 'gh auth login' first" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

OWNER="${ORG:-$(gh api user --jq .login)}"
echo "==> Forking into: ${OWNER}"

# remote<TAB>name<TAB>revision for every project in both manifests.
mapfile -t PROJECTS < <(python3 -I - "${MANIFEST_DIR}"/*.xml <<'PY' | sort -u
import sys
import xml.etree.ElementTree as ET
for f in sys.argv[1:]:
    for p in ET.parse(f).getroot().iter("project"):
        print(f'{p.get("remote")}\t{p.get("name")}\t{p.get("revision")}')
PY
)

declare -A SEEN=()
failed=0
for line in "${PROJECTS[@]}"; do
    IFS=$'\t' read -r remote name rev <<<"$line"
    upstream="${REMOTE_OWNER[$remote]:?unknown remote $remote}/${name}"
    fork="${OWNER}/${name}"

    if [[ -z "${SEEN[$upstream]:-}" ]]; then
        if gh repo view "$fork" >/dev/null 2>&1; then
            parent=$(gh repo view "$fork" --json parent --jq '.parent | "\(.owner.login)/\(.name)"' 2>/dev/null || true)
            if [[ "${parent,,}" == "${upstream,,}" ]]; then
                echo "  ok ${fork} already exists, syncing all branches from ${upstream}"
                # gh repo sync handles one branch at a time; copy every upstream branch.
                for br in $(gh api "repos/${upstream}/branches" --paginate --jq '.[].name'); do
                    gh repo sync "$fork" --source "$upstream" --branch "$br" >/dev/null 2>&1 \
                        || echo "  warning: could not sync ${fork}@${br} (diverged?)" >&2
                done
            else
                echo "  error: ${fork} exists but is not a fork of ${upstream} (parent: ${parent:-none})." >&2
                echo "         Rename or delete it and run again." >&2
                failed=1
                SEEN[$upstream]=1
                continue
            fi
        else
            echo "==> Forking ${upstream}"
            fork_args=("$upstream" --clone=false)
            [[ -n "$ORG" ]] && fork_args+=(--org "$ORG")
            gh repo fork "${fork_args[@]}"
        fi
        SEEN[$upstream]=1
    fi

    # A new fork needs a few seconds before its commits are served.
    for i in 1 2 3 4 5 6; do
        if gh api "repos/${fork}/commits/${rev}" --silent >/dev/null 2>&1; then
            echo "  ok ${fork} has ${rev:0:7}"
            continue 2
        fi
        sleep $((i * 5))
    done
    echo "  error: ${fork} does not have pinned commit ${rev}" >&2
    failed=1
done

if ((failed)); then
    echo "Some repositories failed; manifests were not changed." >&2
    exit 1
fi

if ((REWRITE)); then
    echo "==> Pointing manifests at github.com/${OWNER}"
    for f in "${MANIFEST_DIR}"/*.xml; do
        for remote in "${!REMOTE_OWNER[@]}"; do
            sed -i -E "s#(<remote name=\"${remote}\" fetch=\")https://github.com/[^\"]+\"#\1https://github.com/${OWNER}\"#" "$f"
        done
        echo "  updated $(basename "$f")"
    done
    echo "Done. Commit the manifest changes:"
    echo "  git add evox/manifests && git commit -m 'evox: Use forked T812 repositories' && git push"
else
    echo "Done (manifests left unchanged)."
fi
