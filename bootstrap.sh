#!/usr/bin/env bash
#
# One-line Rockstat installer:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/rockstat/bootstrap-docker/HEAD/bootstrap.sh)"
#
# Installs git if needed, clones this repo (or updates an existing clone)
# and hands over to the interactive installer (install.sh).
#
# Overrides: ROCKSTAT_DIR (default ~/bootstrap-docker), ROCKSTAT_REPO.
#
set -euo pipefail

REPO="${ROCKSTAT_REPO:-https://github.com/rockstat/bootstrap-docker.git}"
DIR="${ROCKSTAT_DIR:-$HOME/bootstrap-docker}"

SUDO=""
[[ $EUID -ne 0 ]] && command -v sudo >/dev/null && SUDO="sudo"

if ! command -v git >/dev/null; then
  echo "==> Installing git"
  if command -v apt-get >/dev/null; then
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq git
  else
    echo "git is required — install it and re-run" >&2
    exit 1
  fi
fi

if [[ -d "$DIR/.git" ]]; then
  echo "==> Updating existing clone in $DIR"
  git -C "$DIR" pull --ff-only
else
  echo "==> Cloning $REPO -> $DIR"
  git clone "$REPO" "$DIR"
fi

cd "$DIR"

# install.sh is interactive; make sure its questions reach the terminal
# even when this script arrives via `curl | bash`
if [[ -t 0 ]]; then
  exec ./install.sh
elif (exec </dev/tty) 2>/dev/null; then
  exec ./install.sh </dev/tty
else
  echo "No terminal available for the interactive installer." >&2
  echo "Run it manually: cd $DIR && ./install.sh" >&2
  exit 1
fi
