#!/usr/bin/env bash
# bootstrap.sh — one-shot init for a fresh clone of nexus_prototype on a new machine.
#
# What it does (idempotent):
#   1. Configure a local (repo-scoped) git url.insteadOf rule so that any
#      github.com/https URL used by nested submodules is transparently
#      rewritten to go through gh-proxy.org. This is required because the
#      upstream Coyote repo carries its own submodules (e.g.
#      hw/services/network -> fpga-network-stack) that reference github.com
#      directly. Without the rewrite those clones fail on machines behind
#      the GFW.
#   2. Initialize and update all submodules recursively.
#   3. Print a short summary so the user can see which upstream commit is
#      locked in.
#
# Assumptions:
#   - You have already cloned this repo (e.g. via SSH), which is why
#     bootstrap.sh even exists on disk.
#   - `git` is available.
#   - Outbound HTTPS to gh-proxy.org works. If your network can reach
#     github.com directly, set NEXUS_USE_GH_PROXY=0 to skip the rewrite.
#
# Usage:
#   ./scripts/bootstrap.sh              # default: use gh-proxy
#   NEXUS_USE_GH_PROXY=0 ./scripts/bootstrap.sh   # direct github.com

set -euo pipefail

# ---- resolve repo root (script may be called from anywhere) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# sanity: we must be inside a git worktree, and it must be *this* repo
if [[ ! -d "${REPO_ROOT}/.git" && ! -f "${REPO_ROOT}/.git" ]]; then
    echo "error: ${REPO_ROOT} is not a git worktree" >&2
    exit 1
fi

USE_PROXY="${NEXUS_USE_GH_PROXY:-1}"
PROXY_PREFIX="https://gh-proxy.org/"

echo "==> nexus_prototype bootstrap"
echo "    repo root : ${REPO_ROOT}"
echo "    use proxy :${USE_PROXY}  (set NEXUS_USE_GH_PROXY=0 to disable)"
echo

# ---- step 1: configure repo-local insteadOf ---------------------------------
# Scope the config to *this* repo (--local), so we do not pollute the user's
# global git config or affect unrelated repos on the same machine.
INSTEADOF_KEY="url.${PROXY_PREFIX}https://github.com/.insteadOf"
if [[ "${USE_PROXY}" == "1" ]]; then
    echo "==> configuring repo-local url.insteadOf -> gh-proxy"
    # Reset first so re-runs don't accumulate duplicate values.
    git config --local --unset-all "${INSTEADOF_KEY}" 2>/dev/null || true
    # For https://github.com/... -> https://gh-proxy.org/https://github.com/...
    git config --local --add "${INSTEADOF_KEY}" "https://github.com/"
    # Also rewrite git://github.com/... (rare, but some old submodules use it).
    # --add appends without clobbering the https rule above; git supports
    # multiple insteadOf values per url.<base>.
    git config --local --add "${INSTEADOF_KEY}" "git://github.com/"
    echo "    done. current rewrites:"
    git config --local --get-all "${INSTEADOF_KEY}" | sed 's/^//'
else
    echo "==> skipping insteadOf rewrite (NEXUS_USE_GH_PROXY=0)"
    # If a previous run installed the rule, drop it so github.com is used directly.
    git config --local --unset-all "${INSTEADOF_KEY}" 2>/dev/null || true
fi
echo

# ---- step 2: submodule init + update ---------------------------------------
# We use --recursive so that Coyote's own submodules (e.g. hw/services/network)
# are also fetched. Thanks to the insteadOf rule above, those inner clones
# will transparently go through gh-proxy too.
echo "==> git submodule sync --recursive"
git submodule sync --recursive
echo
echo "==> git submodule update --init --recursive"
# --jobs 4 speeds up parallel fetch; harmless if some networks throttle.
git submodule update --init --recursive --jobs 4
echo

# ---- step 3: summary --------------------------------------------------------
echo "==> submodule summary"
git submodule status --recursive
echo
echo "==> upstream/Coyote HEAD"
( cd upstream/Coyote && git log --oneline -1 )
echo
echo "bootstrapok. next: cd coyote-u250-deployment && read README.md"
