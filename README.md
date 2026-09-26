# setup-setup

Day-0 bootstrap for a blank Mac.

Everything else I own for setting up a machine — [setup-mac](https://github.com/philsherry/setup-mac),
[setup-dotfiles](https://github.com/philsherry/setup-dotfiles), [setup-neovim](https://github.com/philsherry/setup-neovim) —
is a private repo, which means none of it can be cloned until SSH (or `gh`)
auth exists on the new machine. This repo is public on purpose, so it can be
fetched with a plain HTTPS clone before any of that exists, and it does just
enough to get from "blank Mac" to "can clone the real repos."

## What it does

```sh
git clone https://github.com/philsherry/setup-setup.git
cd setup-setup
./bootstrap.sh
```

1. Makes sure the Xcode Command Line Tools work. It proves that by compiling and
   linking a test program, because a directory at `xcode-select -p` doesn't mean
   the tools are usable. If it can't build, it says why (including a stale
   `SDKROOT`) and prompts for the installer.
2. Installs Homebrew if missing (fixes Cellar ownership on Apple Silicon).
3. Installs the minimal set needed to get any further:
   `stow asdf gh git gnupg pinentry-mac bash bun neovim ripgrep fd fzf`, plus the
   `1password`, `1password-cli`, `kitty` and `visual-studio-code` casks. `node`,
   `lua` and `luarocks` are left to asdf, which owns language runtimes.
4. Walks through enabling 1Password's SSH agent (a GUI step — this script
   can't do it for you) and checks `ssh -T git@github.com`.
5. Falls back to `gh auth login` (browser device flow, HTTPS, no SSH key
   needed) if SSH auth isn't set up yet.
6. Clones `setup-mac`, `setup-dotfiles`, and `setup-neovim` into `$PHILSHERRY`
   (default `~/Projects/philsherry`) and hands off to the `setup-mac` orchestrator:

   ```sh
   bash "$PHILSHERRY"/setup-mac/bin/install-setup.sh --machine-profile <studio|max|mini|employer-mac>
   ```

   Say which machine this is: a new Mac isn't renamed to its registered name
   yet, so it can't be detected. Run that once. It does the dotfiles switch
   (stow), Homebrew bundle, asdf and Neovim in the right order.

Run with `--dry-run` to see what it would do without changing anything,
`--skip-clone` to stop before the private-repo clone step, or `--check-toolchain`
to only check that a C program compiles and links.

`npm test` runs the checks in `test-bootstrap.sh`.

## What it deliberately doesn't do

- Generate or import any SSH/GPG key material. Key setup stays a manual,
  deliberate step inside 1Password.
- Contain anything machine-specific or secret. It's safe to be public because
  there's nothing here but package names and clone URLs.
- Replace the orchestrator. Once the private repos are cloned,
  `$PHILSHERRY/setup-mac/bin/install-setup.sh` is the real entrypoint. Don't also run
  `setup-dotfiles/install.sh` during a setup: both run the same stow step, and
  running both causes symlink conflicts. It stays for recovery and re-stowing.
