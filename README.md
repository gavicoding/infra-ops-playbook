**🇺🇸 English** | [🇧🇷 Português](README.pt-BR.md)

# 🛠️ infra-ops-playbook

[![Lint CI](https://github.com/gavicoding/infra-ops-playbook/actions/workflows/lint.yml/badge.svg)](https://github.com/gavicoding/infra-ops-playbook/actions/workflows/lint.yml)
[![Linux / Bash](https://img.shields.io/badge/Linux-Bash-4EAA25.svg)](linux/)
[![PowerShell](https://img.shields.io/badge/Windows-PowerShell-5391FE.svg)](windows/)
[![Docker Compose](https://img.shields.io/badge/Docker-Compose-2496ED.svg)](templates/docker-compose.yml)
[![Nginx mTLS](https://img.shields.io/badge/Nginx-mTLS-009639.svg)](templates/nginx/mtls.conf)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Hybrid infrastructure (**Linux + Windows/AD + Docker + Nginx mTLS**), observability, and operational automation playbook derived from a multi-branch retail environment (~80 branches, a distribution center, ~400 Windows workstations, central SQL Server ERP, automation bots, and open-source ITSM).

This repository curates **100% anonymized production case studies** (symptom → root cause → fix → measurable impact) alongside **reusable, linted scripts and deployment templates**. No real company names, IPs, domains, or credentials appear anywhere.

---

## Real-World Operational Impact

| Case | Before → After |
| :--- | :--- |
| **Replication & Infrastructure Observability Platform** | Stalled syncs discovered via store complaints → detected in **~5 min**; `80+` emails/day → hourly batched digests; dashboard TTFB **`6.8s → 0.1s`** |
| **Windows Fleet Agent + Central mTLS Control Plane** | Wave-based rollout with rollback & kill switch; post-restart fleet reconnection **`60s → 3–7s`** |
| **Mass Windows Service Failures ("Access Denied" even for `SYSTEM`)** | Root cause: `icacls` inheritance flags applied to **files** yielded empty DACLs → self-healing recovery + clean out-of-tree reinstall (~40s downtime) |
| **Fiscal Contingency Retransmission Automation** | Manual `3–4x/day` interventions → continuous RPA workflow with safety guardrails and automated vendor ticketing |
| **Time-Boxed Vendor Access in Active Directory** | Permanently enabled vendor accounts → restricted strictly to approved windows (`logonHours`, account expiration, RDS session logoff), backed by DKIM/SPF/DMARC & ClamAV attachment scanning |
| **ITSM Notification Queue Recovery** | 7 weeks with zero outbound notifications & 109k stalled tickets → queue normalized and backlog drained without email flooding |

Read the complete 9-project inventory and **24 real troubleshooting cases** in [docs/RELATORIO-TECNICO.md](docs/RELATORIO-TECNICO.md) (Portuguese).

---

## Repository Contents

```text
linux/
  healthcheck-host.sh               Disk, RAM, load, Docker containers & systemd checks (text/JSON + webhook)
  backup-postgres-docker.sh         Containerized pg_dump + integrity verification + SHA-256 + retention + offsite sync
  systemd/pg-backup.{service,timer} Systemd unit & timer templates for scheduled automated backups
  docker/daemon.json                Shifts Docker bridges out of 172.16.0.0/12 to avoid VPN/branch subnet collisions
templates/
  docker-compose.yml                One-shot migration gate -> app + worker, Postgres, healthchecks, explicit TZ
  nginx/mtls.conf                   TLS for web UI + mandatory client-certificate mTLS for WebSocket fleet agents
windows/
  Repair-FileAcl.ps1                Language-agnostic SID-based recovery for folders/services hit by empty DACLs
  Invoke-OutOfTreeTask.ps1          Detached maintenance runner executing outside the service process tree
  HostWatcher.ps1                   Observation agent with DPAPI token storage and RSA-signed auto-updates
  Sign-Script.ps1                   Offline RSA-3072 / SHA-256 signer for HostWatcher.ps1 auto-update payloads
```

---

## Stack Coverage

- **Linux & Containers:** Debian/Ubuntu, `systemd` services & timers, hardened SSH, Docker, Docker Compose, Nginx TLS/mTLS reverse proxy
- **Windows & Virtualization:** Windows Server / 10 / 11, Active Directory, NSSM, Task Scheduler, WinRM, RDS, Defender, DPAPI, SID-based ACLs, Hyper-V, VMware ESXi
- **Networking & Security:** MikroTik, UniFi, TLS/mTLS, WebSockets, DNS, SMB, DKIM/SPF/DMARC, ClamAV, CVE feeds (NVD, CISA KEV, EPSS)
- **Languages & Databases:** Bash, PowerShell, Python (FastAPI), TypeScript (Next.js, Prisma), SQL (SQL Server, PostgreSQL, SQLite, MySQL)

---

## Quick Start

### Linux Host Healthcheck & Automated PostgreSQL Docker Backups

```bash
sudo install -m 0755 linux/healthcheck-host.sh /usr/local/bin/
IGNORE_EXITED_REGEX='-migrate-' healthcheck-host.sh --json

sudo install -m 0755 linux/backup-postgres-docker.sh /usr/local/bin/
sudo install -m 0644 linux/systemd/pg-backup.* /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now pg-backup.timer
```

### Windows Maintenance & Signed Agent Tooling (Elevated PowerShell)

```powershell
# Preview SID-based ACL repair safely with -WhatIf
.\windows\Repair-FileAcl.ps1 -Path 'C:\Program Files\SampleAgent' -ServiceName SampleAgent -WhatIf

# Run maintenance script detached from a service's process tree
.\windows\Invoke-OutOfTreeTask.ps1 -ScriptPath .\uninstall.ps1 -DelaySeconds 45
```

---

## Automated CI Validation

Every Pull Request and push is automatically checked across:
- **`shellcheck`** (`ubuntu-latest`) for all Bash scripts in `linux/`
- **`PSScriptAnalyzer`** (`windows-latest`) for all PowerShell scripts in `windows/`
- **`docker compose config`** (`ubuntu-latest`) for deployment template validity in `templates/`

---

## License

[MIT License](LICENSE) - Copyright (c) 2026 Gabriel Souza (`@gavicoding`).
