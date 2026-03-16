#!/usr/bin/env bash
set -euo pipefail

readonly CA_NAME="agent_ca"

ca_dir="/etc/ssh"
key_type="ed25519"

usage() {
  printf 'Usage: %s [OPTIONS]\n\n' "$(basename "${0}")"
  printf 'Initialize an SSH Certificate Authority for signing temporary agent certificates.\n\n'
  printf 'Options:\n'
  printf '  --ca-dir DIR     Directory to store CA keys (default: /etc/ssh)\n'
  printf '  --key-type TYPE  Key type: ed25519 (default) or rsa\n'
  printf '  --help           Show this help message\n'
  exit 0
}

die() { printf 'ERROR: %s\n' "${1}" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --ca-dir)   [[ $# -ge 2 ]] || die "--ca-dir requires a value"; ca_dir="${2}"; shift 2 ;;
    --key-type) [[ $# -ge 2 ]] || die "--key-type requires a value"; key_type="${2}"; shift 2 ;;
    --help)     usage ;;
    *)          die "Unknown option: ${1}" ;;
  esac
done

readonly ca_private="${ca_dir}/${CA_NAME}"
readonly ca_public="${ca_dir}/${CA_NAME}.pub"

[[ "${key_type}" == "ed25519" || "${key_type}" == "rsa" ]] || die "Key type must be 'ed25519' or 'rsa'"
command -v ssh-keygen &>/dev/null || die "ssh-keygen is required but not found"
[[ ${EUID} -eq 0 ]] || die "This script must be run as root (sudo)"

if [[ -f "${ca_private}" ]]; then
  printf 'WARNING: CA key already exists at %s\n' "${ca_private}"
  printf 'To regenerate, first back up and remove the existing key.\n'
  if [[ -f "${ca_public}" ]]; then
    printf '\nExisting CA public key:\n'
    cat "${ca_public}"
  else
    printf '\nWARNING: Public key missing at %s. Regenerate with:\n' "${ca_public}"
    printf '  ssh-keygen -y -f %s > %s\n' "${ca_private}" "${ca_public}"
  fi
  exit 0
fi

mkdir -p "${ca_dir}"

printf '=== SSH Certificate Authority Setup ===\n'
printf 'Directory: %s\nKey type:  %s\n\n' "${ca_dir}" "${key_type}"

if [[ "${key_type}" == "ed25519" ]]; then
  ssh-keygen -t ed25519 -f "${ca_private}" -N "" -C "agent-support-ca@$(hostname)"
else
  ssh-keygen -t rsa -b 4096 -f "${ca_private}" -N "" -C "agent-support-ca@$(hostname)"
fi

chmod 400 "${ca_private}"
chmod 444 "${ca_public}"

printf '\n=== CA Created Successfully ===\n'
printf 'Private key: %s (chmod 400)\nPublic key:  %s\n\n' "${ca_private}" "${ca_public}"
printf 'CA Public Key (copy this to target servers):\n---\n'
cat "${ca_public}"
printf '%s\n\n=== Next Steps ===\n' '---'
printf 'On each target server:\n'
printf '  1. Copy the CA public key to /etc/ssh/agent_ca.pub\n'
printf '  2. Add to /etc/ssh/sshd_config:\n'
printf '       TrustedUserCAKeys /etc/ssh/agent_ca.pub\n'
printf '  3. Recommended hardening (also in sshd_config):\n'
printf '       MaxSessions 1\n       MaxAuthTries 3\n       AuthenticationMethods publickey\n'
printf '  4. Restart sshd:\n       systemctl restart sshd\n\n'
printf 'Then use grant-access.sh to provision temporary agent sessions.\n'
