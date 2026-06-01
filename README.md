# infra-bootstrap

Public, unauthenticated home for the **remote-target seed scripts** used by
[`infra`](https://github.com/mturilin/infra) (private).

These scripts are the irreducible step that runs **on a fresh target** before
a pyinfra controller can take it over via SSH: ensure `sshd`, create a sudo
user (when run as root), install the controller's SSH key, and — on Arch —
set up passwordless `pacman` + build `paru`. They are deliberately
self-contained (no repo clone, no Python on the target) so they can be piped
straight from `curl`.

## Usage

Run on the target. Install the controller's key so pyinfra can connect
non-interactively — `PREP_SSH_KEY_GH` pulls it from `github.com/<user>.keys`,
or `PREP_SSH_KEY` takes a literal key:

```bash
curl -fsSL https://raw.githubusercontent.com/mturilin/infra-bootstrap/v1/prep-remote-arch.sh \
  | PREP_SSH_KEY_GH=mturilin bash
#   ubuntu/suse: swap in prep-remote-ubuntu.sh / prep-remote-suse.sh
#   from a root shell, also create the login user:
#     curl -fsSL .../prep-remote-arch.sh | PREP_USER=<name> PREP_SSH_KEY_GH=mturilin bash
```

Pin to a tag (`v1`, …) rather than a branch for reproducible bootstraps.

### Env vars

| Var | Meaning |
|---|---|
| `PREP_ENABLE_SSHD` | `1` (default) installs + enables sshd; `0` skips it (used by `infra`'s dev-prep) |
| `PREP_USER` | when run as root, the login user to create |
| `PREP_SSH_KEY` | literal public key to authorize for the target user |
| `PREP_SSH_KEY_GH` | GitHub username; authorizes keys from `github.com/<user>.keys` |

## Source of truth

These files are **mirrored from `infra`** — edit them there
(`prep-remote-*.sh`) and run `infra`'s `publish-seeds` helper to sync. Do not
edit here directly; changes will be overwritten on the next sync.
