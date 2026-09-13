#!/usr/bin/env bash

##
## bootstrap.sh
## Day-0 bootstrap for a blank Mac: everything needed before any of the
## private setup-* repos can even be cloned.
##
## This script is deliberately the whole job. It lives in a public repo on
## purpose, so it can be fetched with a plain HTTPS clone (or curl) before any
## SSH key or GitHub auth exists on the machine.
##
## Usage:
##   ./bootstrap.sh
##   ./bootstrap.sh --dry-run
##   ./bootstrap.sh --skip-clone
##
## What it does, in order:
##   1. Prompts for Xcode Command Line Tools if missing.
##   2. Installs Homebrew if missing, and fixes Cellar ownership on Apple
##      Silicon (a fresh `sudo` install otherwise leaves it root-owned).
##   3. Installs the minimal formula/cask set needed to get any further:
##      stow, asdf, gh, git, gnupg, pinentry-mac, 1password, 1password-cli.
##   4. Walks through enabling 1Password's SSH agent (GUI step, not
##      automatable) and verifies `ssh -T git@github.com` works.
##   5. Falls back to `gh auth login` (browser device flow, HTTPS-only, no
##      SSH key needed) if SSH auth isn't set up yet.
##   6. Clones setup-mac, setup-dotfiles, and setup-neovim to their usual
##      locations, then hands off to setup-dotfiles/install.sh.
##
## Nothing here is machine-specific and nothing here is secret. Nothing
## generates or imports key material — that stays a manual, deliberate step
## inside 1Password.
##

set -uo pipefail

dry_run=0
skip_clone=0

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

Options:
  -n, --dry-run       Report what would happen, change nothing.
      --skip-clone    Do everything except cloning the private repos.
  -h, --help          Show this help.
EOF
}

while (($#)); do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -n | --dry-run)
      dry_run=1
      shift
      ;;
    --skip-clone)
      skip_clone=1
      shift
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

log_step() {
  printf '\n==> %s\n' "$1"
}

status() {
  printf '[info] %s\n' "$1"
}

pass() {
  printf '[pass] %s\n' "$1"
}

warn() {
  printf '[warn] %s\n' "$1" >&2
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

run() {
  if ((dry_run)); then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

## 1. Xcode Command Line Tools ------------------------------------------------

log_step 'Xcode Command Line Tools'

if xcode-select -p >/dev/null 2>&1; then
  pass "Already installed at $(xcode-select -p)."
else
  status 'Not installed. Triggering the GUI installer...'
  if ((dry_run)); then
    printf '[dry-run] xcode-select --install\n'
  else
    xcode-select --install || true
    printf 'Waiting for Xcode Command Line Tools to finish installing.\n'
    printf 'Complete the GUI installer, then press Enter to continue.\n'
    read -r _
    xcode-select -p >/dev/null 2>&1 || die 'Xcode Command Line Tools still not detected.'
  fi
fi

## 2. Homebrew -----------------------------------------------------------------

log_step 'Homebrew'

if command -v brew >/dev/null 2>&1; then
  pass "Already installed at $(command -v brew)."
else
  status 'Not installed. Running the official installer...'
  run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [[ "$(uname -m)" == 'arm64' ]]; then
    status 'Apple Silicon detected: fixing Cellar ownership.'
    run sudo chown -R "$(whoami)" "$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
  fi
fi

if ((dry_run)); then
  brew_bin='brew'
else
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
  command -v brew >/dev/null 2>&1 || die 'brew still not on PATH after install.'
  brew_bin='brew'
fi

## 3. Minimal formula/cask set ---------------------------------------------

log_step 'Minimal formula/cask set'

formulae=(stow asdf gh git gnupg pinentry-mac)
casks=(1password 1password-cli)

for formula in "${formulae[@]}"; do
  if ! ((dry_run)) && "${brew_bin}" list --formula "${formula}" >/dev/null 2>&1; then
    pass "${formula} already installed."
    continue
  fi
  run "${brew_bin}" install "${formula}"
done

for cask in "${casks[@]}"; do
  if ! ((dry_run)) && "${brew_bin}" list --cask "${cask}" >/dev/null 2>&1; then
    pass "${cask} already installed."
    continue
  fi
  run "${brew_bin}" install --cask "${cask}"
done

## 4. 1Password SSH agent + SSH auth check --------------------------------

log_step '1Password SSH agent'

if ((dry_run)); then
  status 'Skipping interactive 1Password/SSH steps in dry-run mode.'
else
  cat <<'EOF'
Open 1Password, sign in, then:
  Settings -> Developer -> "Use the SSH agent" (enabled)
  Settings -> Developer -> "Authorize connections with Touch ID..." (optional)
This writes an IdentityAgent line into ~/.ssh/config for you.

Press Enter once that's done (or Ctrl-C to finish this manually later).
EOF
  read -r _

  status 'Checking SSH access to GitHub...'
  if ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -q 'successfully authenticated'; then
    pass 'SSH auth to GitHub works.'
    auth_mode='ssh'
  else
    warn 'SSH auth to GitHub did not succeed.'
    status 'Falling back to gh auth login (browser device flow, HTTPS only).'
    run gh auth login --hostname github.com --git-protocol https --web
    auth_mode='https'
  fi
fi

## 5. Clone the private repos ------------------------------------------------

log_step 'Clone private repos'

if ((skip_clone)); then
  status 'Skipping clone step (--skip-clone).'
elif ((dry_run)); then
  status 'Skipping clone step in dry-run mode.'
else
  projects_root="${HOME}/Projects/philsherry"
  run mkdir -p "${projects_root}"

  clone_repo() {
    local name="$1"
    local dest="$2"

    if [[ -d "${dest}/.git" ]]; then
      pass "${name} already present at ${dest}."
      return 0
    fi

    local url
    if [[ "${auth_mode:-ssh}" == 'https' ]]; then
      url="https://github.com/philsherry/${name}.git"
    else
      url="git@github.com:philsherry/${name}.git"
    fi

    status "Cloning ${name} into ${dest}..."
    run git clone "${url}" "${dest}"
  }

  clone_repo setup-mac "${HOME}/.setup-mac"
  clone_repo setup-dotfiles "${projects_root}/setup-dotfiles"
  clone_repo setup-neovim "${projects_root}/setup-neovim"
fi

## 6. Hand off -----------------------------------------------------------------

log_step 'Done'

cat <<'EOF'
Day-0 bootstrap complete. From here:

  cd ~/Projects/philsherry/setup-dotfiles
  ./install.sh --dry-run --machine <imac|max|mini|studio|employer-mac>
  ./install.sh --machine <imac|max|mini|studio|employer-mac>

That takes over the rest of the machine setup.
EOF
