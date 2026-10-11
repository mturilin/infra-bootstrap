#!/usr/bin/env bash
# What: Seed a fresh Arch target so a pyinfra controller can take it over via SSH.
# Why: pyinfra can't connect until sshd + a sudo user (with the controller's key) exist,
#      and its pacman/AUR ops need passwordless pacman + paru on the target. This is the
#      irreducible pre-pyinfra step that must run on the target itself.
# Design: Standalone (curl|bash-able) — does NOT source lib/, so it works with no repo
#         clone. Non-interactive by design: it NEVER prompts (curl|bash has no usable
#         stdin anyway) — required inputs come from env vars and it exits loudly if one
#         is missing. Idempotent. Uses $SUDO so it runs both as root (bare image) and as
#         a normal sudo user; installs the `sudo` package itself. paru is built as the
#         non-root target user (makepkg refuses root). Narrates each step via say().
#         Shared by prep-dev-arch.sh (PREP_IS_CONTROLLER=1; PREP_ENABLE_SSHD=0 by
#         default, or 1 for a remote controller).
# Gotchas: sshd enable is opt-out via PREP_ENABLE_SSHD=0 so a dev laptop isn't turned
#          into an SSH server. Run as root to create a user (PREP_USER=<name>). Authorize
#          the controller with PREP_SSH_KEY='ssh-ed25519 …' and/or PREP_SSH_KEY_GH=<gh-user>
#          (fetches github.com/<user>.keys). Key auth is the default login method;
#          PREP_SET_PASSWORD=1 also sets a unix password (off by default). The target
#          user gets passwordless sudo (NOPASSWD: ALL) so pyinfra runs unattended.
set -euo pipefail

PREP_ENABLE_SSHD="${PREP_ENABLE_SSHD:-1}"
PREP_USER="${PREP_USER:-}"
PREP_SSH_KEY="${PREP_SSH_KEY:-}"
PREP_SSH_KEY_GH="${PREP_SSH_KEY_GH:-}"
PREP_SET_PASSWORD="${PREP_SET_PASSWORD:-0}"
PREP_IS_CONTROLLER="${PREP_IS_CONTROLLER:-0}"   # set by prep-dev: this host is its own controller

# Output helpers — colored only on a tty so logs/pipes stay clean.
if [ -t 1 ]; then B=$'\033[1;34m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; X=$'\033[0m'; else B=; Y=; R=; X=; fi
say()  { printf '%s==>%s %s\n' "$B" "$X" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$Y" "$X" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$R" "$X" "$*" >&2; exit 1; }

# Use sudo only when not already root — a bare image may not have sudo yet.
if [ "$(id -u)" = "0" ]; then SUDO=""; is_root=1; else SUDO="sudo"; is_root=0; fi

# Validate inputs up front — fail loud, never prompt.
if [ "$is_root" = 1 ]; then
  [ -n "$PREP_USER" ] || die "running as root but PREP_USER is unset — set PREP_USER=<name>"
  if ! id "$PREP_USER" &>/dev/null \
     && [ -z "$PREP_SSH_KEY" ] && [ -z "$PREP_SSH_KEY_GH" ] && [ "$PREP_SET_PASSWORD" != "1" ]; then
    die "new user '$PREP_USER' would have no way to log in — set PREP_SSH_KEY and/or PREP_SSH_KEY_GH (or PREP_SET_PASSWORD=1)"
  fi
  # A controller never gets passwordless sudo, so a user created here without a
  # password could never use sudo at all (on Arch the paru build then fails mid-run).
  if ! id "$PREP_USER" &>/dev/null \
     && [ "$PREP_IS_CONTROLLER" = "1" ] && [ "$PREP_SET_PASSWORD" != "1" ]; then
    die "controller user '$PREP_USER' would be created with no password and no passwordless sudo, so it could never use sudo — add PREP_SET_PASSWORD=1, or create the user first and run as that user"
  fi
fi

say "Seeding Arch target — user=${PREP_USER:-$USER}, sshd=$([ "$PREP_ENABLE_SSHD" = "1" ] && echo on || echo off)"

# 0. sudo — the created user needs it for pyinfra ops; a bare root image may lack it.
say "Installing sudo"
$SUDO pacman -Sy --needed --noconfirm sudo

# 1. sshd (opt-out) — the controller needs something to connect to.
if [ "$PREP_ENABLE_SSHD" = "1" ]; then
  say "Installing and enabling sshd"
  $SUDO pacman -S --needed --noconfirm openssh
  $SUDO systemctl enable --now sshd
  sshd_state="enabled"
elif [ "$PREP_IS_CONTROLLER" = "1" ]; then
  say "Skipping sshd (this host is the controller — inbound SSH not needed)"
  sshd_state="skipped (controller)"
else
  warn "sshd was NOT enabled (PREP_ENABLE_SSHD=0) — the controller cannot reach this host yet."
  warn "If this is a remote target, rerun with PREP_ENABLE_SSHD=1 (the default)."
  sshd_state="NOT enabled — rerun with PREP_ENABLE_SSHD=1"
fi

# 2. non-root sudo user — only when bootstrapping as root.
if [ "$is_root" = 1 ]; then
  if id "$PREP_USER" &>/dev/null; then
    say "User '$PREP_USER' already exists"
  else
    say "Creating user '$PREP_USER' (group wheel)"
    useradd -m -G wheel "$PREP_USER"
    if [ "$PREP_SET_PASSWORD" = "1" ]; then
      say "Setting a password for '$PREP_USER' (interactive)"
      # Read from the terminal, not stdin: under `curl | bash` stdin is this script,
      # and passwd would swallow its next lines as the password and fail.
      passwd "$PREP_USER" < /dev/tty
    fi
  fi
  target_user="$PREP_USER"
else
  target_user="$USER"
fi

# 3. controller's SSH key(s) — required for non-interactive pyinfra access.
ssh_keys="$PREP_SSH_KEY"
if [ -n "$PREP_SSH_KEY_GH" ]; then
  say "Fetching keys from github.com/$PREP_SSH_KEY_GH.keys"
  ssh_keys="$(printf '%s\n%s\n' "$ssh_keys" "$(curl -fsSL "https://github.com/$PREP_SSH_KEY_GH.keys")")"
fi
if [ -n "${ssh_keys//[[:space:]]/}" ]; then
  say "Authorizing controller SSH key(s) for '$target_user'"
  home="$(getent passwd "$target_user" | cut -d: -f6)"
  $SUDO install -d -m 700 -o "$target_user" -g "$target_user" "$home/.ssh"
  printf '%s\n' "$ssh_keys" | $SUDO tee -a "$home/.ssh/authorized_keys" > /dev/null
  $SUDO sed -i '/^[[:space:]]*$/d' "$home/.ssh/authorized_keys"
  $SUDO sort -u "$home/.ssh/authorized_keys" -o "$home/.ssh/authorized_keys"
  $SUDO chown "$target_user:$target_user" "$home/.ssh/authorized_keys"
  $SUDO chmod 600 "$home/.ssh/authorized_keys"
  key_state="installed for $target_user"
else
  say "No SSH key provided (PREP_SSH_KEY / PREP_SSH_KEY_GH) — authorized_keys unchanged"
  key_state="none provided"
fi

# 4. sudoers — passwordless sudo so the controller can run pyinfra unattended over SSH.
#    Skipped on a controller/dev box (PREP_IS_CONTROLLER=1) so local sudo is left as-is.
if [ "$PREP_IS_CONTROLLER" = "1" ]; then
  say "Skipping passwordless sudo (controller — leaving your local sudo unchanged)"
  sudo_state="unchanged (controller)"
else
  say "Configuring passwordless sudo for '$target_user'"
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$target_user" | $SUDO tee /etc/sudoers.d/pyinfra > /dev/null
  $SUDO chmod 440 /etc/sudoers.d/pyinfra
  $SUDO visudo -cf /etc/sudoers.d/pyinfra > /dev/null || die "invalid sudoers file /etc/sudoers.d/pyinfra"
  sudo_state="NOPASSWD: ALL"
fi

# 5. paru (AUR helper) — build deps via pacman, build as the non-root target user.
$SUDO pacman -S --needed --noconfirm git base-devel
if [ "$(id -un)" = "$target_user" ]; then as_target=(bash); else as_target=(sudo -u "$target_user" bash); fi
if "${as_target[@]}" -c 'command -v paru' &>/dev/null; then
  say "paru already installed"
else
  say "Building paru as '$target_user' (makepkg refuses root)"
  "${as_target[@]}" -euo pipefail <<'BUILD'
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    curl -fsSL https://aur.archlinux.org/cgit/aur.git/snapshot/paru.tar.gz \
      | tar -xz -C "$tmpdir"
    cd "$tmpdir/paru"
    makepkg -si --noconfirm
BUILD
fi

say "Arch target seeded — summary:"
say "  user: $target_user"
say "  sshd: $sshd_state"
say "  keys: $key_state"
say "  sudo: $sudo_state"
if [ "$PREP_IS_CONTROLLER" = "1" ]; then
  say "This host is a controller — run pyinfra-local setup_machine.py (passworded sudo)."
elif [ "$PREP_ENABLE_SSHD" != "1" ]; then
  warn "sshd is off — rerun with PREP_ENABLE_SSHD=1 before the controller can connect."
else
  say "From the controller, run: .venv/bin/pyinfra inventory/<host>.py setup_machine.py"
fi
