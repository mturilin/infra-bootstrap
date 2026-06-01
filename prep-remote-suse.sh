#!/usr/bin/env bash
# What: Seed a fresh openSUSE target so a pyinfra controller can take over via SSH.
# Why: pyinfra needs only sshd + a sudo user (with the controller's key) on the target —
#      zypper already works, and pyinfra pushes plain shell over SSH (no Python-on-remote).
# Design: Standalone (curl|bash-able) — does NOT source lib/, works with no repo clone.
#         Idempotent. Uses $SUDO so it runs both as root (bare image) and as a normal
#         sudo user, and installs the `sudo` package itself since a fresh box may lack it.
#         Reused by prep-dev-suse.sh with PREP_ENABLE_SSHD=0.
# Gotchas: sshd enable is opt-out via PREP_ENABLE_SSHD=0. Run as root to create a user
#          (set PREP_USER=<name>). Set PREP_SSH_KEY='ssh-ed25519 AAAA… you@host' and/or
#          PREP_SSH_KEY_GH=<gh-user> to install the controller's key(s) for non-interactive SSH.
set -euo pipefail

PREP_ENABLE_SSHD="${PREP_ENABLE_SSHD:-1}"
PREP_USER="${PREP_USER:-}"
PREP_SSH_KEY="${PREP_SSH_KEY:-}"
PREP_SSH_KEY_GH="${PREP_SSH_KEY_GH:-}"

# Use sudo only when not already root — a bare image may not have sudo yet.
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi

# 0. sudo — the created user needs it for pyinfra ops; a bare root image may lack it.
$SUDO zypper --non-interactive install -y sudo

# 1. sshd (opt-out)
if [ "$PREP_ENABLE_SSHD" = "1" ]; then
  $SUDO zypper --non-interactive install -y openssh
  $SUDO systemctl enable --now sshd
fi

# 2. non-root sudo user — only when bootstrapping as root.
if [ "$(id -u)" = "0" ]; then
  [ -n "$PREP_USER" ] || { echo "set PREP_USER=<name> when running as root" >&2; exit 1; }
  if ! id "$PREP_USER" &>/dev/null; then
    useradd -m -G wheel "$PREP_USER"
    echo "set a password for $PREP_USER:"
    passwd "$PREP_USER"
  fi
  target_user="$PREP_USER"
else
  target_user="$USER"
fi

# 3. controller's SSH key(s) — required for non-interactive pyinfra access. Supply a
#    literal key via PREP_SSH_KEY and/or a GitHub username via PREP_SSH_KEY_GH
#    (fetches https://github.com/<user>.keys). Both may be set; keys are merged.
ssh_keys="$PREP_SSH_KEY"
if [ -n "$PREP_SSH_KEY_GH" ]; then
  ssh_keys="$(printf '%s\n%s\n' "$ssh_keys" "$(curl -fsSL "https://github.com/$PREP_SSH_KEY_GH.keys")")"
fi
if [ -n "${ssh_keys//[[:space:]]/}" ]; then
  home="$(getent passwd "$target_user" | cut -d: -f6)"
  $SUDO install -d -m 700 -o "$target_user" -g "$target_user" "$home/.ssh"
  printf '%s\n' "$ssh_keys" | $SUDO tee -a "$home/.ssh/authorized_keys" > /dev/null
  $SUDO sed -i '/^[[:space:]]*$/d' "$home/.ssh/authorized_keys"
  $SUDO sort -u "$home/.ssh/authorized_keys" -o "$home/.ssh/authorized_keys"
  $SUDO chown "$target_user:$target_user" "$home/.ssh/authorized_keys"
  $SUDO chmod 600 "$home/.ssh/authorized_keys"
fi

echo "openSUSE target seeded — SSH + sudo user ready."
echo "From the controller, run: .venv/bin/pyinfra inventory/<host>.py setup_machine.py"
