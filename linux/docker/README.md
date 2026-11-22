# daemon.json - tirar o Docker das faixas 172.16.0.0/12

**Sintoma:** de dentro de um container (ou até do próprio host), equipamentos de algumas
filiais não respondiam, enquanto outros endereços privados da mesma rede respondiam normalmente.
O ponto em comum: os que falhavam estavam em sub-redes dentro de `172.16.0.0/12`.

**Causa:** a bridge padrão `docker0` usa `172.17.0.0/16`, e cada rede Compose nova pega a
próxima faixa `172.18…172.31`. O host passa a ter rota local para essas faixas e envia os
pacotes para a bridge em vez de mandar para o gateway/VPN real.

**Correção:**

```bash
# 1. ver as faixas em uso
docker network inspect $(docker network ls -q) -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}}{{end}}'
ip route | grep -E 'docker|br-'

# 2. aplicar o daemon.json deste diretório
sudo install -m 0644 daemon.json /etc/docker/daemon.json
sudo systemctl restart docker

# 3. containers SEM restart policy não voltam sozinhos - listar e religar
docker ps -a --filter status=exited --format '{{.Names}}' \
  | xargs -r -n1 sh -c 'docker inspect -f "{{.Name}} {{.HostConfig.RestartPolicy.Name}}" "$0"'
```

Notas:

- `bip` e `default-address-pools` só valem para redes **novas**. Redes Compose que já existem
  ficam na faixa antiga até serem recriadas (`docker compose down && up -d`). Recrie só as que
  colidem de verdade com a rede corporativa.
- `log-opts` evita que logs `json-file` encham o disco.
- `live-restore` mantém os containers rodando durante um restart do daemon (não se aplica a
  mudanças de rede).
