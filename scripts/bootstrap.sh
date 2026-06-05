#!/usr/bin/env bash
# server initial setup (Debian/Ubuntu)

set -euo pipefail


# --- SCRIPT SETUP ---

# define constants
LOG="/var/log/bootstrap.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# define helper functions
step() {
  echo -e "\n-- $* ----------------";
  echo "[$TIMESTAMP] step: $*" >> "$LOG";
}
ok()   { echo "  ✔ $*"; echo "[$TIMESTAMP] ok: $*" >> "$LOG"; }
warn() { echo "  ~ $*"; echo "[$TIMESTAMP] warn: $*" >> "$LOG"; }
die()  { echo "  ✖ $*"; echo "[$TIMESTAMP] error: $*" >> "$LOG"; exit 1; }

# ensure running as root
[[ $EUID -eq 0 ]] || die "run this script as root (sudo bash bootstrap.sh)"

# yes/no confirmation prompt (default: yes)
confirm() {
  local reply
  while true; do
    read -rp "  $1 [Y/n]: " reply </dev/tty
    case "${reply:-y}" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      *) echo "  please answer y or n." ;;
    esac
  done
}


# --- MENU ---
echo ""
echo "-- bootstrap.sh ----------------"
echo ""

# get timezone from user
while true; do
  read -rp "  timezone [UTC]: " TIMEZONE </dev/tty
  TIMEZONE="${TIMEZONE:-UTC}"

  # timezone is valid: break loop
  if [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    break

  # timezone is invalid: show error and prompt again
  else
    echo \
      "  ✖ invalid timezone. try e.g. UTC, America/Sao_Paulo, Europe/Berlin."
  fi
done

# get options from user
confirm "install docker + docker compose?" &&
  OPT_DOCKER=true ||
  OPT_DOCKER=false
confirm "apply ssh hardening?"             && OPT_SSH=true    || OPT_SSH=false
confirm "add ssh authorized keys?"         && OPT_KEYS=true   || OPT_KEYS=false
confirm "enable ufw firewall?"             && OPT_UFW=true    || OPT_UFW=false

# show summary and confirm
echo ""
echo "  timezone: $TIMEZONE  |  docker: $($OPT_DOCKER && echo 'yes' || echo 'no')  |  ssh: $($OPT_SSH && echo 'yes' || echo 'no')  |  keys: $($OPT_KEYS && echo 'yes' || echo 'no')  |  ufw: $($OPT_UFW && echo 'yes' || echo 'no')"
echo ""
confirm "proceed?" || { echo "  aborted."; exit 0; }

# initialize log
echo "[$TIMESTAMP] bootstrap started" >> "$LOG"
echo "[$TIMESTAMP] timezone=$TIMEZONE docker=$OPT_DOCKER ssh=$OPT_SSH keys=$OPT_KEYS ufw=$OPT_UFW" >> "$LOG"


# --- SYSTEM UPDATE ---
step "system update"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get autoremove -y -qq
ok "system up to date"


# --- TIMEZONE ---
step "timezone"
ln -fs "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
dpkg-reconfigure -f noninteractive tzdata
ok "timezone: $TIMEZONE"


# --- INSTALL PACKAGES ---
step "core packages"
apt-get install -y -qq \
  git \
  curl \
  wget \
  vim \
  nano \
  htop \
  jq \
  unzip \
  rsync \
  lsof \
  net-tools \
  dnsutils \
  ca-certificates \
  gnupg \
  apt-transport-https
ok "packages installed"


# --- DOCKER ---
if $OPT_DOCKER; then
  step "docker"

  # docker is already installed: skip installation
  if command -v docker &>/dev/null; then
    warn "docker already installed — skipping"

  # docker not installed: proceed with installation
  else
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    . /etc/os-release
    cat > /etc/apt/sources.list.d/docker.sources << DOCKERSRC
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKERSRC

    apt-get update -qq
    apt-get install -y -qq \
      docker-ce \
      docker-ce-cli \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    ok "docker $(docker --version | cut -d' ' -f3 | tr -d ',') installed"
    ok "docker compose $(docker compose version --short) installed"
  fi
else
  warn "docker skipped"
fi


# --- PROMPT + ALIASES ---
step "prompt + aliases"

# aliases go to /etc/bash.bashrc (system-wide, all users)
grep -q "server-bootstrap" /etc/bash.bashrc 2>/dev/null && {
  warn "aliases already configured — skipping"
} || cat >> /etc/bash.bashrc << 'BASHRC'

# server-bootstrap
alias gs='git status'
alias gl='git log --oneline --graph --decorate'
BASHRC

# PS1 goes to the invoking user's ~/.bashrc (must be last to avoid being overridden)
TARGET_HOME=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
TARGET_BASHRC="$TARGET_HOME/.bashrc"
grep -q "server-bootstrap-ps1" "$TARGET_BASHRC" 2>/dev/null && {
  warn "prompt already configured — skipping"
} || cat >> "$TARGET_BASHRC" << 'BASHRC'

# server-bootstrap-ps1
PS1='${debian_chroot:+($debian_chroot)}\[\033[01;31m\]\u\[\033[01;33m\]@\[\033[01;36m\]\h \[\033[01;33m\]\w \[\033[01;35m\]\$ \[\033[00m\]'
BASHRC
ok "prompt and aliases configured — open a new shell to apply"


# --- SSH KEYS ---
if $OPT_KEYS; then
  step "ssh keys"

  AUTH_KEYS="/root/.ssh/authorized_keys"
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch "$AUTH_KEYS"
  chmod 600 "$AUTH_KEYS"

  echo "  paste each public key and press enter. leave blank to finish."
  KEY_COUNT=0
  while true; do
    read -rp "  key $((KEY_COUNT + 1)): " pubkey </dev/tty

    # empty input: stop collecting keys
    [[ -z "$pubkey" ]] && break

    # key already exists: skip to avoid duplicates
    if grep -qF "$pubkey" "$AUTH_KEYS" 2>/dev/null; then
      warn "key already exists — skipping"

    # new key: append to authorized_keys
    else
      echo "$pubkey" >> "$AUTH_KEYS"
      ok "key added"
      (( KEY_COUNT++ )) || true
    fi
  done

  [[ $KEY_COUNT -eq 0 ]] && warn "no keys added" || ok "$KEY_COUNT key(s) added"
else
  warn "ssh keys skipped"
fi


# --- SSH HARDENING ---
if $OPT_SSH; then
  step "ssh hardening"

  SSHD="/etc/ssh/sshd_config"

  # backup sshd_config before making changes
  cp "$SSHD" "${SSHD}.bak.$(date +%Y%m%d%H%M%S)"

  # set or replace a key in sshd_config
  sshd_set() {
    local key="$1" val="$2"

    # key exists (commented or not): replace it
    if grep -qE "^#?${key}" "$SSHD"; then
      sed -i "s|^#\?${key}.*|${key} ${val}|" "$SSHD"

    # key not found: append it
    else
      echo "${key} ${val}" >> "$SSHD"
    fi
  }

  # disable root login and password auth, enforce key-only access
  sshd_set "PermitRootLogin"        "no"
  sshd_set "PasswordAuthentication" "no"
  sshd_set "PubkeyAuthentication"   "yes"

  # validate config before restarting to avoid locking ourselves out
  sshd -t && ok "sshd config valid" || die "sshd config has errors — check $SSHD"
  systemctl restart ssh
  ok "ssh hardened"
else
  warn "ssh hardening skipped"
fi


# --- UFW ---
if $OPT_UFW; then
  step "ufw"

  # reset rules and set secure defaults
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  # allow only essential ports
  ufw allow 22/tcp  comment "SSH"
  ufw allow 80/tcp  comment "HTTP"
  ufw allow 443/tcp comment "HTTPS"
  ufw --force enable
  ok "ufw enabled — allowed: 22, 80, 443"
else
  warn "ufw skipped"
fi


# --- DONE ---
echo "[$TIMESTAMP] bootstrap complete" >> "$LOG"

echo ""
echo "-- done ------------------------"
echo ""
echo "  timezone:  $TIMEZONE"
$OPT_DOCKER && echo "  docker:    installed"
$OPT_SSH    && echo "  ssh:       key-only, root login disabled"
$OPT_UFW    && echo "  firewall:  ufw active (22, 80, 443)"
echo ""
echo "  log saved to $LOG"
echo "  reboot recommended."
echo ""
