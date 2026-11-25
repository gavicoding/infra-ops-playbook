[🇺🇸 English](README.md) | **🇧🇷 Português**

# 🛠️ infra-ops-playbook: manual de operação de infraestrutura

[![Lint CI](https://github.com/gavicoding/infra-ops-playbook/actions/workflows/lint.yml/badge.svg)](https://github.com/gavicoding/infra-ops-playbook/actions/workflows/lint.yml)
[![Linux / Bash](https://img.shields.io/badge/Linux-Bash-4EAA25.svg)](linux/)
[![PowerShell](https://img.shields.io/badge/Windows-PowerShell-5391FE.svg)](windows/)
[![Docker Compose](https://img.shields.io/badge/Docker-Compose-2496ED.svg)](templates/docker-compose.yml)
[![Nginx mTLS](https://img.shields.io/badge/Nginx-mTLS-009639.svg)](templates/nginx/mtls.conf)
[![Licença: MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-green.svg)](LICENSE)

Scripts, modelos e casos reais do dia a dia de quem cuida de uma infraestrutura mista: **Windows Server e Active Directory, Linux, Docker e Nginx**. Tudo saiu de um ambiente real com cerca de 80 unidades, uns 400 computadores Windows, um banco SQL Server central, robôs de automação e um help desk de código aberto.

Os casos estão **anonimizados**: nenhum nome de empresa, IP, domínio ou senha real aparece aqui.

---

## Para que serve

Para quem é chamado quando algo para: serviço do Windows que não sobe nem como SYSTEM, backup que ninguém confere, rede do Docker batendo com a rede da VPN, agente que demora a voltar depois de reiniciar. Aqui estão os scripts que resolveram esses problemas e o passo a passo de como cada um foi diagnosticado.

## O que você ganha

- **Scripts prontos e revisados automaticamente** (ShellCheck e PSScriptAnalyzer a cada mudança).
- **Modo de simulação** (`-WhatIf`) nos scripts do Windows, para ver o que vai mudar antes de mudar.
- **24 casos reais de solução de problemas**, com sintoma, causa, correção e resultado, em [docs/RELATORIO-TECNICO.md](docs/RELATORIO-TECNICO.md).

---

## Resultados em produção

| Caso | Antes → Depois |
| :--- | :--- |
| **Monitoramento das filas de replicação e da infra** | A trava só era descoberta quando uma unidade reclamava → detectada em cerca de 5 minutos; mais de 80 e-mails por dia → um resumo por hora; o painel passou a abrir em 0,1 s (antes 6,8 s) |
| **Agente para os computadores Windows + painel central com mTLS** | Implantação em ondas, com volta atrás e botão para desligar tudo; reconexão depois de reiniciar o servidor caiu de 60 s para 3 a 7 s |
| **Serviços do Windows falhando em massa ("Acesso negado" até para o SYSTEM)** | Causa: opções de herança do `icacls` aplicadas a **arquivos** deixavam a lista de permissões vazia → reparo automático e reinstalação limpa, com cerca de 40 s fora do ar |
| **Reenvio de notas fiscais emitidas em contingência** | Alguém fazia à mão 3 a 4 vezes por dia → robô contínuo, com limite de tentativas e chamado automático no fornecedor |
| **Contas de fornecedores no Active Directory** | Ficavam habilitadas o tempo todo → só funcionam na janela autorizada (`logonHours`, data de expiração, logoff no RDS), com DKIM/SPF/DMARC e antivírus nos anexos |
| **Fila de e-mails do help desk** | 7 semanas sem nenhum e-mail e 109 mil chamados parados → fila normalizada e chamados antigos encerrados sem disparar e-mail para ninguém |

---

## O que tem no repositório

```text
linux/
  healthcheck-host.sh               confere disco, memória, carga, containers e serviços do systemd (texto ou JSON, com webhook)
  backup-postgres-docker.sh         backup do PostgreSQL em container: pg_dump, teste de integridade, SHA-256, retenção e cópia externa
  systemd/pg-backup.{service,timer} serviço e agendamento do backup no systemd
  docker/daemon.json                tira as redes do Docker da faixa 172.16.0.0/12 para não bater com VPN e redes das unidades
templates/
  docker-compose.yml                migração roda uma vez -> app + worker, PostgreSQL, healthchecks e fuso horário explícito
  nginx/mtls.conf                   HTTPS para o painel e certificado obrigatório (mTLS) para os agentes via WebSocket
windows/
  Repair-FileAcl.ps1                recupera pastas e serviços com permissões vazias, usando SID (funciona em qualquer idioma do Windows)
  Invoke-OutOfTreeTask.ps1          roda uma manutenção fora da árvore de processos de um serviço
  HostWatcher.ps1                   agente de observação com token protegido (DPAPI) e atualização automática assinada
  Sign-Script.ps1                   assina as atualizações do HostWatcher.ps1 (RSA-3072 / SHA-256), fora da rede
```

---

## Tecnologias

- **Linux e containers:** Debian/Ubuntu, serviços e timers do `systemd`, SSH endurecido, Docker, Docker Compose, Nginx com TLS/mTLS
- **Windows e virtualização:** Windows Server / 10 / 11, Active Directory, NSSM, Agendador de Tarefas, WinRM, RDS, Defender, DPAPI, permissões por SID, Hyper-V, VMware ESXi
- **Rede e segurança:** MikroTik, UniFi, TLS/mTLS, WebSockets, DNS, SMB, DKIM/SPF/DMARC, ClamAV, alertas de vulnerabilidade (NVD, CISA KEV, EPSS)
- **Linguagens e bancos:** Bash, PowerShell, Python (FastAPI), TypeScript (Next.js, Prisma), SQL (SQL Server, PostgreSQL, SQLite, MySQL)

---

## Como usar

### Linux: checagem de saúde e backup automático do PostgreSQL

```bash
sudo install -m 0755 linux/healthcheck-host.sh /usr/local/bin/
IGNORE_EXITED_REGEX='-migrate-' healthcheck-host.sh --json

sudo install -m 0755 linux/backup-postgres-docker.sh /usr/local/bin/
sudo install -m 0644 linux/systemd/pg-backup.* /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now pg-backup.timer
```

### Windows: manutenção e agente assinado (PowerShell como administrador)

```powershell
# Ver o que o reparo de permissões faria, sem mudar nada (-WhatIf)
.\windows\Repair-FileAcl.ps1 -Path 'C:\Program Files\SampleAgent' -ServiceName SampleAgent -WhatIf

# Rodar uma manutenção fora da árvore de processos do serviço
.\windows\Invoke-OutOfTreeTask.ps1 -ScriptPath .\uninstall.ps1 -DelaySeconds 45
```

---

## Conferência automática

A cada pull request e a cada push:
- **`shellcheck`** (`ubuntu-latest`) revisa todos os scripts Bash de `linux/`;
- **`PSScriptAnalyzer`** (`windows-latest`) revisa todos os scripts PowerShell de `windows/`;
- **`docker compose config`** (`ubuntu-latest`) confere se os modelos de `templates/` são válidos.

---

## Licença

[MIT License](LICENSE). Copyright (c) 2026 Gabriel Souza (`@gavicoding`).
