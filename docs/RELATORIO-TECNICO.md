# Relatório técnico — Infraestrutura, DevOps e Automação

> Documento 100% anonimizado. Todos os nomes de empresa, sistemas internos, ERP,
> hosts, IPs, portas de produção, usuários e credenciais foram substituídos por
> nomes genéricos (`app-server`, `edge-node`, `store-NN`, `erp-db`, `example.internal`).
> Os números de escala são aproximados e servem só para dar uma ideia do tamanho.

**Contexto do ambiente:** rede de varejo com ~80 filiais (`store-01..store-NN`), um
centro de distribuição (`dc-site`), um escritório central e ~400 estações Windows.
Infra híbrida: um host Linux de homologação/apps internos (`app-server`), um segundo
host Linux com containers de integração (`int-server`), hipervisores (VMware ESXi e
Hyper-V), ambiente Active Directory corporativo, um ERP com banco
SQL Server central (`erp-db`), robôs Windows (fiscais e de integração) e uma ITSM
open source (GLPI).

---

## 1. Mapa de stack e tecnologias

### 1.1 Sistemas operacionais e administração

| Área | O que foi usado na prática |
|---|---|
| **Linux (Debian/Ubuntu)** | Administração por SSH com chave, `sudo -S` só para operações pontuais, `crontab` de usuário, `apt` (ffmpeg, utilitários), `/etc/docker/daemon.json`, análise de disco (`df`, `du`), inspeção de processo (`/proc/<pid>/status`), timezone (`tzdata`, `TZ`) |
| **systemd** | Leitura de estado (`systemctl --failed`, `--state=running`) para monitoramento remoto; units/timers como alternativa a cron |
| **SSH** | Chave ed25519 restrita a um único usuário; impressão digital *pinada* no primeiro acesso (TOFU) no coletor de monitoramento; comandos remotos fixos e só-leitura |
| **Windows Server / Workstation (10/11)** | Serviços com **NSSM**, Agendador de Tarefas (gatilho único, AtLogOn, RunLevel Highest, conta SYSTEM), WinRM/PowerShell Remoting (`TrustedHosts`, `Invoke-Command`), `quser`/`msg`/`logoff` remotos em RDS, `icacls`/`takeown` por **SID** (independente de idioma), DPAPI para guardar credencial local |
| **Active Directory** | Levantamento só-leitura (`[adsisearcher]`), contas de serviço com permissão delegada mínima, `logonHours`, expiração de conta, desativação automática fora da janela autorizada; proposta de gMSA + JEA |
| **Registro / Políticas** | Políticas HKLM de navegador (`URLBlocklist`/`URLAllowlist`, `DnsOverHttpsMode`), `Dnscache\EnableAutoDoh`, política do Firefox (`WebsiteFilter`, `DNSOverHTTPS`); reversão limpa das chaves criadas |
| **Microsoft Defender / EDR** | Gestão de exclusões (`Add/Remove-MpPreference`), leitura de eventos 5007 (Tamper Protection), convivência com EDR comercial em modo ativo |
| **Hipervisores** | VMware ESXi 5.5 (API SOAP `vim25`, TLS legado), Hyper-V (`Get-VM`), VMs de homologação |

### 1.2 Containers, deploy e rede

| Área | O que foi usado na prática |
|---|---|
| **Docker / Docker Compose** | ~15 containers num mesmo host sem conflito: inventário de portas antes de cada deploy, projetos Compose isolados, volumes nomeados, Postgres próprio por app ligado só em `127.0.0.1`, serviço `migrate` *one-shot* antes de `app`/`worker`, `restart: unless-stopped`, `docker builder prune` para recuperar disco |
| **Rede Docker** | Reconfiguração de `bip` e `default-address-pools` para tirar as bridges de faixas `172.16–31.x` que colidiam com a rede das filiais |
| **Deploy** | `git archive <commit> \| ssh host 'tar -x -C <dir>'` (sem deploy key no servidor), scripts idempotentes (checa disco, gera segredos, builda, espera *health*), deploy parcial por arquivo, rollback por imagem anterior + tarball |
| **TLS / mTLS** | Painel com TLS autoassinado e agentes autenticados por certificado de cliente (PKI própria em volume), WebSocket seguro (`wss://`), close code **1012** para reinício gracioso do servidor sem tempestade de reconexão |
| **WebSockets** | Canal persistente agente ↔ painel, reconexão com *backoff* e *jitter* |
| **Rede corporativa** | MikroTik (porta de gerência, API), dois links de internet com detecção de link ativo, controlador UniFi (APs, clientes, RSSI, canais), APs de outro fabricante via API REST, SMB legado e SMB2/3, RTSP/ISAPI de DVRs |
| **Acesso remoto** | RDS (RDP) com controle de sessão por script; servidor RustDesk próprio |

### 1.3 Linguagens e scripting

| Linguagem | Uso |
|---|---|
| **Bash** | Deploy, backup, healthcheck, helpers de operação na VPS |
| **PowerShell 5.1** | Agentes de observação, recuperação de ACL, desinstalação fora da árvore do serviço, inventário (serviços, Hyper-V, backups, discos), RPA de programa desktop, AD |
| **Python** | Agente Windows empacotado com PyInstaller, painel FastAPI, clientes de DVR (HTTP digest, JSON-RPC, protocolo binário), SMB, Fernet |
| **Node.js / TypeScript** | Next.js + Prisma (dashboards e workers), `mssql`, `ssh2`, `imapflow`/`mailauth`, `sharp` |
| **SQL** | SQL Server (DMVs, `msdb`, Extended Events, `#temp`, `TABLOCKX`), PostgreSQL, SQLite, MySQL (leitura) |

### 1.4 Observabilidade, backup, ITSM e automação

- **Observabilidade própria** (worker + dashboard): checagem HTTP/TCP/ping, SSH só-leitura, SQL Server via DMVs, Wi-Fi, ESXi, *health checks* de APIs, status pages públicas, feed de vulnerabilidades (NVD 2.0, CISA KEV, EPSS).
- **Alertas**: e-mail SMTP (STARTTLS) + WhatsApp via gateway HTTP interno, envio em lote, janela de silêncio, regra de espera mínima, aviso de "voltou ao normal".
- **Backup**: monitoramento de Windows Server Backup, Veeam, Cobian e NAS; dump de Postgres; histórico de backup no `msdb`.
- **ITSM**: GLPI (API REST, ações automáticas/cron, templates de notificação, plugin de formulários), Kanboard self-hosted (API JSON-RPC, tema CSS e plugin PHP).
- **Segurança de e-mail**: verificação DKIM/SPF/DMARC no código, antivírus ClamAV em container (scan INSTREAM em memória).
- **Assinatura de código**: atualização de agente só com assinatura RSA-SHA256.

---

## 2. Inventário de projetos, automações e implantações

> Status: ✅ em produção/homologação ativa · 🧪 validado em homologação · 🗄️ descomissionado

### 2.1 Agente de endpoint + painel central de frota (🗄️ após ciclo completo)

- **Problema:** não havia como inventariar, comandar ou restringir navegação nas estações de forma central; tudo era feito máquina a máquina.
- **Arquitetura:**
  - Agente Windows em Python empacotado com PyInstaller, rodando como serviço via **NSSM**, com tarefa agendada "guardiã" que religa o serviço.
  - Painel FastAPI + PostgreSQL 16 em Docker Compose; agentes conectam por `wss://` com **certificado de cliente** emitido no *enrollment*.
  - **Auto-update** em ondas: o agente compara a versão com `latest_version.txt`, aplica *jitter* de 0–15 min, tem *kill switch* por arquivo (`PAUSE_AUTO_UPDATE`) e rollback para o binário anterior se o novo não ficar legível ou não conectar.
  - **Filtro DNS por categoria** (31 categorias, ~1.200 palavras-chave): proxy DNS local em `127.0.0.1:53`, índice compilado e cache (de 1,3 ms para 138 µs por consulta, ~238 mil consultas/s com cache), pool fixo de workers, resposta por tipo de registro (A→`0.0.0.0`, AAAA→`::`, demais→NODATA), lista de domínios que nunca são bloqueados (bancos, meios de pagamento, governo, SSO, atualizações), bloqueio de DoH nos navegadores, detecção de VPN pelo nome do adaptador de rede.
  - **RBAC** no painel: papel `admin`/`operator`, escopo por tipo de local e permissões por função, tudo validado **no servidor** (o painel só esconde botões por conveniência).
  - Ferramenta de **reinstalação limpa** (`ReinstallAgent.exe`) para recuperar máquinas travadas: remove serviço, tarefas, regras de DNS e hosts, políticas de registro e exclusões do Defender e só então reinstala, sem interação (variáveis de ambiente para deploy em massa).
- **Resultado:** rollout de versão 6/6 máquinas online convergindo, sem rollback e sem máquina perdida; reinstalação limpa com ~40 s de indisponibilidade; reinício do servidor com reconexão dos agentes em 3–7 s (antes iam até 60 s de *backoff*). No fim do ciclo o sistema foi **descomissionado de forma controlada**: código conferido e sincronizado com o repositório, remoção remota nas máquinas online, containers, volumes e backups apagados, projetos arquivados.

### 2.2 Host Linux multi-aplicação de homologação (✅)

- **Problema:** várias aplicações internas precisavam de ambiente estável fora do notebook de desenvolvimento (um banco de dev embutido travava a cada 20–30 min e apagava formulários em uso).
- **Passos executados:**
  - Inventário de portas ocupadas antes de cada stack nova; cada app com projeto Compose, rede e volumes próprios.
  - Postgres de cada app em container próprio publicado só em `127.0.0.1`.
  - Script de deploy idempotente: confere espaço livre (≥3 GB), gera segredos na primeira execução, builda, sobe e espera `GET /api/health` responder `{"status":"ok","db":"ok"}`.
  - `CMD` do container roda `migrate deploy` + seed idempotente antes do `start`.
  - Imagem com `tzdata` + `TZ` local (o host estava em UTC e quebrava regras de horário comercial).
  - `.gitattributes` com `eol=lf` (script com CRLF quebrava `set -euo pipefail`).
  - Limpeza recorrente de build cache: o disco chegou a 95% (14,5 GB de cache recuperável).
- **Resultado:** 5+ aplicações (recrutamento, monitoramento, CFTV, quadro Kanban, painel de frota) rodando no mesmo host sem conflito de porta, rede ou banco; deploy reproduzível em minutos.

### 2.3 Plataforma de monitoramento operacional (✅)

Começou como um monitor de filas de replicação entre a matriz e as filiais e virou o "painel de operação" da TI.

- **Problema:** a replicação de dados matriz↔filial travava em silêncio (um registro com dado inválido segurava a fila) e ninguém sabia até a filial reclamar.
- **Arquitetura:** Next.js + Prisma; `worker` separado do `app`; leitura **só-leitura** no SQL Server do ERP com usuário restrito; histórico próprio em SQLite.
- **Pontos técnicos:**
  - Heurística com vários sinais: erro explícito, tempo desde a última conexão, idade do registro pendente mais antigo e tendência da fila. Separa *alta demanda* de *travada*.
  - **Limite aprendido** por filial e por fila (mediana dos picos diários de 14 dias × 1,3; o valor configurado vale como piso).
  - **Perfil de venda por filial** (dia da semana × hora, 8 semanas) para saber se a loja deveria estar aberta, em vez de um horário comercial fixo.
  - Alertas por e-mail + WhatsApp com **reenvio em lote global** (antes cada alerta reenviava no próprio relógio), silêncio das 22h às 6h, espera mínima de 10 min, aviso de "normalizado".
  - Aba de **infraestrutura**: mapa de dependências ("roda em"), causa raiz só quando a máquina está inalcançável, SSH só-leitura em servidores Linux (`docker ps -a`, `systemctl --failed`, `df`, `free`, `loadavg`) com senha cifrada e impressão digital pinada.
  - **Saúde do SQL Server** via DMVs (bloqueios, deadlocks/hora, esperas, discos, CPU, backups no `msdb`, jobs que deixaram de rodar), com a permissão `VIEW SERVER STATE` concedida no lugar de um papel mais amplo.
  - **Wi-Fi do CD**: leitura de APs e clientes (RSSI, canal, largura), detecção de APs fora do controlador anunciando as mesmas SSIDs no mesmo canal.
  - **Serviços externos**: status pages públicas, teste de alcance, notícias de queda (RSS) filtradas por termos de interrupção; só avisa sobre serviços realmente usados.
  - **Vulnerabilidades**: NVD 2.0 incremental, CISA KEV e EPSS cruzados com um catálogo de ~50 tecnologias em uso (CPE = confirmado, regex = provável).
  - **Agente PowerShell** nas máquinas de robôs: processos com janela, caixas de erro (via `EnumWindows`/`WM_GETTEXT`), WerFault, serviços, logs (lidos com `FileShare.ReadWrite`), Hyper-V, eventos de backup, CPU/memória/disco; auto-update **só com assinatura RSA-SHA256**.
- **Resultado (antes → depois):**
  - Travas de replicação: descobertas pela reclamação da filial → detectadas em ~5 min (erro) ou dentro do limite configurado (trava silenciosa).
  - Volume de alerta: 80+ e-mails/dia → 1 resumo por ciclo, reenvio de hora em hora, sem alerta falso de madrugada.
  - Dashboard: TTFB de 4,5–6,8 s → 0,05–0,1 s (85 queries por loja disparadas em paralelo substituídas por agregação).

### 2.4 Robô de retransmissão fiscal em contingência (✅)

- **Problema:** notas fiscais de consumidor emitidas em contingência eram retransmitidas à mão várias vezes por dia num programa desktop legado; a tarefa agendada antiga nunca funcionou.
- **Passos:**
  - Engenharia reversa dos parâmetros de linha de comando do programa (achado o parâmetro de banco que faltava e fazia a tarefa antiga falhar).
  - `ciclo.ps1` contínuo com mutex global: passadas seguidas até a fila estabilizar; janela dinâmica de datas vinda da API do monitor.
  - **Salvaguardas de RPA**: detecta janela de erro (`#32770`/`TMessageForm`), WerFault e "Não respondendo" só quando o log também parou; mata e reabre até N vezes; nunca abre o log enquanto o programa grava (o *logger* dele exige acesso exclusivo e travava).
  - Parâmetros de tempo servidos pelo painel, o que permite ajustar sem recopiar o script.
  - Abertura automática do chamado diário no portal do fornecedor (OAuth/IdentityServer), com deduplicação por venda.
  - Inventário e aviso de vencimento dos certificados digitais (A1) da máquina.
- **Resultado:** processo manual de 3–4 vezes por dia → contínuo e sem intervenção; fila pendente de ~200 vendas (10 dias) → só as do dia; o chamado ao fornecedor sai sozinho e sem repetir venda.

### 2.5 Orquestrador de extração de imagens de CFTV (✅ cadastro e motores HTTP · 🧪 legado)

- **Problema:** cada pedido de imagem exigia achar o DVR da filial, a senha, baixar o vídeo no app do fabricante e subir manualmente.
- **Passos:**
  - FastAPI + SQLite + senhas cifradas com **Fernet**; configurações de negócio editáveis no painel e só segredos de infra em variável de ambiente.
  - Clientes de DVR: ISAPI (busca e download em XML, digest auth) e JSON-RPC com *challenge* MD5 em duas etapas; download com **teto de tempo total** (o `timeout` da lib só cobre o intervalo entre pacotes, então um download lento travava o processo).
  - Importação em massa: migração controlada e somente leitura do inventário local de dispositivos, preservando credenciais no contexto seguro do sistema sem tentativas repetidas contra os equipamentos (evita bloqueio de conta).
  - Para equipamentos sem senha legível: IPs descobertos pelas conexões TCP ativas do software (`Get-NetTCPConnection` por PID).
  - Varredura de conectividade da frota e sincronização de nomes de câmera.
  - Entrega em storage de rede SMB legado (exigiu suporte a protocolo de compatibilidade).
  - Integração com a ITSM: formulário com uma pergunta de câmera por filial, condicionada ao login da filial, gerada por script idempotente.
- **Resultado:** 83 DVRs e 1.118 câmeras cadastrados automaticamente; 50/83 prontos para extração via API e o restante classificado por motivo (firmware legado ou senha divergente).

### 2.6 Liberação de acesso temporário de fornecedor (✅ homologação)

- **Problema:** contas de acesso remoto do fornecedor do ERP ficavam habilitadas para sempre, sem expiração e sem horário, e a liberação era feita à mão a partir de e-mail.
- **Arquitetura:**
  - Leitura IMAP da caixa de pedidos, sem marcar como lida.
  - Verificação DKIM/SPF/DMARC no código; anexos escaneados pelo ClamAV em container.
  - Análise do `.docx`/`.doc`: assinatura do arquivo, *zip bomb*, macros, ActiveX, objetos embutidos e modelo externo.
  - O robô valida o ticket no portal do fornecedor e cria o registro no formulário do ERP (`INSERT` com permissão mínima).
  - Agente PowerShell no domínio, com conta de serviço que só escreve no pool de contas: aplica senha, expiração = fim da liberação, `logonHours` seg–sex 08–18, avisa o usuário na sessão RDS 60/30/5 min antes e faz *logoff* no corte.
  - Travas: banco vazio ou com erro = não faz nada; mais de 3 habilitações num ciclo = não habilita.
  - Pedidos fora do expediente viram enquete no WhatsApp para aprovação humana.
- **Resultado:** 14 contas sempre ligadas → ligadas só durante a janela autorizada; sessões fora do horário derrubadas automaticamente; cada liberação deixa trilha de auditoria.

### 2.7 Recuperação de notificações da ITSM (✅)

- **Problema:** nenhum e-mail saía havia 7 semanas (~16 mil na fila) e ~109 mil chamados estavam parados em "Solucionado".
- **Passos:**
  - Diagnóstico: as ações automáticas estavam presas em "Executando" no modo CLI, sem cron do sistema depois de uma migração de URL.
  - Fila antiga descartada em lotes (limite de `max_input_vars`) e modo de execução corrigido.
  - Backlog encerrado **em silêncio**: e-mail desligado, data de corte da pesquisa de satisfação ajustada, tarefa de fechamento executada em ciclos.
  - Novos templates (último acompanhamento público, bloco de solução e aviso de fechamento automático), com backup do template antigo.
  - Cron paliativo a partir de outro host (`curl .../cron.php` 2×/min), porque não havia acesso SSH ao servidor da ITSM.
- **Resultado:** e-mail voltou com entrega em ~1 min; backlog de 109.536 → 675 sem disparar nenhum e-mail em massa.

### 2.8 Quadro de projetos self-hosted (✅)

Kanboard em Docker (SQLite em bind-mount), API JSON-RPC para popular 20+ projetos a partir dos repositórios, tema CSS corporativo via configuração (com reversão em um comando), plugin PHP de painel por usuário. Achado: a CSP padrão bloqueia `<script>` inline, por isso a customização foi feita por CSS e plugin.

### 2.9 Levantamentos só-leitura (✅)

- **AD e onboarding:** DC único em versão sem suporte, usuários sem atributos (e-mail/departamento), contas e máquinas sem logon há mais de 90 dias, ausência de LAPS e GPOs que só bloqueiam USB.
- **Agente de terceiros na rede:** servidor de desenvolvimento exposto na internet, agente rodando como SYSTEM e *stack trace* com caminhos internos nas respostas de erro. A recomendação foi build de produção e tirar a porta da internet.

---

## 3. Troubleshooting e hardening

| # | Sintoma | Causa raiz | Correção |
|---|---|---|---|
| 1 | Estações com serviço parado e "Acesso negado" até para SYSTEM; a suspeita inicial era o antivírus | `icacls <arquivo> /grant "SID:(OI)(CI)F"` retorna exit 0, mas num **arquivo** as flags de herança deixam a ACE só-herança, ou seja, DACL efetiva vazia. Além disso, `/inheritance:r` seguido de `/grant:r` abre uma janela de DACL vazia em arquivos que estão abertos | `(F)` puro em arquivo, `(OI)(CI)F` só em pasta; `/inheritance:d` (atômico) + `/remove:g`; auto-cura no guardião (`takeown` + `/reset` + grant por SID) antes do `sc start`; rollback se o binário ficar ilegível |
| 2 | `icacls /grant Everyone:...` falha em Windows pt-BR e em máquinas de domínio | Nome de grupo localizado ("Todos") e resolução de nome no AD | **Sempre por SID** (`*S-1-1-0`, `*S-1-5-18`, `*S-1-5-32-544`) + checar o código de retorno |
| 3 | Antivírus reagindo ao agente | O agente adicionava exclusões para binários genéricos do Windows (`powershell.exe`, `cmd.exe`, `certutil.exe`...), o mesmo padrão *living off the land* usado por malware | Exclusões só do próprio binário/pasta; rotina que remove as exclusões perigosas no boot |
| 4 | Desinstalação remota "não pegava" e o guardião restaurava tudo | O script rodava como filho do serviço; `sc stop` matava a árvore inteira antes do resto | Tarefa agendada avulsa (SYSTEM, +45 s), fora da árvore do serviço |
| 5 | Mensagem na tela do usuário "enviada com sucesso" mas nunca aparecia | O endurecimento de ACL também trancou a pasta `temp` de onde saem os scripts da sessão do usuário | Reabrir só `temp\` por SID depois do endurecimento |
| 6 | Filtro DNS "bloqueia, mas no F5 abre" e o navegador fechava sozinho | (a) Resposta sempre tipo A para pergunta AAAA; (b) busca linear O(n) por palavra; (c) **`WSAECONNRESET`** em `recvfrom` UDP depois de um ICMP *port unreachable* matava o loop do servidor | Resposta por QTYPE; índice compilado + cache; `WSAIoctl(SIO_UDP_CONNRESET, FALSE)` + tratar o reset como não fatal; autoteste virou *heartbeat* |
| 7 | Máquina sem DNS depois de reboot com o filtro ativo | Duas inicializações concorrentes gravavam "DNS original = vazio" | Lock, DNS original persistido em disco com *merge* (nunca encolhe) e fallback para DNS público se a interface ficar vazia |
| 8 | Container sem acesso a equipamentos de uma faixa de rede | Bridge `docker0` em `172.17.0.0/16` = mesma faixa da rede das filiais | `daemon.json` com `bip` e `default-address-pools` em `10.x`; religar containers sem política de restart |
| 9 | Download de vídeo "vivo" mas que nunca terminava | `timeout` da lib HTTP só mede o intervalo entre pacotes | Teto de tempo total no laço de stream |
| 10 | Dashboard em produção mostrava sempre a mesma foto | A página foi pré-renderizada estaticamente no build | Forçar renderização dinâmica |
| 11 | `next build` quebrava dentro do Docker | Config de conexão com `throw` montada no *import* do módulo (env só existe em runtime) | Montar a config dentro da função de conexão |
| 12 | Deploy "não pegou" num dos serviços | O serviço `migrate` tinha build próprio e os outros reusavam imagem velha | Imagem única com tag, rebuild dos 3 serviços |
| 13 | Disco do host Docker em 95% | Build cache acumulado | `docker builder prune` + checagem de espaço no script de deploy |
| 14 | Painel com login travando 100% das vezes, sem erro e sem query no banco | Não identificada (o resto do app estava saudável) | Restart do container; o registro serve de referência para casos parecidos |
| 15 | Fila de e-mail da ITSM parada havia semanas | Ação automática presa em "Executando" no modo CLI, sem cron no sistema | Reset de estado + modo interno + cron externo paliativo |
| 16 | E-mail de acompanhamento mostrando o acompanhamento mais antigo | O template iterava em ordem crescente com "FIRST 1" | "LAST 1" |
| 17 | Robô de RPA travava o programa fiscal | Leitura do log enquanto o programa gravava com acesso exclusivo | Monitorar só o `LastWriteTime` da pasta e ler o log depois que o programa terminar |
| 18 | Token de agente commitado num repositório | `git add -A` numa pasta com config preenchida | Placeholders + `.gitignore` + `git filter-repo --replace-text` + *force push*; instalador pede o token com `Read-Host -AsSecureString`; agente só aceita update assinado |
| 19 | Assinatura do script do agente quebrava depois do commit | `core.autocrlf` mudava os bytes | `.gitattributes` com `-text` no arquivo assinado |
| 20 | Agente travando a máquina | Varredura recursiva do disco inteiro | Escopo de pastas explícito + limite de profundidade |
| 21 | Coleta de performance por WMI levava ~1 min | `Win32_PerfFormattedData_PerfProc_Process` é lenta | Delta de `Get-Process` |
| 22 | Hipervisor legado recusava conexão | Só fala TLS 1.0 | `minVersion: TLSv1` + `SECLEVEL=0` só nesse cliente |
| 23 | Consulta SQL estourando o timeout | `EXISTS` dentro de agregação + varredura grande | Materializar em `#temp` em duas etapas; pool com timeout longo só para relatórios |
| 24 | Fila de bipes "lenta por Wi-Fi" no CD | Correlação mostrou atraso simultâneo em vários coletores ao mesmo tempo, o que aponta para gargalo no servidor e não no rádio | Evidência entregue com rastreio por evento; Wi-Fi também otimizado (canais sobrepostos, APs fora do controlador) |

**Hardening aplicado em geral:**

- Usuários de banco só-leitura, com *grants* pontuais por tabela ou coluna, em vez de papéis amplos (ex.: `VIEW SERVER STATE` no lugar de papel de leitura de jobs que permite criar jobs).
- Segredos cifrados em repouso (AES-256-GCM / Fernet), *write-only* no painel; a chave mestra só existe em variável de ambiente.
- Enforcement de permissão sempre no servidor; senha nunca exibida, logada ou enviada por chat.
- SSH remoto com comando fixo e só-leitura e impressão digital pinada.
- Updates assinados (RSA-SHA256) e validação de sintaxe antes de substituir o script.
- Janela de silêncio e espera mínima para alertas (evita fadiga).
- ACLs por SID; credenciais locais em DPAPI; pasta do agente acessível só por admin/SYSTEM.

---

## 4. Scripts e templates sanitizados

Estão na raiz deste repositório:

| Arquivo | O que faz |
|---|---|
| `linux/healthcheck-host.sh` | Disco, memória, load, containers parados/unhealthy, units falhas; saída texto ou JSON; webhook opcional |
| `linux/backup-postgres-docker.sh` + `linux/systemd/*` | `pg_dump` de um Postgres em container, checksum, retenção, cópia para fora do host; agendado por systemd timer |
| `linux/docker/daemon.json` | Faixas de rede do Docker fora de `172.16/12` + rotação de log |
| `templates/docker-compose.yml` + `templates/nginx/mtls.conf` | Stack `migrate → app + worker + db` com healthcheck, TZ e proxy reverso com TLS e mTLS opcional |
| `windows/Repair-FileAcl.ps1` | Recupera arquivos e serviços com DACL vazia (playbook do caso #1) |
| `windows/Invoke-OutOfTreeTask.ps1` | Executa manutenção fora da árvore de processos de um serviço (caso #4) |
| `windows/HostWatcher.ps1` + `windows/Sign-Script.ps1` | Agente de observação (serviços, processos, janelas de erro, discos) com envio para API e auto-update assinado |

---

## 5. Repositório de portfólio sugerido

**Nome:** `infra-ops-playbook` (ou `hybrid-infra-automation`)

```
infra-ops-playbook/
├── README.md                  # visão geral, stack, casos em destaque
├── docs/
│   ├── RELATORIO-TECNICO.md   # este documento
│   ├── case-studies/          # 1 arquivo por caso (problema → diagnóstico → correção → resultado)
│   └── diagrams/              # arquitetura em Mermaid/SVG (sem nomes reais)
├── linux/                     # bash, systemd, docker daemon
├── windows/                   # PowerShell: ACL, tarefas, agente
├── templates/                 # compose, nginx/mTLS
└── .github/workflows/lint.yml # shellcheck + PSScriptAnalyzer
```

**Por que funciona como portfólio:** mostra a mesma pessoa resolvendo problemas em Linux, Windows/AD, Docker, rede e banco, sempre com causa raiz documentada e resultado medido. Um CI com `shellcheck` e `PSScriptAnalyzer` prova que os scripts no mínimo passam por lint.

**Sugestão de bullets para o LinkedIn:**

- Projetei e operei agente de endpoint Windows + painel central (FastAPI, PostgreSQL, WebSocket com mTLS) com auto-update em ondas, rollback e *kill switch*; rollout sem perda de máquina.
- Construí plataforma de monitoramento operacional (Next.js, SQL Server DMVs, SSH só-leitura, Wi-Fi, CVE feeds) com alertas por e-mail/WhatsApp; volume de alertas caiu de 80+/dia para resumos de hora em hora e o TTFB do dashboard caiu de 6,8 s para 0,1 s.
- Automatizei a retransmissão de documentos fiscais em contingência (PowerShell + RPA com salvaguardas), eliminando uma rotina manual diária.
- Automatizei o ciclo de vida de contas de acesso de fornecedor no AD (expiração, `logonHours`, *logoff* em RDS) com verificação DKIM/SPF/DMARC e antivírus nos anexos.
- Diagnostiquei a causa raiz de falha em massa de serviços Windows (DACL vazia causada por flags de herança do `icacls` em arquivo) e criei ferramenta de reinstalação limpa e auto-cura.
- Recuperei a fila de notificações da ITSM e encerrei um backlog de 109 mil chamados sem disparo em massa.
