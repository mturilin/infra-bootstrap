#!/usr/bin/env bash
# What: Seed a fresh Arch target so a pyinfra controller can take it over via SSH.
# Why: pyinfra can't connect until sshd + a sudo user (with the controller's key) exist,
#      and its pacman/AUR ops need passwordless pacman + paru on the target. This is the
#      irreducible pre-pyinfra step that must run on the target itself.
# Design: Standalone (curl|bash-able) — does NOT source lib/, so it works with no repo
#         clone. Idempotent. Uses $SUDO so it runs both as root (bare image) and as a
#         normal sudo user; it installs the `sudo` package itself since a fresh box may
#         lack it. paru is built as the non-root target user (makepkg refuses root).
#         Shared by prep-dev-arch.sh, which calls it with PREP_ENABLE_SSHD=0.
# Gotchas: sshd enable is opt-out via PREP_ENABLE_SSHD=0 so a dev laptop isn't turned
#          into an SSH server. Run as root to create a user (set PREP_USER=<name>).
#          Set PREP_SSH_KEY='ssh-ed25519 AAAA… you@host' and/or PREP_SSH_KEY_GH=<gh-user>
#          to install the controller's key(s) for non-interactive SSH (else only a password).
set -euo pipefail

PREP_ENABLE_SSHD="${PREP_ENABLE_SSHD:-1}"
PREP_USER="${PREP_USER:-}"
PREP_SSH_KEY="${PREP_SSH_KEY:-}"
PREP_SSH_KEY_GH="${PREP_SSH_KEY_GH:-}"

# Use sudo only when not already root — a bare image may not have sudo yet.
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi

# 0. sudo — the created user needs it for pyinfra ops; a bare root image may lack it.
$SUDO pacman -Sy --needed --noconfirm sudo

# 1. sshd (opt-out) — the controller needs something to connect to.
if [ "$PREP_ENABLE_SSHD" = "1" ]; then
  $SUDO pacman -S --needed --noconfirm openssh
  $SUDO systemctl enable --now sshd
fi

# 2. non-root sudo user — only when bootstrapping as root. The controller
#    connects as this user, never root.
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

# 4. sudoers — passwordless pacman for pyinfra's package ops, plus wheel sudo
#    for the rest of provisioning.
echo "$target_user ALL=(ALL) NOPASSWD: /usr/bin/pacman" \
  | $SUDO tee /etc/sudoers.d/pyinfra-pacman > /dev/null
$SUDO chmod 440 /etc/sudoers.d/pyinfra-pacman
echo "%wheel ALL=(ALL) ALL" | $SUDO tee /etc/sudoers.d/wheel > /dev/null
$SUDO chmod 440 /etc/sudoers.d/wheel

# 5. paru (AUR helper) — build deps via pacman, build as the non-root target user.
$SUDO pacman -S --needed --noconfirm git base-devel
if [ "$(id -un)" = "$target_user" ]; then as_target=(bash); else as_target=(sudo -u "$target_user" bash); fi
if ! "${as_target[@]}" -c 'command -v paru' &>/dev/null; then
  "${as_target[@]}" -euo pipefail <<'BUILD'
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    curl -fsSL https://aur.archlinux.org/cgit/aur.git/snapshot/paru.tar.gz \
      | tar -xz -C "$tmpdir"
    cd "$tmpdir/paru"
    makepkg -si --noconfirm
BUILD
fi

echo "Arch target seeded. From the controller, run:"
echo "  .venv/bin/pyinfra inventory/<host>.py setup_machine.py"
