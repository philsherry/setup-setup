#!/usr/bin/env bash

## test-bootstrap.sh
## Guard bootstrap.sh. Runs anywhere: it uses --dry-run and a stand-in compiler,
## so nothing is installed and no host toolchain is trusted.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bootstrap="${script_dir}/bootstrap.sh"
failures=0
tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

## Isolate from the caller's environment: a shell with a dangling SDKROOT (the
## very thing the check diagnoses) would change which message a failure prints.
unset SDKROOT

pass() {
  printf '[pass] %s\n' "$1"
}

fail() {
  printf '[fail] %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_equals() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [[ "${actual}" == "${expected}" ]]; then
    pass "${label}"
  else
    fail "${label}: expected ${expected:-<empty>}, got ${actual:-<empty>}"
  fi
}

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"

  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass "${label}"
  else
    fail "${label}: output does not contain: ${needle}"
  fi
}

assert_not_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass "${label}"
  else
    fail "${label}: output unexpectedly contains: ${needle}"
  fi
}

make_cc() {
  local name="$1"
  local code="$2"

  printf '#!/bin/sh\nexit %s\n' "${code}" >"${tmp_root}/${name}"
  chmod +x "${tmp_root}/${name}"
  printf '%s\n' "${tmp_root}/${name}"
}

good_cc="$(make_cc good-cc 0)"
bad_cc="$(make_cc bad-cc 1)"

## --- The toolchain is proven by compiling, not by asking xcode-select -----------
## A directory at `xcode-select -p` does not mean the tools work.

TOOLCHAIN_CC="${good_cc}" bash "${bootstrap}" --check-toolchain >/dev/null 2>&1
assert_equals 'toolchain check passes when a program compiles and links' '0' "$?"

output="$(TOOLCHAIN_CC="${bad_cc}" bash "${bootstrap}" --check-toolchain 2>&1)"
status=$?
assert_equals 'toolchain check fails when a program cannot be built' '1' "${status}"
assert_contains 'toolchain failure points at the Command Line Tools' "${output}" 'Command Line Tools'

output="$(SDKROOT=/no/such/Xcode.app/sdk TOOLCHAIN_CC="${bad_cc}" bash "${bootstrap}" --check-toolchain 2>&1)"
assert_contains 'toolchain failure names a dangling SDKROOT' "${output}" 'SDKROOT'

## An unaccepted Xcode licence (Xcode.app installed, licence not agreed) makes clang
## refuse to run. The tools are fine, so the answer is to accept the licence, not
## to reinstall them or to open the GUI installer again.
unlicensed_cc="${tmp_root}/unlicensed-cc"
printf '#!/bin/sh\necho "You have not agreed to the Xcode license agreements." >&2\nexit 69\n' >"${unlicensed_cc}"
chmod +x "${unlicensed_cc}"

output="$(TOOLCHAIN_CC="${unlicensed_cc}" bash "${bootstrap}" --check-toolchain 2>&1)"
assert_contains 'an unaccepted licence is named, with how to accept it' "${output}" 'sudo xcodebuild -license accept'
assert_not_contains 'an unaccepted licence does not send you to the installer' "${output}" 'xcode-select --install'

output="$(TOOLCHAIN_CC="${unlicensed_cc}" bash "${bootstrap}" --dry-run --skip-clone 2>&1)"
assert_contains 'the run tells you to accept the licence' "${output}" 'sudo xcodebuild -license accept'
assert_not_contains 'the run does not offer the GUI installer for a licence problem' "${output}" '[dry-run] xcode-select --install'

## --- What a dry run says it will install ----------------------------------------

dry_run="$(TOOLCHAIN_CC="${good_cc}" bash "${bootstrap}" --dry-run --skip-clone 2>&1)"

for item in neovim ripgrep fd fzf bun; do
  assert_contains "installs ${item}" "${dry_run}" "install ${item}"
done

for cask in kitty visual-studio-code 1password 1password-cli; do
  assert_contains "installs cask ${cask}" "${dry_run}" "install --cask ${cask}"
done

## node, lua and luarocks belong to asdf (README ownership rule); the orchestrator
## installs them before Neovim's preflight, and a Homebrew copy would be shadowed.
for runtime in node lua luarocks; do
  assert_not_contains "does not install ${runtime} from Homebrew" "${dry_run}" "brew install ${runtime}"
done

## --- The hand-off goes to the orchestrator, and names the machine ---------------
## The orchestrator identifies a Mac by its LocalHostName, which a new Mac does not
## have yet, so the machine must be named explicitly.

assert_contains 'hands off to the setup-mac orchestrator' "${dry_run}" 'setup-mac/bin/install-setup.sh'
assert_contains 'hand-off names the machine' "${dry_run}" '--machine-profile'
assert_not_contains 'does not send the user to setup-dotfiles/install.sh' "${dry_run}" 'cd ~/Projects/philsherry/setup-dotfiles'

## --- Every setup-* repo is cloned into $PHILSHERRY, and nothing into $HOME ---------
## PHILSHERRY is the one root (default ~/Projects/philsherry); setup-mac is no
## longer a hidden folder in the home directory. The dry run prints the clones.

projects_root="${tmp_root}/projects"
clone_run="$(PHILSHERRY="${projects_root}" TOOLCHAIN_CC="${good_cc}" bash "${bootstrap}" --dry-run 2>&1)"

for repo in setup-mac setup-dotfiles setup-neovim; do
  assert_contains "clones ${repo} into the projects root" "${clone_run}" "${repo}.git ${projects_root}/${repo}"
done

assert_not_contains 'does not clone anything into a hidden folder in $HOME' "${clone_run}" '/.setup-mac'
assert_contains 'the hand-off runs the orchestrator from the projects root' "${clone_run}" "${projects_root}/setup-mac/bin/install-setup.sh"

## The orchestrator renames the Mac to its registered name and needs sudo for it,
## so the user should hear about the password prompt before it appears.
assert_contains 'says the orchestrator sets the machine name' "${dry_run}" 'set this Mac'
assert_contains 'warns that it will ask for your password' "${dry_run}" 'ask for your password'

if ((failures > 0)); then
  printf '\n%s check(s) failed.\n' "${failures}" >&2
  exit 1
fi

printf '\nAll bootstrap checks passed.\n'
