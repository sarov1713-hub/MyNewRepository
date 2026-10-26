#!/usr/bin/env bash
# AstraFin FreeIPA client enrollment for Debian, Ubuntu, and RHEL-family Linux.
# Run interactively as root; do not store FreeIPA credentials in this script.
set -Eeuo pipefail

IPA_HOST="${IPA_HOST:-idm01.int.astrafin.test}"
IPA_DOMAIN="${IPA_DOMAIN:-int.astrafin.test}"
IPA_REALM="${IPA_REALM:-INT.ASTRAFIN.TEST}"
IPA_ADMIN="${IPA_ADMIN:-admin}"
IPA_CA_FILE="${IPA_CA_FILE:-}"
IPA_CA_SHA256="${IPA_CA_SHA256:-}"
ENROLL_HOST="${ENROLL_HOST:-$(hostname -f 2>/dev/null || true)}"

log() { printf '\n[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || die 'Run as root: sudo bash ./astrafin-ipa-enroll.sh.'
[[ -n "$ENROLL_HOST" && "$ENROLL_HOST" == *.* && "$ENROLL_HOST" != localhost* ]] || die 'Set a valid FQDN (ENROLL_HOST=...).'
[[ "$ENROLL_HOST" != "$IPA_HOST" ]] || die 'Do not enroll the FreeIPA server as a client.'
[[ -n "$IPA_CA_FILE" || -n "$IPA_CA_SHA256" ]] || die 'Provide IPA_CA_FILE=/trusted/ipa-ca.crt or IPA_CA_SHA256=<trusted sha256>.'
[[ -z "$IPA_CA_SHA256" || "$IPA_CA_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || die 'IPA_CA_SHA256 must be 64 hexadecimal characters.'
[[ ! -e /etc/ipa/default.conf ]] || die 'This host appears to be enrolled already (/etc/ipa/default.conf exists). Inspect it manually.'

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
else
  die 'Cannot identify the operating system.'
fi
case "${ID:-}" in
  debian|ubuntu) PKG_FAMILY=apt ;;
  almalinux|rocky|rhel|centos|fedora) PKG_FAMILY=dnf ;;
  *) die "Unsupported OS: ${ID:-unknown}" ;;
esac

log "Preflight: OS=${PRETTY_NAME:-$ID}, host=$ENROLL_HOST, FreeIPA=$IPA_HOST"
command -v getent >/dev/null || die 'getent is missing.'
getent ahostsv4 "$IPA_HOST" >/dev/null || die "DNS cannot resolve $IPA_HOST."
getent ahostsv4 "$ENROLL_HOST" >/dev/null || die "DNS cannot resolve $ENROLL_HOST. Create/check the host A record first."

# Require working Kerberos, LDAP, HTTPS, and password-change TCP paths.
for port in 88 389 443 464; do
  if ! timeout 4 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$IPA_HOST" "$port" 2>/dev/null; then
    die "Cannot reach $IPA_HOST on TCP/$port. Check routing and firewall rules."
  fi
done

# Check actual clock discipline, not just whether an NTP service is running.
if command -v chronyc >/dev/null 2>&1; then
  tracking="$(chronyc tracking 2>/dev/null || true)"
  printf '%s\n' "$tracking" | grep -Eq 'Leap status[[:space:]]*:[[:space:]]*Normal' || die 'Chrony is not synchronized (Leap status is not Normal).'
  offset="$(printf '%s\n' "$tracking" | awk '/^System time[[:space:]]*:/ {print $4}')"
  [[ "$offset" =~ ^[0-9]+([.][0-9]+)?$ ]] || die 'Cannot parse Chrony system-time offset.'
  awk -v value="$offset" 'BEGIN {exit !(value < 60)}' || die "Clock offset ($offset seconds) is too large. Fix NTP before enrollment."
elif command -v timedatectl >/dev/null 2>&1; then
  sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  [[ "$sync" == yes ]] || die 'System clock is not synchronized. Fix NTP before enrollment.'
else
  die 'Cannot verify time synchronization (chronyc/timedatectl missing).'
fi

log 'Preflight passed. Confirm that the FreeIPA server clock is synchronized too.'
printf 'Enroll %s into %s via %s? [y/N] ' "$ENROLL_HOST" "$IPA_REALM" "$IPA_HOST"
read -r answer
[[ "$answer" == y || "$answer" == Y ]] || die 'Cancelled.'

log 'Installing FreeIPA client dependencies'
if [[ "$PKG_FAMILY" == apt ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y freeipa-client sssd-ipa sssd-tools libsss-sudo sudo curl ca-certificates openssl
else
  dnf install -y ipa-client sssd-ipa sssd-tools sudo curl ca-certificates openssl
fi

# Ubuntu may default to sudo-rs, which does not support SSSD sudo rules.
if [[ "$PKG_FAMILY" == apt ]] && [[ -x /usr/bin/sudo.ws ]] && command -v update-alternatives >/dev/null; then
  if update-alternatives --query sudo 2>/dev/null | grep -Fq 'Alternative: /usr/bin/sudo.ws'; then
    current_sudo="$(update-alternatives --query sudo 2>/dev/null | awk '/^Value: / {print $2}')"
    if [[ "$current_sudo" != /usr/bin/sudo.ws ]]; then
      log 'Selecting classic sudo for SSSD sudo-rule support'
      update-alternatives --set sudo /usr/bin/sudo.ws
    fi
  fi
fi

# Use a trusted CA file or verify a downloaded CA against an out-of-band hash.
ca_tmp=''
cleanup() { [[ -z "$ca_tmp" ]] || rm -f "$ca_tmp"; }
trap cleanup EXIT
if [[ -n "$IPA_CA_FILE" ]]; then
  [[ -r "$IPA_CA_FILE" ]] || die "Cannot read CA file: $IPA_CA_FILE"
  ca_file="$IPA_CA_FILE"
else
  ca_tmp="$(mktemp /tmp/astrafin-ipa-ca.XXXXXXXX.crt)"
  curl --fail --silent --show-error --insecure --connect-timeout 5 \
    "https://$IPA_HOST/ipa/config/ca.crt" -o "$ca_tmp"
  ca_file="$ca_tmp"
fi
if [[ -n "$IPA_CA_SHA256" ]]; then
  actual="$(sha256sum "$ca_file" | awk '{print $1}')"
  [[ "${actual,,}" == "${IPA_CA_SHA256,,}" ]] || die 'FreeIPA CA SHA256 mismatch. Aborting.'
fi
openssl x509 -in "$ca_file" -noout >/dev/null 2>&1 || die 'CA file is not a valid PEM certificate.'

log 'Enrolling host (FreeIPA administrator password will be requested interactively)'
ipa-client-install \
  --hostname="$ENROLL_HOST" \
  --domain="$IPA_DOMAIN" \
  --realm="$IPA_REALM" \
  --server="$IPA_HOST" \
  --ca-cert-file="$ca_file" \
  --principal="$IPA_ADMIN" \
  --mkhomedir \
  --no-ntp

# Debian/Ubuntu can socket-activate the sudo responder. Avoid dual startup.
if [[ "$PKG_FAMILY" == apt ]]; then
  if systemctl is-enabled sssd-sudo.socket >/dev/null 2>&1; then
    python3 - <<'PY'
from pathlib import Path
import re
p = Path('/etc/sssd/sssd.conf')
s = p.read_text()
def update(m):
    services = [x.strip() for x in m.group(2).split(',') if x.strip()]
    services = [x for x in services if x != 'sudo']
    return m.group(1) + ', '.join(services)
s = re.sub(r'(?m)^(\s*services\s*=\s*)([^\n#]+)', update, s)
p.write_text(s)
PY
    systemctl restart sssd
    systemctl stop sssd-sudo.service 2>/dev/null || true
    systemctl reset-failed sssd-sudo.socket 2>/dev/null || true
    systemctl start sssd-sudo.socket
  fi
fi

# Enable sudo rule lookup from SSSD without granting any local sudo rights.
if grep -qE '^sudoers:' /etc/nsswitch.conf; then
  if ! grep -E '^sudoers:' /etc/nsswitch.conf | grep -qw sss; then
    sed -i -E '/^sudoers:/ s/$/ sss/' /etc/nsswitch.conf
  fi
else
  printf '\nsudoers: files sss\n' >> /etc/nsswitch.conf
fi

log 'Checking SSSD and FreeIPA identity resolution'
systemctl is-active --quiet sssd || die 'SSSD is not running.'
sssctl domain-status "$IPA_DOMAIN" >/dev/null 2>&1 || warn "SSSD domain status is not available yet: $IPA_DOMAIN"
log "Enrollment finished: $ENROLL_HOST"
log 'Sudo authorization still requires a host-scoped FreeIPA sudo rule.'
log 'Check with: id <ipa-user>; ssh <ipa-user>@localhost; sudo -l'
