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

1. Prompts for Xcode Command Line Tools if missing.
2. Installs Homebrew if missing (fixes Cellar ownership on Apple Silicon).
3. Installs the minimal set needed to get any further:
   `stow asdf gh git gnupg pinentry-mac` plus the `1password` and
   `1password-cli` casks.
4. Walks through enabling 1Password's SSH agent (a GUI step — this script
   can't do it for you) and checks `ssh -T git@github.com`.
5. Falls back to `gh auth login` (browser device flow, HTTPS, no SSH key
   needed) if SSH auth isn't set up yet.
6. Clones `setup-mac`, `setup-dotfiles`, and `setup-neovim` to their usual
   locations and hands off to `setup-dotfiles/install.sh`.

Run with `--dry-run` to see what it would do without changing anything, or
`--skip-clone` to stop before the private-repo clone step.

## What it deliberately doesn't do

- Generate or import any SSH/GPG key material. Key setup stays a manual,
  deliberate step inside 1Password.
- Contain anything machine-specific or secret. It's safe to be public because
  there's nothing here but package names and clone URLs.
- Replace `setup-dotfiles/install.sh`. Once the private repos are cloned,
  that's back to being the real entrypoint.
