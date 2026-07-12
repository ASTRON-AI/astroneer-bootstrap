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

# --- 1. preflight (inline; lib/ is not available until after the fetch) --------
[ "$(uname -s)" = "Linux" ] || die "astroneer supports Linux (WSL/Ubuntu); found $(uname -s)"
command -v curl >/dev/null 2>&1 || die "curl is required to bootstrap astroneer"
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

# --- 2. fetch the astroneer tree ----------------------------------------------
if [ "${ASTRONEER_SKIP_FETCH:-0}" = "1" ] && [ -x "${ASTRONEER_HOME}/bin/astroneer" ]; then
  say "Using existing astroneer tree at $ASTRONEER_HOME (skip-fetch)"
elif [ -d "${ASTRONEER_HOME}/.git" ]; then
  say "Updating astroneer in $ASTRONEER_HOME"
  if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    git -C "$ASTRONEER_HOME" -c "http.https://github.com/.extraheader=AUTHORIZATION: bearer $(gh auth token)" pull --ff-only \
      || warn "git pull failed; using existing tree"
  else
    git -C "$ASTRONEER_HOME" pull --ff-only || warn "git pull failed; using existing tree"
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
installs Claude Code, Node, gh, then offers optional tools):

  ${BIN_DIR}/astroneer install

After that, open a new shell (or: exec "\$SHELL") and try:  astro doctor
EOF
