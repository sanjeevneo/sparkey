#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
PASS=0
FAIL=0
SKIP=0

pass()    { PASS=$((PASS + 1)); printf '  PASS: %s\n' "${1}"; }
fail()    { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "${1}" >&2; }
skip()    { SKIP=$((SKIP + 1)); printf '  SKIP: %s\n' "${1}"; }
section() { printf '\n=== %s ===\n' "${1}"; }

assert_exit() {
  local desc="${1}" expected="${2}" actual="${3}"
  if [[ "${actual}" -eq "${expected}" ]]; then
    pass "${desc}"
  else
    fail "${desc} (exit ${actual}, expected ${expected})"
  fi
}

assert_grep() {
  local desc="${1}" pattern="${2}" text="${3}"
  if printf '%s' "${text}" | grep -qiE "${pattern}"; then
    pass "${desc}"
  else
    fail "${desc}"
  fi
}

assert_no_grep() {
  local desc="${1}" pattern="${2}" text="${3}"
  if ! printf '%s' "${text}" | grep -qiE "${pattern}"; then
    pass "${desc}"
  else
    fail "${desc}"
  fi
}

assert_file_exists()   { [[ -f "${2}" ]] && pass "${1}" || fail "${1}"; }
assert_file_missing()  { [[ ! -f "${2}" ]] && pass "${1}" || fail "${1}"; }
assert_file_exec()     { [[ -x "${2}" ]] && pass "${1}" || fail "${1}"; }
assert_not_empty()     { [[ -n "${2}" ]] && pass "${1}" || fail "${1}"; }

dispatch_test() {
  local shell="${1}" cmd="${2}" desc="${3}" expect="${4}"
  local result
  result=$(SSH_ORIGINAL_COMMAND="${cmd}" bash "${shell}" 2>&1) || true
  case "${expect}" in
    allowed)
      assert_no_grep "Dispatch: ${desc}" "not allowed|not in allowlist|blocked|denied" "${result}" ;;
    blocked_meta)
      assert_grep "Dispatch: ${desc}" "metacharacter|not allowed" "${result}" ;;
    blocked_path)
      assert_grep "Dispatch: ${desc}" "by name, not by path|not allowed|blocked" "${result}" ;;
    blocked_traversal)
      assert_grep "Dispatch: ${desc}" "traversal|not allowed|blocked" "${result}" ;;
    blocked_cmd)
      assert_grep "Dispatch: ${desc}" "not in allowlist|not allowed|outside allowed" "${result}" ;;
    blocked_newline)
      assert_grep "Dispatch: ${desc}" "newline|not allowed" "${result}" ;;
    restricted_help)
      assert_grep "Dispatch: ${desc}" "restricted|send commands" "${result}" ;;
  esac
}

cleanup_all() {
  printf '\n--- Cleanup ---\n'
  for u in $(getent passwd 2>/dev/null | grep '^agent_support_' | cut -d: -f1); do
    chattr -i "/home/${u}/.ssh/authorized_keys" 2>/dev/null || true
    chattr -i "/home/${u}/.ssh" 2>/dev/null || true
    userdel -r "${u}" 2>/dev/null || true
    printf '  Cleaned up user: %s\n' "${u}"
  done
  if [[ -f /etc/ssh/agent_ca.e2e_backup ]]; then
    mv /etc/ssh/agent_ca.e2e_backup /etc/ssh/agent_ca 2>/dev/null || true
    mv /etc/ssh/agent_ca.pub.e2e_backup /etc/ssh/agent_ca.pub 2>/dev/null || true
    printf '  Restored original CA\n'
  fi
  rm -f /tmp/agent_session_* /tmp/e2e_agent_key* 2>/dev/null || true
  rm -f /usr/local/bin/agent-support-shell-* /usr/local/sbin/agent-cleanup-*.sh 2>/dev/null || true
  printf '  Temp files cleaned\n'
}

section "0. Prerequisites"

[[ ${EUID} -eq 0 ]] || { printf 'ERROR: Must run as root\n' >&2; exit 1; }
pass "Running as root"

[[ "$(uname -s)" == "Linux" ]] || { printf 'ERROR: Requires Linux\n' >&2; exit 1; }
pass "Running on Linux"

for cmd in ssh-keygen useradd userdel passwd pkill getent date; do
  command -v "${cmd}" &>/dev/null && pass "Dependency: ${cmd}" || fail "Missing: ${cmd}"
done

if [[ -f /etc/ssh/agent_ca ]]; then
  cp /etc/ssh/agent_ca /etc/ssh/agent_ca.e2e_backup
  cp /etc/ssh/agent_ca.pub /etc/ssh/agent_ca.pub.e2e_backup 2>/dev/null || true
  printf '  INFO: Backed up existing CA\n'
  rm -f /etc/ssh/agent_ca /etc/ssh/agent_ca.pub
fi

trap cleanup_all EXIT

section "1. setup-ca.sh"

OUTPUT=$(bash "${SCRIPT_DIR}/setup-ca.sh" 2>&1); EXIT_CODE=$?
assert_exit "setup-ca.sh exited 0" 0 "${EXIT_CODE}"
[[ ${EXIT_CODE} -ne 0 ]] && printf '%s\n' "${OUTPUT}"

assert_file_exists "CA private key created" /etc/ssh/agent_ca
assert_file_exists "CA public key created" /etc/ssh/agent_ca.pub

PERMS=$(stat -c '%a' /etc/ssh/agent_ca 2>/dev/null)
[[ "${PERMS}" == "400" ]] && pass "CA private key permissions: 400" || fail "CA private key permissions: ${PERMS} (expected 400)"

KEY_TYPE=$(ssh-keygen -l -f /etc/ssh/agent_ca.pub 2>/dev/null | awk '{print $NF}')
printf '%s' "${KEY_TYPE}" | grep -qi "ed25519" && pass "CA key type: Ed25519" || fail "CA key type: ${KEY_TYPE}"

OUTPUT2=$(bash "${SCRIPT_DIR}/setup-ca.sh" 2>&1)
assert_grep "Idempotent: refuses to overwrite existing CA" "already exists" "${OUTPUT2}"

assert_grep "--help shows usage" "Usage" "$(bash "${SCRIPT_DIR}/setup-ca.sh" --help 2>&1)"

section "2. grant-access.sh — CA mode with generated key"

OUTPUT=$(bash "${SCRIPT_DIR}/grant-access.sh" --host testserver.local --duration 1h --allow diagnostic 2>&1); EXIT_CODE=$?
assert_exit "grant-access.sh (CA/generated) exited 0" 0 "${EXIT_CODE}"
[[ ${EXIT_CODE} -ne 0 ]] && printf '%s\n' "${OUTPUT}"

SESSION_CA=$(printf '%s' "${OUTPUT}" | grep 'Session ID:' | head -1 | awk '{print $NF}')
USER_CA=$(printf '%s' "${OUTPUT}" | grep 'Account:' | head -1 | awk '{print $NF}')

assert_not_empty "Session ID returned: ${SESSION_CA}" "${SESSION_CA}"
id "${USER_CA}" &>/dev/null && pass "Agent account created: ${USER_CA}" || fail "Agent account not found: ${USER_CA}"

PASSWD_STATUS=$(passwd -S "${USER_CA}" 2>/dev/null | awk '{print $2}')
[[ "${PASSWD_STATUS}" == "L" || "${PASSWD_STATUS}" == "LK" ]] && pass "Account password locked" || fail "Password not locked: ${PASSWD_STATUS}"

SHELL_PATH="/usr/local/bin/agent-support-shell-${SESSION_CA}"
assert_file_exists "Support shell installed" "${SHELL_PATH}"
assert_file_exec "Support shell is executable" "${SHELL_PATH}"

assert_grep "Support shell has metacharacter filter" "grep -qE" "$(cat "${SHELL_PATH}" 2>/dev/null)"
assert_grep "Support shell has path validation" "check_paths" "$(cat "${SHELL_PATH}" 2>/dev/null)"
assert_no_grep "Support shell has no eval" "eval " "$(cat "${SHELL_PATH}" 2>/dev/null)"

KEY_PATH="/tmp/agent_session_${SESSION_CA}"
assert_file_exists "Session private key generated" "${KEY_PATH}"

CERT_PATH="${KEY_PATH}-cert.pub"
assert_file_exists "Session certificate generated" "${CERT_PATH}"

CERT_INFO=$(ssh-keygen -L -f "${CERT_PATH}" 2>/dev/null)
assert_grep "Certificate principal matches account" "${USER_CA}" "${CERT_INFO}"
assert_grep "Certificate has force-command" "force-command" "${CERT_INFO}"
assert_no_grep "Certificate denies port-forwarding" "permit-port-forwarding" "${CERT_INFO}"

CLEANUP_PATH="/usr/local/sbin/agent-cleanup-${SESSION_CA}.sh"
assert_file_exists "Cleanup script created" "${CLEANUP_PATH}"

[[ -f /var/log/agent-support.log ]] && grep -q "SESSION_START.*${SESSION_CA}" /var/log/agent-support.log && \
  pass "SESSION_START logged" || fail "SESSION_START not found in log"

section "3. grant-access.sh — CA mode with agent-provided pubkey"

ssh-keygen -t ed25519 -N "" -f /tmp/e2e_agent_key -C "e2e-test" -q

OUTPUT=$(bash "${SCRIPT_DIR}/grant-access.sh" --host testserver.local --duration 2h --allow remediation --agent-pubkey /tmp/e2e_agent_key.pub 2>&1)
EXIT_CODE=$?
assert_exit "grant-access.sh (CA/agent-pubkey) exited 0" 0 "${EXIT_CODE}"
[[ ${EXIT_CODE} -ne 0 ]] && printf '%s\n' "${OUTPUT}"

SESSION_PK=$(printf '%s' "${OUTPUT}" | grep 'Session ID:' | head -1 | awk '{print $NF}')
USER_PK=$(printf '%s' "${OUTPUT}" | grep 'Account:' | head -1 | awk '{print $NF}')

id "${USER_PK}" &>/dev/null && pass "Agent account created (agent-pubkey): ${USER_PK}" || fail "Agent account not found (agent-pubkey)"

assert_file_exists "Certificate signed for agent pubkey" "/tmp/e2e_agent_key-cert.pub"

SHELL_PK="/usr/local/bin/agent-support-shell-${SESSION_PK}"
[[ -f "${SHELL_PK}" ]] && grep -q 'remediation' "${SHELL_PK}" && \
  pass "Remediation support shell installed" || fail "Remediation support shell not found or wrong profile"
grep -q 'kill|pkill' "${SHELL_PK}" 2>/dev/null && \
  pass "Remediation profile includes kill/pkill" || fail "Remediation profile missing expected commands"

if [[ -f "${SHELL_PK}" ]]; then
  dispatch_test "${SHELL_PK}" "uptime"                                   "remediation: 'uptime' allowed"                  allowed
  dispatch_test "${SHELL_PK}" "curl --help"                              "remediation: 'curl' allowed"                    allowed
  dispatch_test "${SHELL_PK}" "systemctl restart sshd"                   "remediation: 'systemctl restart' allowed"       allowed
  dispatch_test "${SHELL_PK}" "systemctl enable malicious"               "remediation: 'systemctl enable' blocked"        blocked_cmd
  dispatch_test "${SHELL_PK}" "rm -rf /"                                 "remediation: 'rm' blocked"                      blocked_cmd
  dispatch_test "${SHELL_PK}" "cat /etc/passwd | grep root"              "remediation: pipe blocked"                      blocked_meta
fi

section "4. grant-access.sh — no-CA mode (authorized_keys)"

OUTPUT=$(bash "${SCRIPT_DIR}/grant-access.sh" --host testserver.local --duration 30m --no-ca --agent-pubkey /tmp/e2e_agent_key.pub 2>&1)
EXIT_CODE=$?
assert_exit "grant-access.sh (no-CA) exited 0" 0 "${EXIT_CODE}"
[[ ${EXIT_CODE} -ne 0 ]] && printf '%s\n' "${OUTPUT}"

SESSION_NC=$(printf '%s' "${OUTPUT}" | grep 'Session ID:' | head -1 | awk '{print $NF}')
USER_NC=$(printf '%s' "${OUTPUT}" | grep 'Account:' | head -1 | awk '{print $NF}')

id "${USER_NC}" &>/dev/null && pass "Agent account created (no-CA): ${USER_NC}" || fail "Agent account not found (no-CA)"

AK_HOME=$(getent passwd "${USER_NC}" 2>/dev/null | cut -d: -f6)
AK_FILE="${AK_HOME}/.ssh/authorized_keys"
assert_file_exists "authorized_keys file created" "${AK_FILE}"

AK_CONTENT=$(cat "${AK_FILE}" 2>/dev/null)
assert_grep "authorized_keys has expiry-time" "expiry-time" "${AK_CONTENT}"
assert_grep "authorized_keys has restrict option" "restrict" "${AK_CONTENT}"
assert_grep "authorized_keys has force-command" "command=" "${AK_CONTENT}"

if command -v lsattr &>/dev/null; then
  ATTRS=$(lsattr "${AK_FILE}" 2>/dev/null | awk '{print $1}')
  printf '%s' "${ATTRS}" | grep -q 'i' && \
    pass "authorized_keys is immutable (chattr +i)" || \
    skip "authorized_keys not immutable (chattr may not be supported on this fs)"
else
  skip "lsattr not available — cannot verify immutability"
fi

section "5. Support Shell — Command Dispatch Tests"

if [[ ! -f "${SHELL_PATH}" ]]; then
  fail "Cannot test command dispatch — shell not found"
else
  dispatch_test "${SHELL_PATH}" "uptime"                                  "'uptime' allowed and executed"          allowed
  dispatch_test "${SHELL_PATH}" "hostname"                                "'hostname' allowed and executed"        allowed
  dispatch_test "${SHELL_PATH}" "cat /etc/passwd | grep root"             "pipe '|' blocked"                      blocked_meta
  dispatch_test "${SHELL_PATH}" "uptime; whoami"                          "semicolon ';' blocked"                  blocked_meta
  dispatch_test "${SHELL_PATH}" 'echo $HOME'                              "dollar '\$' blocked"                    blocked_meta
  dispatch_test "${SHELL_PATH}" 'echo `whoami`'                           "backtick blocked"                       blocked_meta
  dispatch_test "${SHELL_PATH}" "/bin/rm -rf /"                           "absolute path command blocked"          blocked_path
  dispatch_test "${SHELL_PATH}" "cat /var/log/../../etc/shadow"           "path traversal (..) blocked"            blocked_traversal
  dispatch_test "${SHELL_PATH}" "rm -rf /"                                "unlisted command 'rm' blocked"          blocked_cmd
  dispatch_test "${SHELL_PATH}" "systemctl enable malicious-service"      "'systemctl enable' blocked in diag"     blocked_cmd
  dispatch_test "${SHELL_PATH}" "systemctl status sshd"                   "'systemctl status' allowed"             allowed
  dispatch_test "${SHELL_PATH}" ""                                        "empty command shows help"               restricted_help
  dispatch_test "${SHELL_PATH}" $'uptime\nwhoami'                         "newline injection blocked"              blocked_newline

  if [[ -f /var/log/syslog ]]; then
    dispatch_test "${SHELL_PATH}" "head -1 /var/log/syslog" "/var/log/ path allowed" allowed
  elif [[ -f /var/log/messages ]]; then
    dispatch_test "${SHELL_PATH}" "head -1 /var/log/messages" "/var/log/ path allowed" allowed
  else
    skip "No /var/log/syslog or /var/log/messages to test path validation"
  fi

  dispatch_test "${SHELL_PATH}" "cat /etc/shadow" "/etc/ path blocked in diagnostic" blocked_cmd
fi

section "6. grant-access.sh — Input Validation"

RESULT=$(bash "${SCRIPT_DIR}/grant-access.sh" 2>&1); RC=$?
[[ ${RC} -ne 0 ]] && assert_grep "Rejects missing --host" "host.*required|Usage" "${RESULT}" || fail "Did not reject missing --host"

RESULT=$(bash "${SCRIPT_DIR}/grant-access.sh" --host x --duration "abc" 2>&1); RC=$?
assert_exit "Rejects invalid duration 'abc'" 1 "${RC}"

RESULT=$(bash "${SCRIPT_DIR}/grant-access.sh" --host x --duration "10" 2>&1); RC=$?
[[ ${RC} -ne 0 ]] && assert_grep "Rejects too-short duration (10s)" "at least" "${RESULT}" || fail "Accepted too-short duration"

RESULT=$(bash "${SCRIPT_DIR}/grant-access.sh" --host x --allow hacker 2>&1); RC=$?
assert_exit "Rejects invalid profile 'hacker'" 1 "${RC}"

RESULT=$(bash "${SCRIPT_DIR}/grant-access.sh" --host x --agent-pubkey /nonexistent 2>&1); RC=$?
assert_exit "Rejects nonexistent pubkey path" 1 "${RC}"

assert_grep "--help shows usage" "Usage" "$(bash "${SCRIPT_DIR}/grant-access.sh" --help 2>&1)"

assert_grep "grant-access.sh handles missing scheduler" "No scheduler available|WARNING.*scheduler|at.*systemd" \
  "$(grep -A2 'command -v at.*command -v systemd' "${SCRIPT_DIR}/grant-access.sh" 2>/dev/null || \
    grep 'No scheduler available' "${SCRIPT_DIR}/grant-access.sh" 2>/dev/null)"

section "7. revoke-access.sh — Revoke First Session"

printf '  Revoking session: %s (user: %s)\n' "${SESSION_CA}" "${USER_CA}"
OUTPUT=$(bash "${SCRIPT_DIR}/revoke-access.sh" --session "${SESSION_CA}" 2>&1); EXIT_CODE=$?
assert_exit "revoke-access.sh exited 0" 0 "${EXIT_CODE}"
[[ ${EXIT_CODE} -ne 0 ]] && printf '%s\n' "${OUTPUT}"

! id "${USER_CA}" &>/dev/null 2>&1 && pass "Account removed: ${USER_CA}" || fail "Account still exists: ${USER_CA}"
assert_file_missing "Support shell removed" "${SHELL_PATH}"
assert_file_missing "Cleanup script removed" "${CLEANUP_PATH}"
assert_file_missing "Session private key destroyed" "${KEY_PATH}"

grep -q "SESSION_REVOKED.*${SESSION_CA}" /var/log/agent-support.log 2>/dev/null && \
  pass "SESSION_REVOKED logged" || fail "SESSION_REVOKED not found in log"

[[ -f "/var/log/agent-support-archive/${SESSION_CA}.log" ]] && \
  pass "Session log archived" || skip "Session log not archived (may have no matching entries)"

section "8. revoke-access.sh — Revoke All"

OUTPUT=$(bash "${SCRIPT_DIR}/revoke-access.sh" --all 2>&1); EXIT_CODE=$?
assert_exit "revoke-access.sh --all exited 0" 0 "${EXIT_CODE}"

REMAINING=$(getent passwd 2>/dev/null | grep '^agent_support_' | wc -l)
[[ "${REMAINING}" -eq 0 ]] && pass "All agent accounts removed" || fail "${REMAINING} agent account(s) still exist"

section "9. revoke-access.sh — Input Validation"

RESULT=$(bash "${SCRIPT_DIR}/revoke-access.sh" 2>&1); RC=$?
assert_exit "Rejects no arguments" 1 "${RC}"

assert_grep "--help shows usage" "Usage" "$(bash "${SCRIPT_DIR}/revoke-access.sh" --help 2>&1)"

section "10. Duration Boundary Tests"

for dur_test in "30m:30m duration accepted" "1d:1d duration accepted"; do
  dur="${dur_test%%:*}"
  desc="${dur_test#*:}"
  OUTPUT=$(bash "${SCRIPT_DIR}/grant-access.sh" --host x.local --duration "${dur}" 2>&1)
  if [[ $? -eq 0 ]]; then
    SID=$(printf '%s' "${OUTPUT}" | grep 'Session ID:' | head -1 | awk '{print $NF}')
    pass "${desc}"
    bash "${SCRIPT_DIR}/revoke-access.sh" --session "${SID}" >/dev/null 2>&1
  else
    fail "${desc}"
  fi
done

OUTPUT=$(bash "${SCRIPT_DIR}/grant-access.sh" --host x.local --duration 25h 2>&1)
if [[ $? -eq 0 ]]; then
  SID=$(printf '%s' "${OUTPUT}" | grep 'Session ID:' | head -1 | awk '{print $NF}')
  printf '%s' "${OUTPUT}" | grep -qi "WARNING.*24 hours" && \
    pass "25h duration accepted with warning" || fail "25h duration accepted without warning"
  bash "${SCRIPT_DIR}/revoke-access.sh" --session "${SID}" >/dev/null 2>&1
else
  fail "25h duration rejected"
fi

section "11. Full Profile Test"

OUTPUT=$(bash "${SCRIPT_DIR}/grant-access.sh" --host x.local --duration 1h --allow full 2>&1)
if [[ $? -eq 0 ]]; then
  pass "Full profile accepted"
  SID_FULL=$(printf '%s' "${OUTPUT}" | grep 'Session ID:' | head -1 | awk '{print $NF}')
  assert_file_missing "Full profile: no support shell (unrestricted)" "/usr/local/bin/agent-support-shell-${SID_FULL}"
  bash "${SCRIPT_DIR}/revoke-access.sh" --session "${SID_FULL}" >/dev/null 2>&1
else
  fail "Full profile rejected"
fi

section "RESULTS"

printf '\n===========================================\n'
printf '  PASS: %d\n  FAIL: %d\n  SKIP: %d\n  TOTAL: %d\n' "${PASS}" "${FAIL}" "${SKIP}" "$((PASS + FAIL + SKIP))"
printf '===========================================\n'

if [[ ${FAIL} -eq 0 ]]; then
  printf '  All tests passed.\n'
  exit 0
else
  printf '  %d test(s) failed.\n' "${FAIL}"
  exit 1
fi
