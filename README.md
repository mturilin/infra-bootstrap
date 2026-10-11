# infra-bootstrap

Public, unauthenticated home for the **remote-target seed scripts** used by
[`infra`](https://github.com/mturilin/infra) (private).

These scripts are the irreducible step that runs **on a fresh target** before
a pyinfra controller can take it over via SSH: ensure `sshd`, create a sudo
user (when run as root), install the controller's SSH key, and — on Arch —
set up passwordless `pacman` + build `paru`. They are deliberately
self-contained (no repo clone, no Python on the target) so they can be piped
straight from `curl`, and **non-interactive** (they never prompt — required
inputs come from env vars and the script exits loudly if one is missing).

## Usage

Run on the target. Install the controller's key so pyinfra can connect
non-interactively — `PREP_SSH_KEY_GH` pulls it from `github.com/<user>.keys`,
or `PREP_SSH_KEY` takes a literal key:

```bash
curl -fsSL https://raw.githubusercontent.com/mturilin/infra-bootstrap/v2/prep-remote-arch.sh \
  | PREP_SSH_KEY_GH=mturilin bash
#   ubuntu/suse: swap in prep-remote-ubuntu.sh / prep-remote-suse.sh
#   from a root shell, also create the login user:
#     curl -fsSL .../prep-remote-arch.sh | PREP_USER=<name> PREP_SSH_KEY_GH=mturilin bash
```

Pin to a tag (`v2`, …) rather than a branch for reproducible bootstraps.

### Env vars

| Var | Meaning |
|---|---|
| `PREP_ENABLE_SSHD` | `1` (default) installs + enables sshd; `0` skips it. If skipped on a remote target the controller can't connect — rerun with `1`. |
| `PREP_IS_CONTROLLER` | `0` (default) = remote **target** (installs NOPASSWD). `1` = controller path: skip NOPASSWD. Used by `infra`'s `prep-dev`; leave unset for curl\|bash targets. |
| `PREP_USER` | when run as root, the login user to create (required as root) |
| `PREP_SSH_KEY` | literal public key to authorize for the target user |
| `PREP_SSH_KEY_GH` | GitHub username; authorizes keys from `github.com/<user>.keys` |
| `PREP_SET_PASSWORD` | `1` to also set a unix password (off by default — key auth is enough) |

A new user created as root must have a login method: pass `PREP_SSH_KEY` /
`PREP_SSH_KEY_GH` (or `PREP_SET_PASSWORD=1`), or the script exits.

## Examples

Env vars go **before** `bash` so they reach the piped script. Below, `URL` is
`https://raw.githubusercontent.com/mturilin/infra-bootstrap/v2` — pick the
script for the target's distro (`prep-remote-arch.sh` / `-ubuntu.sh` / `-suse.sh`).

```bash
# Existing login user — just authorize the controller's key (pulled from GitHub):
curl -fsSL "$URL/prep-remote-arch.sh" | PREP_SSH_KEY_GH=mturilin bash

# Existing user — authorize a literal key copied from the controller instead:
curl -fsSL "$URL/prep-remote-arch.sh" | PREP_SSH_KEY="ssh-ed25519 AAAA… you@laptop" bash

# Fresh box from a ROOT shell — create the login user and authorize the key:
curl -fsSL "$URL/prep-remote-arch.sh" | PREP_USER=deploy PREP_SSH_KEY_GH=mturilin bash

# …and also set a unix password for that user (interactive passwd):
curl -fsSL "$URL/prep-remote-arch.sh" | PREP_USER=deploy PREP_SSH_KEY_GH=mturilin PREP_SET_PASSWORD=1 bash

# Ubuntu / openSUSE target — same vars, just the matching script:
curl -fsSL "$URL/prep-remote-ubuntu.sh" | PREP_SSH_KEY_GH=mturilin bash
curl -fsSL "$URL/prep-remote-suse.sh"   | PREP_SSH_KEY_GH=mturilin bash
```

If you skip sshd on a remote target (`PREP_ENABLE_SSHD=0`), the script warns
that the controller can't connect — rerun without it (the default enables sshd).

## Source of truth

These files — scripts **and this README** — are **mirrored from `infra`**
(`prep-remote-*.sh` and `bootstrap/README.md`). Edit them there and let
`infra`'s `publish-seeds` helper sync them. Do not edit here directly;
changes will be overwritten on the next sync.
