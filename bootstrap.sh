#!/usr/bin/env bash
# astroneer bootstrap — fetch astroneer, install runtime deps, put it on PATH.
#
# Public one-liner (this file is mirrored to the public astroneer-bootstrap repo):
#   curl -fsSL https://raw.githubusercontent.com/ASTRON-AI/astroneer-bootstrap/main/bootstrap.sh | bash
#
# ASTRON-AI/astroneer itself is a PRIVATE repo, so the raw curl|bash of THIS repo
# won't resolve without auth. Use the public one-liner above, or clone directly:
#
#   gh repo clone ASTRON-AI/astroneer ~/.local/share/astroneer \
#     && ASTRONEER_SKIP_FETCH=1 bash ~/.local/share/astroneer/bootstrap.sh
#
# Non-interactive by design (no menu here). The interactive menu lives in
# `astroneer install`, which has a real tty. Runs under bash regardless of your
# login shell; the shell wiring in `astroneer install` targets your login shell.
set -euo pipefail

# Did the caller point us at a custom (reachable) source? If so, we may still
# fall back to a plain tarball fetch when gh/git are absent. Otherwise the
# default repo is private and an unauthenticated download can't work — so we
# fail fast instead of attempting a doomed fetch (see the no-gh/git branch).
_an_src_overridden=0
if [ -n "${ASTRONEER_SLUG:-}" ] || [ -n "${ASTRONEER_TARBALL:-}" ]; then
  _an_src_overridden=1
fi

ASTRONEER_SLUG="${ASTRONEER_SLUG:-ASTRON-AI/astroneer}"
ASTRONEER_REPO="${ASTRONEER_REPO:-https://github.com/${ASTRONEER_SLUG}.git}"
ASTRONEER_TARBALL="${ASTRONEER_TARBALL:-https://github.com/${ASTRONEER_SLUG}/archive/refs/heads/main.tar.gz}"
ASTRONEER_HOME="${ASTRONEER_HOME:-$HOME/.local/share/astroneer}"
BIN_DIR="${HOME}/.local/bin"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[ERR ]\033[0m %s\n' "$*" >&2; exit 1; }

# --- system prerequisites: curl/git/gh must be present AND >= a version floor --
# astroneer no longer installs gh; curl/git/gh are treated as system tools that
# you provide via apt. We only CHECK here (no sudo, no apt run) and, if a tool is
# missing or too old, die with the apt install/upgrade command so you can fix it
# and re-run. Floors are pinned (a floor = "install/upgrade until at least this");
# version math is inlined from lib/version.sh because lib/ is fetched later.
CURL_MIN=8.18.0
GIT_MIN=2.53.0
GH_MIN=2.96.0
CURL_HINT='  sudo apt update && sudo apt install curl'
GIT_HINT='  sudo add-apt-repository ppa:git-core/ppa && sudo apt update && sudo apt install git'
GH_HINT='  # gh is not in the default Ubuntu repos. Add the GitHub apt source, then:
  #   sudo apt update && sudo apt install gh
  # setup steps: https://github.com/cli/cli/blob/trunk/docs/install_linux.md'

_an_ver() { printf '%s' "${1:-}" | grep -oE '[0-9]+(\.[0-9]+){0,3}' | head -n1; }
_an_ge()  {
  [ "$1" = "$2" ] && return 0
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}
# _an_require <label> <bin> <floor> <apt-hint>: die unless installed and >= floor.
_an_require() {
  local label="$1" bin="$2" floor="$3" hint="$4" ver
  if ! command -v "$bin" >/dev/null 2>&1; then
    die "${label} is not installed (astroneer needs >= ${floor}). Install it, then re-run:
${hint}"
  fi
  ver="$(_an_ver "$("$bin" --version 2>&1)")"
  if [ -z "$ver" ] || ! _an_ge "$ver" "$floor"; then
    die "${label} ${ver:-(unknown version)} is too old (need >= ${floor}). Upgrade it, then re-run:
${hint}"
  fi
}

# --- 1. preflight (inline; lib/ is not available until after the fetch) --------
[ "$(uname -s)" = "Linux" ] || die "astroneer supports Linux (WSL/Ubuntu); found $(uname -s)"
# curl is always required — it fetches astroneer's runtime deps (gum, jq) too,
# so this gate runs regardless of how the astroneer tree itself is obtained.
_an_require "curl" curl "$CURL_MIN" "$CURL_HINT"
mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR (check home permissions)"

is_wsl=0
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then is_wsl=1; fi
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
fi
case " ${ID:-} ${ID_LIKE:-} " in
  *" ubuntu "*|*" debian "*) : ;;
  *) [ "$is_wsl" = 1 ] || warn "not Ubuntu/Debian-family; proceeding best-effort" ;;
esac

# git + gh are required to clone the private astroneer repo (and later for
# `astroneer update`). Enforce them on the normal fetch path only: skip when the
# tree is already present (ASTRONEER_SKIP_FETCH) or a custom reachable source is
# set (those paths fetch via curl/tarball and don't need git/gh — this mirrors
# the fetch ladder below and preserves the documented manual-clone recovery).
if [ "${ASTRONEER_SKIP_FETCH:-0}" != "1" ] && [ "$_an_src_overridden" = 0 ]; then
  _an_require "git" git "$GIT_MIN" "$GIT_HINT"
  _an_require "gh" gh "$GH_MIN" "$GH_HINT"
fi

# --- 2. fetch the astroneer tree ----------------------------------------------
if [ "${ASTRONEER_SKIP_FETCH:-0}" = "1" ] && [ -x "${ASTRONEER_HOME}/bin/astroneer" ]; then
  say "Using existing astroneer tree at $ASTRONEER_HOME (skip-fetch)"
elif [ -d "${ASTRONEER_HOME}/.git" ]; then
  say "Updating astroneer in $ASTRONEER_HOME"
  # Update the same way we clone — via gh (native auth), not a hand-built git
  # extraheader token: GitHub's git-over-HTTPS transport rejects the bearer-token
  # scheme ("invalid credentials"). Fast-forward first; hard-reset (--force) on a
  # non-fast-forward, since the tree is astroneer-managed and matching origin/main
  # is the intended recovery. Plain pull only when gh is unauthenticated.
  if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    ( cd "$ASTRONEER_HOME" && { gh repo sync -b main || gh repo sync -b main --force; } ) \
      || warn "gh repo sync failed; using existing tree"
  else
    GIT_TERMINAL_PROMPT=0 git -C "$ASTRONEER_HOME" pull --ff-only \
      || warn "git pull failed — run 'gh auth login', then re-run; using existing tree"
  fi
elif [ -e "$ASTRONEER_HOME" ]; then
  die "$ASTRONEER_HOME exists but is not an astroneer git checkout; move it aside and re-run"
elif command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
  say "Cloning astroneer (private) via gh into $ASTRONEER_HOME"
  gh repo clone "$ASTRONEER_SLUG" "$ASTRONEER_HOME" -- --depth 1
elif command -v git >/dev/null 2>&1; then
  say "Cloning astroneer into $ASTRONEER_HOME"
  git clone --depth 1 "$ASTRONEER_REPO" "$ASTRONEER_HOME" \
    || die "git clone failed (private repo needs gh auth: run 'gh auth login', or use the gh clone command in the README)"
else
  # No authenticated gh and no git. The default repo is private, so an
  # unauthenticated tarball fetch always 404s — fail fast with actionable
  # guidance instead of a doomed download. Only a caller-overridden (reachable)
  # source still falls through to the tarball path below.
  if [ "$_an_src_overridden" = 0 ]; then
    die "can't fetch ${ASTRONEER_SLUG}: no authenticated gh and no git, and the repo is private.
Fix it one of these ways, then re-run the one-liner:
  - gh auth login            (install the GitHub CLI first if needed)
  - or clone it yourself (see README):
      gh repo clone ${ASTRONEER_SLUG} ${ASTRONEER_HOME} \\
        && ASTRONEER_SKIP_FETCH=1 bash ${ASTRONEER_HOME}/bootstrap.sh"
  fi
  say "git/gh not found — fetching tarball from custom source into $ASTRONEER_HOME"
  tmp="$(mktemp -d)"
  curl -fsSL "$ASTRONEER_TARBALL" -o "${tmp}/astroneer.tar.gz" \
    || die "tarball fetch failed from ${ASTRONEER_TARBALL}"
  tar -xzf "${tmp}/astroneer.tar.gz" -C "$tmp"
  src="$(find "$tmp" -maxdepth 1 -type d -name 'astroneer-*' | head -n1)"
  [ -n "$src" ] || die "unexpected tarball layout"
  mkdir -p "$ASTRONEER_HOME"
  cp -a "${src}/." "${ASTRONEER_HOME}/"
  rm -rf "$tmp"
fi

[ -x "${ASTRONEER_HOME}/bin/astroneer" ] || chmod +x "${ASTRONEER_HOME}/bin/astroneer" 2>/dev/null || true

# --- 3. install astroneer's runtime deps (gum, jq), user-scope ----------------
export ASTRONEER_ROOT="$ASTRONEER_HOME"
# shellcheck source=/dev/null
. "${ASTRONEER_HOME}/manifest.sh"
for f in ui version fetch provision deps; do
  # shellcheck source=/dev/null
  . "${ASTRONEER_HOME}/lib/${f}.sh"
done
an_install_runtime_deps || warn "runtime dependency install reported problems (see above)"

# --- 4. put astroneer on PATH -------------------------------------------------
ln -sfn "${ASTRONEER_HOME}/bin/astroneer" "${BIN_DIR}/astroneer"
say "Linked ${BIN_DIR}/astroneer -> ${ASTRONEER_HOME}/bin/astroneer"

# --- 5. next step -------------------------------------------------------------
cat <<EOF

astroneer bootstrapped into ${ASTRONEER_HOME}.

Next — provision the astron dev environment (wires PATH + cc/ccpo48x/astro and
installs Claude Code, Node, then offers optional tools):

  ${BIN_DIR}/astroneer install

After that, open a new shell (or: exec "\$SHELL") and try:  astro doctor
EOF
