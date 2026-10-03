# pkinfra-toolkit

Ferramentas de upgrade, tuning e validação para frota Debian / Proxmox VE.

**Versão do pacote:** 2026.10.03

---

## Instalação

### Remota (uma linha)

```bash
curl -fsSL https://raw.githubusercontent.com/pkthegod/pkinfra-toolkit/main/bootstrap.sh | sudo bash
```

O `bootstrap.sh` descobre o último release, baixa, confere integridade e
chama o `install.sh` de dentro do pacote. Flags passam direto:

```bash
# ver o que faria, sem escrever nada
curl -fsSL .../bootstrap.sh | sudo bash -s -- --dry-run

# versão fixa + digest fixo — é assim que se instala em produção
curl -fsSL .../bootstrap.sh | sudo bash -s -- --version 2026.10.03 --sha256 <hash>

# forçar tudo, independente do papel do host
curl -fsSL .../bootstrap.sh | sudo bash -s -- --all
```

> **Sobre confiar num `curl | bash`.** O `.sha256` publicado ao lado do
> tarball só protege contra download corrompido — quem controlasse o release
> controlaria os dois arquivos. Integridade de verdade vem de fixar o digest
> com `--sha256`, e o valor sai das notas de cada release (ou do seu próprio
> `./build.sh`, que é reproduzível). Em produção, fixe.
>
> **E fixe também o `bootstrap.sh`.** A URL com `/main/` serve sempre a
> versão mais recente do script — conveniente para corrigir o instalador sem
> republicar release, mas significa que a frota executa como root um arquivo
> que pode ter mudado desde a última vez. Para produção, aponte para a tag:
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/pkthegod/pkinfra-toolkit/v2026.10.03/bootstrap.sh \
>   | sudo bash -s -- --version 2026.10.03 --sha256 <hash>
> ```
>
> Assim as duas metades ficam pinadas: o instalador pela tag, o pacote pelo
> digest.

### Manual (tarball do release)

```bash
V=2026.10.03
curl -fsSLO https://github.com/pkthegod/pkinfra-toolkit/releases/download/v$V/pkinfra-toolkit-$V.tar.gz
curl -fsSLO https://github.com/pkthegod/pkinfra-toolkit/releases/download/v$V/pkinfra-toolkit-$V.tar.gz.sha256
sha256sum -c pkinfra-toolkit-$V.tar.gz.sha256

tar xzf pkinfra-toolkit-$V.tar.gz
cd pkinfra-toolkit-$V
sha256sum -c CHECKSUMS.sha256     # confere item por item
./install.sh --dry-run            # ver o que faria
sudo ./install.sh                 # instala conforme o papel detectado
```

O instalador detecta se é host Proxmox ou guest e instala só o que faz
sentido. `--all` força tudo.

### Frota

```bash
for h in $(cat hosts.txt); do
  ssh "$h" "curl -fsSL https://raw.githubusercontent.com/pkthegod/pkinfra-toolkit/main/bootstrap.sh \
            | sudo bash -s -- --version $V --sha256 $HASH"
done
```

---

## Conteúdo

| Arquivo | Versão | Papel |
|---|---|---|
| `bin/pkassess.sh` | 1.0 | **levantamento, benchmark e prescricao — comece aqui** |
| `lib/pkops.sh` | 1.0 | estado, eventos, callbacks, manifest, drift |
| `bin/pve-upgrade.sh` | 3.6.1 | upgrade PVE 6→7→8→9.2 |
| `bin/proxmox_tune.sh` | 3.3.0 | tuning do host PVE — **hipervisor-aware** (firewall, ARC, hugepages) |
| `bin/tune-profile.sh` | 1.0 | tuning de guest — 8 perfis de carga |
| `bin/setup-unbound.sh` | 2.0 | resolvedor recursivo validante |
| `bin/validate.sh` | 2.1 | **valida e testa** o runtime — RED/GREEN, `--deep`, `--json`, `--report` |
| `bin/update-root-hints.sh` | 1.0 | atualiza o `root.hints` sem derrubar o DNS — baixa antes de trocar |
| `bin/deb-release-upgrade.sh` | 1.0 | upgrade de release Debian, **um salto por vez** |
| `docs/TOOLKIT.md` | — | **referência completa** |

Após instalar, tudo fica em `/usr/local/sbin/` e a referência em
`/usr/local/share/pkinfra/TOOLKIT.md`.

---

## Novidades — 2026.10.03

### `pve-upgrade.sh` 3.6.1 — o bloqueio do Ceph explica o caminho

No salto 8→9 com Ceph abaixo do Squid, o script só dizia
`PVE 9 exige Squid 19.2` e parava. Agora mostra os saltos que faltam
(Quincy → Reef → Squid, com o link da wiki do Proxmox de cada um), a ordem
de restart, o critério de pronto (`ceph versions` só com 19.2 e
`HEALTH_OK`) e o alerta para `/etc/pve/ceph.conf` que sobrou de um Ceph que
não está em uso.

## Novidades anteriores

### `proxmox_tune.sh` 3.3.0 — o host tunado como hipervisor

A v3.2 tunava o host PVE como um servidor Linux qualquer. Parte do que ela
fazia custava desempenho às VMs ou falhava sem avisar. Esta versão corrige
isso:

| # | Antes | Agora | Ganho |
|---|---|---|---|
| 1 | `bridge-nf-call-iptables = 1` sempre, `br_netfilter` sempre carregado | Detecta o firewall do PVE (`cluster.fw`). **Desligado:** `0` e sem `br_netfilter`. **Ligado:** as chaves ficam com o `pve-firewall` | Sem firewall, o tráfego bridgeado das VMs deixa de passar pelo iptables e pelo conntrack do host: menos CPU por pacote |
| 2 | `nf_conntrack_tcp_timeout_established = 300` | Default do kernel (5 dias). Com o firewall ligado, `nf_conntrack_max` e esse timeout ficam no `host.fw` | Conexão ociosa de VM (SSH, pool de banco) não morre mais calada depois de 5 min |
| 3 | `--zfs-arc N` abaixo do `zfs_arc_min` era **ignorado** pelo ZFS sem erro (piso default = RAM/32) | Baixa o `zfs_arc_min` junto, grava os dois no `modprobe.d` e confere o `c_max` no `arcstats` | O teto do ARC passa a valer de fato, e a RAM volta para as VMs |
| 4 | `--hugepages` reservava mesmo sem VM consumidora e ignorava o ARC no piso do host | Conta as VMs com `hugepages:` e **recusa** pool sem consumidor (`--force` passa por cima). O ARC entra no piso de 8 GB. Avisa sobre tamanho divergente e sobre balloon junto com hugepages | RAM deixa de ficar travada num pool ocioso e o host não fica sem memória |
| 5 | Só páginas de 2 MB | `--hugepages-size 1G`, com checagem da flag `pdpe1gb` | Menos TLB miss em VM grande (banco, NoSQL) |
| 6 | `facts.env` e `state-<kernel>.env` sem aspas: `Intel(R)` quebrava o `source` (bug 3 de volta) | Todo valor entre aspas | `pve-upgrade.sh --validate` volta a ler o estado do tuning |
| 7 | Checagem de colisão só em `/etc/sysctl.d` | Também em `/run`, `/usr/local/lib` e `/usr/lib/sysctl.d`, onde os pacotes põem os deles | Um conflito com o sysctl do próprio PVE aparece no relatório |
| 8 | Mudar a RAM ou o firewall não refazia o tuning | Os dois entram na assinatura do estado | Cruzar 32 GB (`dirty_ratio` → `dirty_bytes`) ou ligar o firewall re-tuna sozinho |

```bash
proxmox_tune.sh --dry-run --tune-only            # mostra a decisão do firewall
proxmox_tune.sh --zfs-arc 8                      # agora confere se pegou
proxmox_tune.sh --hugepages 32 --hugepages-size 1G
```

> **Ao ligar ou desligar o firewall do datacenter, rode o tuning de novo.**
> A decisão sobre `bridge-nf-call-*` depende dele, e a assinatura detecta a
> mudança.

---

## Início rápido

### Comece sempre por aqui

```bash
pkassess.sh --full     # inventário + benchmark + prescrição com comandos prontos
```

Ele mede quatro eixos (HW, SW, IO, TUNE) e diz o que fazer: atualizar,
tunar, trocar hardware, ou nada. Códigos de saída: `0` sólido · `1` ação ·
`2` alerta · `3` crítico.

### Host Proxmox

```bash
pkops doctor                       # a camada está sã?
pve-upgrade.sh --assess            # score do hardware, decide a versão-alvo
tmux new -s upg                    # obrigatório — o script bloqueia sem
pve-upgrade.sh --apply
# reboot
pve-upgrade.sh --validate
proxmox_tune.sh
```

### Upgrade de release Debian (guest)

```bash
deb-release-upgrade.sh --dry-run      # mostra host resolvido, repos e riscos
deb-release-upgrade.sh                # um salto: bullseye -> bookworm
# reboot
deb-release-upgrade.sh --to trixie    # próximo salto, depois de validar
```

Resolve **por sondagem** onde a release está hospedada — release arquivada vive
em `archive.debian.org`, a próxima em `deb.debian.org`. Um `sed` no codename
produziria `archive.debian.org/debian bookworm`, que não existe, e o `apt
update` só falha depois que o `sources.list` já foi mexido. O script sonda,
faz backup, e reverte sozinho se o `apt update` não passar.

Recusa saltos de mais de uma release (o Debian só suporta N→N+1) e recusa
rodar em host Proxmox — lá o caminho é o `pve-upgrade.sh`, que trata repos do
PVE, ceph e a ordem correta.

### Guest de serviço

```bash
pkops doctor
tune-profile.sh --detect           # adivinha pelo que está instalado
tune-profile.sh --profile <p> --dry-run
tune-profile.sh --profile <p>
systemctl restart <serviço>        # limites só valem no restart
validate.sh --deep                 # exercita o serviço, não só o processo
```

### Validar e testar

`validate.sh` tem duas camadas. A **passiva** (padrão) só lê estado — é
segura em cron de 5 minutos. A **ativa** (`--deep`) exercita o serviço de
verdade: consulta o resolvedor, força TCP, força EDNS, tenta AXFR não
autorizado, confere se o serial servido bate com o do arquivo de zona.

```bash
validate.sh                        # passiva
validate.sh --deep --only bind     # ativa, só DNS
validate.sh --deep --strict        # gate: nem ressalva passa
validate.sh --list                 # módulos disponíveis
```

Baliza **RED/GREEN**, com exit code para plugar em cron e Zabbix:

| | significado | exit |
|---|---|---|
| `GREEN` | passou | `0` |
| `YELLOW` | divergiu, não derruba agora | `1` |
| `RED` | falhou, precisa de ação | `2` |
| `SKIP` | não se aplica a este host | — |

### Exportar e montar relatório

```bash
validate.sh --deep --report > laudo-$(hostname)-$(date +%F).md   # markdown pronto
validate.sh --deep --json  > /tmp/host.json                      # schema 2
```

O JSON traz, por caso, o **id estável**, o valor esperado, o obtido e a
correção — dá para montar o laudo do jeito que você quiser:

```bash
jq -r 'if .verdict=="OK" then "ok" else "nok" end' /tmp/host.json
jq -r '.checks[] | select(.status=="RED") | "\(.id): esperado \(.expected), veio \(.actual) -> \(.fix)"' /tmp/host.json
```

### Atualizar o `root.hints`

```bash
update-root-hints.sh --check       # baixa, compara e relata; não instala
update-root-hints.sh               # instala só se o publicado for mais atual
```

A ordem é o ponto. A sequência intuitiva — `mv` o hints, `apt install wget`,
baixar — se autodestrói: sem hints o resolvedor perde a raiz, e o host fica
sem como buscar justamente o arquivo que o conserta. Aqui o download vai para
`root.hints2`, **ao lado**, e o arquivo em uso só é tocado depois que o novo
existe, passa na validação e prova ser mais atual pelo `related version of
root zone`.

Recusa três coisas que passariam batido: HTML de portal cativo respondido com
200, arquivo truncado, e versão **mais antiga** que a instalada (mirror velho
ou `--url` errado rebaixaria o hints). Depois do restart confere se a raiz
volta a responder — e **desfaz** se não voltar.

> `/usr/share/dns/root.hints` pertence ao pacote `dns-root-data`: o próximo
> `apt upgrade` dele reverte a atualização em silêncio. O script avisa. Para
> durar, aponte a config para um caminho seu.

### Gestão

```bash
pkops manifest                     # estado atual em Markdown + JSON
pkops drift                        # declarado × real
pkops timeline                     # histórico de eventos

for h in $(cat hosts.txt); do
  ssh "$h" 'validate.sh --deep --json' > /tmp/frota/$h.json
done
pkops fleet /tmp/frota/*.json
```

---

## Perfis de tuning

```bash
tune-profile.sh --list
```

| Perfil | Carga |
|---|---|
| `dns` | BIND recursivo |
| `dns-unbound` | Unbound (threaded, `so-reuseport`) |
| `proxy` | Zabbix Proxy + PostgreSQL |
| `medidor` | OoklaServer / iperf |
| `acs` | GenieACS + MongoDB |
| `docker` | Docker em VM |
| `lxc-docker` | Docker em LXC |
| `generico` | VPS simples, conservador |

**Perfis são exclusivos.** Aplicar um remove o outro — eles se contradizem
por natureza. `ip_forward` é `0` no `proxy` e `1` no `docker`; `rmem_max`
varia 16× entre `proxy` e `medidor`.

---

## Callbacks

Qualquer executável em `/etc/pkops/hooks.d/` recebe
`$1=evento $2=detalhe $3=timestamp`.

```bash
mv /etc/pkops/hooks.d/30-git.sh.example /etc/pkops/hooks.d/30-git.sh
chmod +x /etc/pkops/hooks.d/30-git.sh
```

| Exemplo incluído | O que faz |
|---|---|
| `10-jsonl.sh` | eventos em JSON Lines |
| `20-zabbix.sh` | `zabbix_sender` para item trapper |
| `30-git.sh` | **commit do manifest a cada mudança** — recomendado |
| `40-alerta.sh` | syslog/webhook só em evento ruim |

Hook que falha nunca derruba quem emitiu; roda sob `timeout 10` e vira
evento `hook.failed`.

---

## Convenções

**Códigos de saída:** `0` tudo ok · `1` há avisos · `2` há falhas.

**Idempotência:** rodar duas vezes = rodar uma vez. Arquivo só é reescrito
se o conteúdo efetivo mudou.

**Nenhum script reinicia sozinho.** Kernel novo pode renomear NIC.

**`--dry-run` existe em tudo.** Use antes.

---

## Desinstalação

```bash
./install.sh --uninstall
```

Remove os binários. **Preserva** `/var/lib/pkops` (estado, eventos,
manifest, histórico git) e `/etc/pkops/hooks.d`.

---

## Antes de modificar

Leia a **seção 5 do `TOOLKIT.md`** — catálogo de 33 bugs encontrados e
corrigidos. Vários são falhas silenciosas: o script "funciona" e o efeito
não existe. Reintroduzir qualquer um é regressão.

---

## Desenvolvimento e release

```bash
./build.sh                 # gera dist/pkinfra-toolkit-<VERSION>.tar.gz
python -m pytest tests/ -q # testa o build: integridade, LF, reprodutibilidade
shellcheck bin/*.sh lib/*.sh install.sh bootstrap.sh build.sh
```

**O build é reproduzível — no nível do `.tar`.** `uid/gid` zerados, `mtime`
derivado do `VERSION`, modo de cada membro vindo do `--mode` do `tar` (nunca
do filesystem, que no Windows não representa `0644` fielmente) e conteúdo
normalizado para LF. O mesmo commit gera **o mesmo `.tar` byte a byte em
qualquer host**, e é isso que permite conferir um release contra o código:

```bash
git checkout v2026.10.03 && ./build.sh
# compare dist/pkinfra-toolkit-2026.10.03.tar.sha256 com o publicado no release
```

O digest do **`.tar.gz`** não atravessa hosts: a saída do gzip varia entre
versões do compressor. Por isso o `build.sh` emite os dois digests e o
release publica os dois — para comparar entre máquinas diferentes, use o do
`.tar`; o do `.tar.gz` serve para conferir o download que você acabou de
fazer.

**Para publicar uma versão:**

```bash
echo 2026.10.03 > VERSION
git commit -am "release: 2026.10.03"
git tag v2026.10.03
git push origin main --tags     # o CI monta, verifica e publica o release
```

O workflow aborta se a tag não bater com o `VERSION` — sem release com
versão divergente.

**`.gitattributes` força LF.** Num checkout Windows, CRLF no shebang faz o
Linux responder `no such file or directory` apontando para um interpretador
que existe. O `build.sh` normaliza de novo por garantia, e o
`tests/test_build.py` falha se um `\r` chegar ao pacote.
