# 🔑 sparkey

**Time-limited, self-destructing SSH access for AI agents.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![AgentSkills](https://img.shields.io/badge/AgentSkills-compatible-brightgreen)](https://github.com/anthropics/skills/blob/main/spec/agent-skills-spec.md)
[![ClawHub](https://img.shields.io/badge/ClawHub-sparkey-orange)](https://clawhub.com/skills/sparkey)

> Your AI agent needs SSH access. Static keys are a liability. Sparkey gives it access that expires, restricts, audits, and self-destructs — in that order.

---

## The Problem

When an AI agent needs to diagnose a server, you face a choice: hand it a long-lived SSH key (security nightmare) or manually provision and revoke access every time (operational nightmare).

A leaked SSH key works identically on day one and five years later. There's no built-in expiry, no command restriction, no cleanup. If the agent crashes mid-session, the key lives forever.

Temporary accounts should be time-limited by design, with automated deprovisioning when access is no longer needed. Agents should operate under least privilege — the minimum rights necessary for the task at hand. Static SSH keys satisfy neither requirement.

## The Solution

Sparkey applies the temporary-credential pattern — the same principle behind just-in-time privileged access management and short-lived authentication tickets — to SSH access for AI agents:

- **Expires automatically** — cryptographic certificate TTL with managed credential rotation, not "remember to revoke"
- **Restricts commands** — read-only diagnostics by default, enforcing least privilege at the shell level
- **Leaves no session artifacts** — account, keys, and scripts destroyed after each session
- **Logs everything** — sanitized audit trail of every command, supporting accountability and incident reconstruction
- **Survives agent crashes** — independent dead-man timers clean up even if the agent never comes back

---

## Defense in Depth

Four independent layers enforce access control. Each fails safe on its own — a vulnerability in one layer does not bypass the others. Controls are deployed at multiple independent enforcement points to eliminate single points of failure.

<picture>
  <img src="diagrams/sparkey_defense_in_depth.svg" alt="Four-layer defense in depth" width="680">
</picture>

| Layer | Mechanism | Enforcement Point |
| ----- | --------- | ----------------- |
| **1. Certificate TTL** | `ssh-keygen -V +Nh` | Server-side — cryptographic rejection of expired certs, unforgeable |
| **2. OS Account Expiry** | `useradd --expiredate` | Kernel-level — login denied regardless of valid credentials |
| **3. Command Dispatch** | Exact `case` match, `readlink -f` path validation, no `eval` | Application-level — unlisted commands rejected before execution |
| **4. Scheduled Cleanup** | `at` / `systemd-run` dead-man timer | Scheduler-level — fires independently of agent process lifecycle |

---

## Access Lifecycle

<picture>
  <img src="diagrams/sparkey_access_lifecycle.svg" alt="Access lifecycle — request through cleanup" width="680">
</picture>

---

## Quick Start

```bash
# One-time: create Certificate Authority on your operator host
sudo bash scripts/setup-ca.sh

# Preview what will happen (no changes made)
sudo bash scripts/grant-access.sh \
  --host myserver.example.com \
  --duration 4h \
  --agent-pubkey /path/to/agent.pub \
  --dry-run

# Grant 4-hour diagnostic access
sudo bash scripts/grant-access.sh \
  --host myserver.example.com \
  --duration 4h \
  --agent-pubkey /path/to/agent.pub

# Revoke immediately if needed
sudo bash scripts/revoke-access.sh --session SESSION_ID

# Scan for any orphaned artifacts from previous sessions
sudo bash scripts/audit.sh
```

---

## Command Profiles

| Profile | Scope |
| ------- | ----- |
| `diagnostic` *(default)* | Read logs, check service status, view metrics, network diagnostics. Read-only — no state changes. |
| `remediation` | Diagnostic scope + restart services, edit configs, manage Docker containers. Write access to `/etc/`, `/var/`, `/tmp/`. |
| `full` | Unrestricted shell. Bypasses Layer 3 — use only when the task cannot be scoped to a profile. |

The agent's effective permissions are the intersection of the OS account, the certificate options, and the dispatch shell allowlist. No single layer grants more than the others permit.

---

## Security Controls

| Control | How |
| ------- | --- |
| No `eval` | Commands dispatched directly as `"$COMMAND" "${ARGS[@]}"` — no shell interpretation |
| No prefix matching | Exact command-name match via `case` — `systemctl status` allowed, `systemctl enable` denied |
| Metacharacter blocking | `;` `\|` `&` `$` `` ` `` `()` `{}` `<>` `\` rejected before any parsing |
| Path restriction | Arguments validated against directory allowlists; symlinks resolved via `readlink -f` before comparison |
| Log sanitization | `printf '%q'` escaping prevents injection into the audit trail |
| Session isolation | Per-session dispatch shell and cleanup timer — no cross-session interference |
| Real-time observability | Shared `screen`/`tmux` session lets the operator watch the agent work live |
| Crash safety | `expiry-time` (OpenSSH 8.2+) and `at` timer fire independently of the agent process |

No data leaves the machine. No telemetry. No analytics. No external endpoints. All operations are local to the operator and target hosts.

---

## Installation

### From ClawHub

```bash
clawhub install sparkey
```

### Manual

```bash
git clone https://github.com/sanjeevneo/sparkey.git \
  /path/to/your/skills/sparkey
```

### Requirements

Linux with standard user-management tools. Scripts check dependencies at startup and report what to install:

```bash
# Debian/Ubuntu
sudo apt-get install -y openssh-client coreutils passwd at e2fsprogs procps

# Alpine
apk add openssh-keygen bash shadow coreutils util-linux procps at e2fsprogs

# RHEL/Fedora
sudo dnf install -y openssh-clients coreutils shadow-utils at e2fsprogs procps-ng
```

---

## CA Key Lifecycle

The CA private key (`/etc/ssh/agent_ca`) is a persistent operator-side credential — the one thing that intentionally survives sessions. Like any signing authority, compromise allows minting valid certificates for any target that trusts the CA.

**Recommended controls:**
- Run `setup-ca.sh` on a dedicated, hardened operator host — not on target servers
- Restrict to `chmod 400`, root-only access, with file access auditing enabled
- Rotate periodically — `setup-ca.sh` warns after 90 days
- For high-security environments, use an HSM or an air-gapped CA host

Session artifacts — agent accounts, keys, certificates, dispatch shells, cleanup timers — are destroyed on session end or TTL expiry. The CA key is the only credential that persists by design.

---

## Compatibility

Sparkey follows the [AgentSkills open standard](https://github.com/anthropics/skills/blob/main/spec/agent-skills-spec.md) and works with any conforming agent platform. See [SKILL.md](SKILL.md) for the full reference, including the Security Manifest and Trust & Privacy statement.

---

## License

[MIT](LICENSE)
