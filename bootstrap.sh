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
##   1. Makes sure the Xcode Command Line Tools work, by compiling and linking
##      a test program rather than trusting that a directory exists.
##   2. Installs Homebrew if missing, and fixes Cellar ownership on Apple
##      Silicon (a fresh `sudo` install otherwise leaves it root-owned).
##   3. Installs the minimal formula/cask set needed to get any further:
##      stow, asdf, gh, git, gnupg, pinentry-mac, bash, bun, neovim, ripgrep,
##      fd, fzf, 1password, 1password-cli, kitty, visual-studio-code.
##   4. Walks through enabling 1Password's SSH agent (GUI step, not
##      automatable) and verifies `ssh -T git@github.com` works.
##   5. Falls back to `gh auth login` (browser device flow, HTTPS-only, no
##      SSH key needed) if SSH auth isn't set up yet.
##   6. Clones setup-mac, setup-dotfiles, and setup-neovim to their usual
##      locations, then hands off to the setup-mac orchestrator
##      (bin/install-setup.sh), which runs the dotfiles switch, Homebrew
##      bundle, asdf and Neovim in the right order.
##
## Nothing here is machine-specific and nothing here is secret. Nothing
## generates or imports key material — that stays a manual, deliberate step
## inside 1Password.
##

set -uo pipefail

## Every setup-* repo lives in one root, PHILSHERRY, and nothing goes in $HOME.
## Set it here, before anything else: on day 0 there are no dotfiles to export it.
## An explicit value wins, so a machine can keep its repos elsewhere.
export PHILSHERRY="${PHILSHERRY:-${HOME}/Projects/philsherry}"

dry_run=0
skip_clone=0
check_toolchain_only=0

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

Options:
  -n, --dry-run          Report what would happen, change nothing.
      --skip-clone       Do everything except cloning the private repos.
      --check-toolchain  Only check that a C program compiles and links, then exit.
  -h, --help             Show this help.
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
    --check-toolchain)
      check_toolchain_only=1
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

## Prove the C toolchain works by compiling and linking a one-line program.
##
## `xcode-select -p` only proves a directory exists, and `xcrun --find clang` /
## `xcrun --show-sdk-path` exit 0 even when SDKROOT points at a path that does
## not exist (xcrun echoes it back), so none of them say whether builds will
## work. This is a deliberate copy of setup-mac/bin/lib/toolchain.sh: this repo
## runs before setup-mac can be cloned. Keep the two in step.
##
## TOOLCHAIN_CC overrides the compiler so tests can stand in for it.
toolchain_check() {
  local cc="${TOOLCHAIN_CC:-/usr/bin/clang}"
  local work_dir=''
  local built=0
  local compile_output=''

  work_dir="$(mktemp -d)" || return 1
  printf 'int main(void) { return 0; }\n' >"${work_dir}/probe.c"

  # `|| built=$?`, not a bare assignment: this file runs without errexit, but the copy
  # in setup-mac runs under callers' `set -e`, where a failing command substitution
  # ends the function before it can say why. Keep the two the same.
  compile_output="$("${cc}" "${work_dir}/probe.c" -o "${work_dir}/probe" 2>&1)" || built=$?

  rm -rf "${work_dir}"

  ((built == 0)) && return 0

  # An unaccepted Xcode licence beats every other cause: the Command Line Tools
  # are fine, so reinstalling them (or fixing SDKROOT) cannot help.
  if [[ ${compile_output} == *"agreed to the Xcode license"* ]]; then
    printf 'The Xcode licence has not been accepted, so clang refuses to run.\n' >&2
    printf 'Accept it with: sudo xcodebuild -license accept   (or open Xcode.app once and agree), then re-run.\n' >&2
  elif [[ -n ${SDKROOT:-} && ! -d ${SDKROOT} ]]; then
    printf 'SDKROOT points at %s, which does not exist, so C programs cannot be linked.\n' "${SDKROOT}" >&2
    printf 'Unset SDKROOT, or install what it points at. It is usually exported by a shell startup file.\n' >&2
  else
    printf 'Cannot compile and link a C program. Install the Xcode Command Line Tools (xcode-select --install) and re-run.\n' >&2
  fi

  return 1
}

if ((check_toolchain_only)); then
  toolchain_check
  exit $?
fi

## 1. Xcode Command Line Tools ------------------------------------------------

log_step 'Xcode Command Line Tools'

toolchain_report="$(toolchain_check 2>&1)" && toolchain_ok=1 || toolchain_ok=0

if ((toolchain_ok)); then
  pass 'The C toolchain compiles and links.'
elif [[ ${toolchain_report} == *'Xcode licence has not been accepted'* ]]; then
  ## The tools are installed and fine; only the licence stands in the way.
  printf '%s\n' "${toolchain_report}" >&2
  ((dry_run)) || die 'Accept the Xcode licence first; installing the Command Line Tools will not help.'
elif [[ -n ${SDKROOT:-} && ! -d ${SDKROOT} ]]; then
  ## Reinstalling the tools cannot fix a bad variable, so say so instead of
  ## sending the user round the installer again.
  toolchain_check || true
  ((dry_run)) || die 'Fix SDKROOT first; installing the Command Line Tools will not help.'
elif ((dry_run)); then
  status 'The C toolchain does not work yet.'
  printf '[dry-run] xcode-select --install\n'
else
  status 'The C toolchain does not work yet. Triggering the GUI installer...'
  attempts=0
  until toolchain_check 2>/dev/null; do
    attempts=$((attempts + 1))
    if ((attempts > 3)); then
      toolchain_check || true
      die 'Still cannot build a C program. If the tools are damaged, remove and reinstall them: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install'
    fi
    xcode-select --install 2>/dev/null || true
    printf 'Complete the GUI installer, then press Enter to check again.\n'
    read -r _
  done
  pass 'The C toolchain compiles and links.'
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

## `bash` is required here, not just in the host Brewfiles: setup-dotfiles'
## bootstrap scripts use bash 4+ features (associative arrays, mapfile) and
## are invoked via a bare `bash`, which resolves to macOS's ancient system
## bash (3.2) until Homebrew's bash is installed and first on PATH. Nothing
## in install.sh runs `brew bundle install` automatically, so this has to be
## the thing that gets it here before setup-dotfiles ever runs.
##
## `bun` is here because Claude Code plugin hooks (claude-mem) run it from a
## non-interactive shell, where asdf's shims may not be on PATH. Homebrew's
## /opt/homebrew/bin always is. asdf still pins the version for projects.
##
## `neovim ripgrep fd fzf` are the Neovim requirements that Homebrew owns.
## `node`, `lua` and `luarocks` are deliberately absent: asdf owns language
## runtimes (setup-dotfiles README, "Who installs what"), and Neovim's preflight
## expects the asdf-managed Lua and its LuaRocks. The orchestrator installs them
## before that preflight; a Homebrew copy would only be shadowed.
##
## `kitty` and `visual-studio-code` are the terminal and editor, wanted from the
## first login. Build dependencies for asdf plugins (autoconf, icu4c, ...) are not
## listed here: setup-mac's asdf-install.sh owns them per plugin.
formulae=(stow asdf gh git gnupg pinentry-mac bash bun neovim ripgrep fd fzf)
casks=(1password 1password-cli kitty visual-studio-code)

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
else
  ## A dry run still walks this step: `run` prints each clone instead of doing it,
  ## which shows where every repo would land.
  projects_root="${PHILSHERRY}"
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

  clone_repo setup-mac "${projects_root}/setup-mac"
  clone_repo setup-dotfiles "${projects_root}/setup-dotfiles"
  clone_repo setup-neovim "${projects_root}/setup-neovim"
fi

## 6. Hand off -----------------------------------------------------------------

log_step 'Done'

## The repos were cloned over https when the gh fallback was used, and the
## orchestrator needs to know, or it would try ssh for updates.
https_flag=''
[[ "${auth_mode:-ssh}" == 'https' ]] && https_flag=' --https'

cat <<EOF
Day-0 bootstrap complete. Now run the setup-mac orchestrator, once:

  bash ${PHILSHERRY}/setup-mac/bin/install-setup.sh --machine-profile <studio|max|mini|employer-mac>${https_flag}

A new Mac isn't renamed to its registered name yet, so say which machine this is;
the personal or employer flavour follows from it.

Early on, right after the dotfiles are in place, it will set this Mac's registered name.
It will ask for your password to do that, once.

That runs the dotfiles switch (stow), Homebrew bundle, asdf and Neovim in the right
order. Don't also run setup-dotfiles/install.sh: both run the same stow step, and
running both is what causes symlink conflicts.
EOF
