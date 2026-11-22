# infra-ops-playbook

Infraestrutura híbrida (Linux + Windows/AD + Docker), observabilidade e automação
operacional em um ambiente real de varejo multi-filial: ~80 filiais, um CD, ~400 estações,
ERP com SQL Server central, robôs Windows e ITSM open source.

Este repositório reúne **casos reais anonimizados** (problema → diagnóstico → correção →
resultado) e **scripts/templates reutilizáveis** derivados do que foi usado em produção.
Nenhum nome, IP, domínio ou credencial real aparece aqui.

## Destaques

| Caso | Antes → Depois |
|---|---|
| Plataforma de monitoramento de filas de replicação e infra | trava descoberta pela reclamação da filial → detectada em ~5 min; 80+ e-mails/dia → resumos de hora em hora; TTFB do dashboard 6,8 s → 0,1 s |
| Agente de endpoint Windows + painel com mTLS | rollout em ondas com rollback e *kill switch*; reconexão após restart do servidor 60 s → 3–7 s |
| Falha em massa de serviços Windows ("Acesso negado" até para SYSTEM) | causa raiz: flags de herança do `icacls` aplicadas a **arquivo** = DACL vazia → auto-cura + ferramenta de reinstalação limpa (~40 s de downtime) |
| Retransmissão fiscal em contingência | rotina manual 3–4×/dia → robô contínuo com salvaguardas de RPA e chamado automático ao fornecedor |
| Contas de acesso de fornecedor no AD | sempre habilitadas → só na janela autorizada (`logonHours`, expiração, *logoff* em RDS), com DKIM/SPF/DMARC e antivírus nos anexos |
| Fila de notificações da ITSM | 7 semanas sem e-mail e 109 mil chamados parados → fila normalizada e backlog encerrado sem disparo em massa |

O relatório completo, com stack, inventário de projetos e 24 casos de troubleshooting, está em
[docs/RELATORIO-TECNICO.md](docs/RELATORIO-TECNICO.md).

## Conteúdo

```
linux/
  healthcheck-host.sh          disco, memória, load, containers, systemd; texto/JSON; webhook
  backup-postgres-docker.sh    pg_dump em container + validação + checksum + retenção + offsite
  systemd/pg-backup.{service,timer}
  docker/daemon.json           tira as bridges do Docker de 172.16.0.0/12 (+ README do caso)
templates/
  docker-compose.yml           migrate one-shot -> app + worker, Postgres, healthchecks, TZ
  nginx/mtls.conf              TLS para o painel + mTLS obrigatório para agentes (WebSocket)
windows/
  Repair-FileAcl.ps1           recupera pasta/serviço com DACL vazia (tudo por SID)
  Invoke-OutOfTreeTask.ps1     roda manutenção fora da árvore de processos de um serviço
  HostWatcher.ps1              agente de observação com token DPAPI e auto-update assinado
  Sign-Script.ps1              assina o agente (RSA-SHA256)
```

## Stack

**Linux:** Debian/Ubuntu, systemd, SSH, cron, Docker, Docker Compose, Nginx ·
**Windows:** Server/10/11, Active Directory, NSSM, Agendador de Tarefas, WinRM, RDS, Defender, DPAPI, ACL/SID, Hyper-V ·
**Virtualização:** VMware ESXi, Hyper-V ·
**Rede:** MikroTik, UniFi, TLS/mTLS, WebSocket, DNS, SMB ·
**Linguagens:** Bash, PowerShell, Python (FastAPI), TypeScript (Next.js, Prisma), SQL (SQL Server, PostgreSQL, SQLite, MySQL) ·
**Operação:** GLPI, Kanboard, ClamAV, SMTP, monitoramento de backup, feeds de CVE (NVD, CISA KEV, EPSS)

## Uso rápido

```bash
# Linux
sudo install -m 0755 linux/healthcheck-host.sh /usr/local/bin/
IGNORE_EXITED_REGEX='-migrate-' healthcheck-host.sh --json

sudo install -m 0755 linux/backup-postgres-docker.sh /usr/local/bin/
sudo install -m 0644 linux/systemd/pg-backup.* /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now pg-backup.timer
```

```powershell
# Windows (PowerShell elevado)
.\windows\Repair-FileAcl.ps1 -Path 'C:\Program Files\SampleAgent' -ServiceName SampleAgent -WhatIf
.\windows\Invoke-OutOfTreeTask.ps1 -ScriptPath .\uninstall.ps1 -DelaySeconds 45
```

## Licença

MIT
