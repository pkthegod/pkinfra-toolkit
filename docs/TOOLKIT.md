# Toolkit de Infraestrutura — Referência e Progresso

> Documento de contexto para operação humana **e** para iteração por IA.
> Última atualização: 2026-07-29 · Escrito a partir de uma sessão de auditoria
> e refatoração incremental.

---

## 1. Contexto do ambiente

Provedor de internet regional. Pilha típica do setor no Brasil:

| Camada | O que roda |
|---|---|
| Hipervisor | Proxmox VE (frota mista: PVE 7.4, 8.x, 9.2) |
| Hardware | Dell PowerEdge 11G (R410/R610/R710) e 13G+ (E5 v3) |
| DNS | BIND9 recursivo validante; Unbound em avaliação |
| Monitoramento | Zabbix 7.0 (server externo) + proxies com PostgreSQL 16 |
| Provisionamento CPE | GenieACS (TR-069) + MongoDB |
| Medição | OoklaServer (speedtest) |
| Aplicações | Docker em VMs Debian 13 |

Host de referência usado nos diagnósticos: 2× Xeon E5-2699 v3 (72 threads),
128 GB, 2 nós NUMA, 22 VMs, KSM ativo.

**Restrição operacional dominante:** frota heterogênea, acesso remoto,
janelas curtas. Tudo precisa ser idempotente e reversível.

---

## 2. Inventário

| Script | Ver. | Papel | Onde roda |
|---|---|---|---|
| `pkops.sh` | 1.0 | Estado, eventos, callbacks, manifest, drift | Todos |
| `pve-upgrade.sh` | 3.2.0 | Upgrade PVE 6→7→8→9 | Host PVE |
| `proxmox_tune.sh` | 3.1.0 | Tuning do host PVE | Host PVE |
| `tune-profile.sh` | 1.0 | Tuning de guest por perfil de carga | VM/LXC/bare-metal |
| `setup-unbound.sh` | 2.0 | Resolvedor recursivo validante | VM DNS |
| `validate.sh` | 1.0 | Validação de runtime + tuning | Todos |

Scripts do operador auditados nesta sessão, **não** reescritos (correções
descritas na seção 5): `system_config.sh` v4.0.0, `setup-bind-recursivo.sh`,
instalador do Zabbix Proxy, instalador do OoklaServer, suíte de teste
unitário, configurador de IPv6.

### 2.1 `pkops.sh` — camada compartilhada

Arquivo único com dupla natureza: **biblioteca** quando `source`,
**CLI** quando executado. Escolha deliberada — a frota recebe `scp`,
e um arquivo é melhor que três.

```bash
install -m 0755 pkops.sh /usr/local/lib/pkops.sh
ln -sf /usr/local/lib/pkops.sh /usr/local/sbin/pkops
```

Integração nos demais scripts (duas linhas, no topo):

```bash
TOOL="nome-do-script"; VERSION="1.0"
[[ -f /usr/local/lib/pkops.sh ]] && . /usr/local/lib/pkops.sh && pk_init
```

**API de biblioteca**

| Função | Efeito |
|---|---|
| `pk_init` | cria árvore, migra diretórios legados (copia, não move) |
| `pk_emit <evento> [detalhe]` | grava em `events.log` **e dispara hooks** |
| `pk_state_set <comp> k=v...` | declara estado + carimba kernel/tool/timestamp |
| `pk_state_get <comp> [k]` | lê estado |
| `pk_state_list` | lista componentes |
| `pk_stale <comp>` | retorna 0 se o estado foi aplicado em **outro kernel** |
| `pk_facts` / `pk_facts_read` | coleta/lê fatos de hardware |

**CLI**

```
pkops manifest    gera manifest.md + manifest.json
pkops drift       compara DECLARADO x REAL
pkops timeline    histórico de eventos legível
pkops doctor      diagnostica a própria camada + integração dos scripts
pkops hooks       list | test | example
pkops fleet *.json  agrega saída do validate.sh da frota
```

**Árvore de estado**

```
/var/lib/pkops/
  events.log        ISO8601|host|tool|versão|evento|detalhe   (append-only)
  facts.env         fatos de hardware — valores SEMPRE entre aspas
  state/<comp>.env  estado declarado por componente
  manifest.md       estado atual, legível e versionável
  manifest.json     mesmo conteúdo, para máquina
  drift.log         deriva detectada, histórico
/etc/pkops/hooks.d/*.sh   callbacks executáveis
```

**Contrato de hook:** recebe `$1=evento $2=detalhe $3=timestamp`; ambiente
com `PK_TOOL`, `PK_VERSION`, `PK_HOST`, `PK_ROOT`. Roda sob `timeout 10`.
Falha de hook **nunca** derruba quem emitiu — vira evento `hook.failed`.

### 2.2 `pve-upgrade.sh` — upgrade de versão

Ciclo por servidor:

```
--assess  →  --apply  →  reboot  →  --validate  →  proxmox_tune.sh  →  repete
```

Idempotência **sem arquivo de progresso**: o estado é derivado do próprio
sistema (`pveversion`, `/etc/os-release`, conteúdo dos sources). Rodar duas
vezes na mesma fase é no-op; interromper no meio e reexecutar retoma do
ponto certo.

**Score de hardware** (`--assess`) calibrado na frota Dell 11G — o chassi
não decide nada, a CPU decide:

| Config | Score | Alvo |
|---|---|---|
| R410/R610 Nehalem (E5504/E5520/X5570) | 20–35 | PVE 8 |
| R610/R710 Westmere (E5620/X5650/X5670) | 85–90 | PVE 9 |
| Haswell+ (E5 v3+) | 100 | PVE 9 |

O divisor é **PCID** (−35 pontos): sem ele o KPTI invalida a TLB a cada
syscall, custando 20–40% em I/O — o pior perfil possível para hipervisor.
Nehalem não tem; Westmere tem. **Trocar o par de Xeon 5500 por 5600 promove
um R410 de "não recomendado" para "recomendado".**

`--validate` roda 7 estágios: serviços, pmxcfs, storages, rede (incluindo
NIC renomeada), guests (diff contra snapshot pré-upgrade), benchmark
`pveperf` comparado com a versão anterior, e presença de tuning.

### 2.3 `tune-profile.sh` — perfis de carga

Oito perfis **mutuamente exclusivos**. Aplicar um remove o outro.

| Perfil | Carga | Marca registrada |
|---|---|---|
| `dns` | BIND recursivo | UDP, PPS alto, buffer médio |
| `dns-unbound` | Unbound | threaded + `so-reuseport`, backlog maior |
| `proxy` | Zabbix Proxy + PostgreSQL | `dirty_bytes` pequeno, THP never |
| `medidor` | OoklaServer | buffers de 256 MB, BBR + fq |
| `acs` | GenieACS + MongoDB | porta efêmera, THP never |
| `docker` | Docker em VM | `ip_forward=1`, inotify, `max_map_count` |
| `lxc-docker` | Docker em LXC | só chaves namespaced |
| `generico` | VPS simples | conservador, sem aposta |

**Prova de que empilhar quebra:**

| chave | dns | medidor | proxy | docker |
|---|---|---|---|---|
| `net.core.rmem_max` | 32 MB | **256 MB** | 16 MB | 16 MB |
| `net.core.somaxconn` | 4096 | **65535** | 16384 | 32768 |
| `net.ipv4.ip_forward` | — | — | **0** | **1** |

`ip_forward` é `0` no `proxy` (VM de serviço não é roteador) e `1` no
`docker` (bridge não roteia sem ele). São contraditórios por natureza.

### 2.4 `validate.sh` — validação de runtime

Sete módulos auto-detectados: `core`, `tuning`, `bind`, `unbound`,
`zabbix-proxy`, `docker`, `pve`.

Saída humana ou `--json`. **Códigos de saída semânticos:** `0` ok,
`1` warn, `2` fail — plugga direto em Zabbix e cron.

```
UserParameter=host.validate,/usr/local/sbin/validate.sh --json
```

O módulo `tuning` detecta **deriva**: lê o arquivo do perfil aplicado e
compara chave a chave com o valor efetivo no kernel.

---

## 3. Princípios de projeto

Regras estabelecidas ao longo da refatoração. **Violá-las é regressão.**

### 3.1 Idempotência por conteúdo, nunca por timestamp

```bash
cmp -s <(grep -v '^# gerado-em:' "$file") <(grep -v '^# gerado-em:' "$tmp")
```

Arquivo só é reescrito — e só é feito backup — se o conteúdo **efetivo**
mudou. A linha de timestamp é ignorada na comparação.

### 3.2 Sysctl tolerante, chave a chave

Nunca `sysctl --system`. Aplica uma por vez; chave inexistente ou rejeitada
vira aviso e é pulada; **só o que o kernel aceitou é persistido**. É isso
que faz um arquivo só funcionar do kernel 5.4 (PVE 6) ao 7.0 (PVE 9.2).

### 3.3 Severidade explícita, nunca `$?` implícito

```bash
ok_ "nome" "detalhe"      # certo
check_status "..."         # errado: depende de $? do comando anterior
```

### 3.4 Bloqueador aborta, penalidade avisa

- **Bloqueador**: CT com cgroupv1 no PVE 9, Ceph < Squid, disco < 5 GB → `die`
- **Penalidade**: sem PCID, sem AES-NI, RAM baixa → desconta score, segue

### 3.5 Nunca reiniciar sozinho

Com NIC podendo ser renomeada pelo kernel novo, reboot automático sem
supervisão é como se perde host remoto. Todo script para num ponto de
parada explícito.

### 3.6 Estado derivado do sistema, não de arquivo de progresso

Arquivo de progresso dessincroniza do real. `pveversion` não.

### 3.7 Um arquivo por ferramenta

A frota recebe `scp`. Biblioteca compartilhada só quando o ganho supera o
custo de deploy — foi o caso do `pkops.sh` a partir de seis scripts.

### 3.8 Medir antes e depois

`pveperf` salvo por versão em `bench/pveN-<kernel>.txt`, comparado
automaticamente. Queda >15% dispara alerta. Ao fim da jornada 6→7→8→9 você
tem a resposta empírica, no seu hardware, para "qual versão rende mais".

### 3.9 Bloco compartilhado byte-idêntico

Enquanto houver duplicação, verificar:

```bash
for f in a.sh b.sh; do
  sed -n '/BLOCO COMPARTILHADO/,/FIM DO BLOCO/p' $f | sha256sum
done   # os hashes têm que bater
```

---

## 4. Fluxos operacionais

### 4.1 Upgrade de host PVE

```bash
tmux new -s upg                      # obrigatório; o script bloqueia sem
./pve-upgrade.sh --assess            # decide o alvo, grava hw-target
./pve-upgrade.sh                     # dry-run
./pve-upgrade.sh --apply             # até o próximo reboot
reboot
./pve-upgrade.sh --validate          # 7 estágios + benchmark comparado
./proxmox_tune.sh                    # kernel novo = conjunto de chaves novo
# repete até o target
```

### 4.2 Provisionamento de VM de serviço

```bash
./tune-profile.sh --detect
./tune-profile.sh --profile <perfil> --dry-run
./tune-profile.sh --profile <perfil>
systemctl restart <serviço>          # limites só valem no restart
./validate.sh
```

### 4.3 Gestão de frota

```bash
for h in $(cat hosts.txt); do
  ssh "$h" 'validate.sh --json' > /tmp/frota/$h.json
done
pkops fleet /tmp/frota/*.json
```

### 4.4 Cron recomendado

```cron
0 6 * * *  /usr/local/sbin/pkops manifest && /usr/local/sbin/pkops drift
*/10 * * * * /usr/local/sbin/validate.sh --quiet --json > /var/lib/pkops/last-validate.json
```

Com o hook `30-git.sh` ativo, cada mudança de estado vira commit —
histórico auditável de graça (`git log -p manifest.md`).

---

## 5. Catálogo de bugs — lista anti-regressão

**Esta é a seção mais importante do documento.** Cada item foi encontrado e
corrigido; reintroduzir qualquer um é regressão.

### 5.1 Falhas silenciosas (as piores)

| # | Bug | Sintoma | Correção |
|---|---|---|---|
| 1 | `cat > /etc/unbound/unbound.conf` apaga o `include` do `conf.d/` | DNSSEC **não valida**, sem erro visível | escrever em `conf.d/`, nunca no arquivo do pacote |
| 2 | `\$2` escapado dentro de aspas simples em `$( )` num heredoc | `awk: unexpected character '\'` | calcular em variáveis **antes** do heredoc |
| 3 | `facts.env` sem aspas nos valores | `Intel(R)` é erro de sintaxe; o `source` aborta e todas as chaves seguintes ficam vazias | aspas obrigatórias em todo `.env` gerado |
| 4 | `dig ... > /dev/null` como teste de resolução | retorna 0 mesmo com resposta vazia/NXDOMAIN | checar conteúdo: `[[ -n "$(dig +short)" ]]` |
| 5 | Zabbix `ConfigFrequency` (depreciada no 6.4) | o `sed` não casa, você acha que configurou | usar `ProxyConfigFrequency` no 7.0 |
| 6 | `nf_conntrack_buckets` via sysctl | read-only após carregar o módulo; falha calada | `options nf_conntrack hashsize=N` em `modprobe.d` |
| 7 | `readonly VAR` na implementação descarta mock do teste | suíte de teste opera nos **arquivos reais** | `VAR="${VAR:-default}"` ou isolar com `unshare -m` |

### 5.2 Escopo e ordem

| # | Bug | Correção |
|---|---|---|
| 8 | `/etc/security/limits.conf` para serviço systemd | systemd ignora (é PAM); usar drop-in `LimitNOFILE` |
| 9 | Checagem de cgroupv1 só no 8→9 | PVE 7 já usa cgroupv2 puro — avisar no 6→7, bloquear no 8→9 |
| 10 | Ordem de `/etc/sysctl.d/` | lexicográfica; `99-` vence `95-`. Migrado do `sysctl.conf` usa prefixo `60-` de propósito |
| 11 | `/etc/sysctl.conf` no Debian 13 | não é mais lido; migrar para `/etc/sysctl.d/` |
| 12 | Módulo carregado depois do sysctl que depende dele | `br_netfilter`/`nf_conntrack` **antes** |
| 13 | `>>` em `sysctl.conf` | duplica a cada execução; escrever arquivo próprio |

### 5.3 Escala e dimensionamento

| # | Bug | Correção |
|---|---|---|
| 14 | `dirty_ratio` percentual | 25% de 128 GB = 19,6 GB sujos; usar `dirty_bytes` acima de 32 GB. `dirty_bytes` e `dirty_ratio` se zeram mutuamente — emitir só um |
| 15 | `rmem_max = 2 GB` com `tcp_mem` de 781 MB | teto de um socket maior que o global; valores coerentes |
| 16 | `fs.inotify.max_user_instances = 128` (default) | ~10 containers e acabou; erro aparece como `ENOSPC` com disco sobrando |
| 17 | Docker `json-file` sem rotação | enche 32 GB em semanas; `max-size` + `max-file` |
| 18 | Slabs do Unbound não potência de 2 | exigência do software |

### 5.4 Detecção e falso positivo

| # | Bug | Correção |
|---|---|---|
| 19 | `pgrep -f 'termproxy'` global | dispara por aba do noVNC de **outra** sessão; subir a árvore de PPID |
| 20 | `numa_balancing=1` fixo | desfaz o pinning; detectar `hostnodes=` nas VMs |
| 21 | `rp_filter=1` (strict) | quebra roteamento assimétrico e exit node EVPN; `2` (loose) como padrão |
| 22 | Firewall stateful na porta 53 | UDP de DNS enche o conntrack; `notrack` na 53 |

### 5.5 Destrutivos

| # | Bug | Correção |
|---|---|---|
| 23 | `rm -f /etc/apt/sources.list.d/*.list` | leva junto repo de terceiro; usar `apt modernize-sources` |
| 24 | Comentar linha de stanza deb822 | gera entrada malformada; usar `Enabled: false` |
| 25 | `reboot` automático no fim | NIC pode ter sido renomeada |
| 26 | Ceph Squid→Tentacle junto com o salto de SO | migração separada; wiki `Ceph_Squid_to_Tentacle` |
| 27 | sudoers apontando para diretório | `sudo` espera executável; não concede nada, e virar `/*` seria escalonamento total |
| 28 | Senha em `sed` sem escape + arquivo 644 | `/`, `&`, `\` corrompem; `chmod 640` + `chown root:zabbix` |

---

## 6. Fatos verificados nesta sessão

Anotados porque são a base de decisões e podem envelhecer.

| Fato | Fonte |
|---|---|
| PVE 9.2 = Debian 13.5, kernel 7.0, QEMU 11.0, LXC 7.0, ZFS 2.4 | roadmap oficial, 21/05/2026 |
| PVE 9.1 = kernel 6.17; PVE 9.0 = kernel 6.14 | idem |
| PVE 9 **removeu** cgroupv1 | wiki 8→9 |
| PVE 9 exige 8.4.1+ e Ceph Squid 19.2 antes do salto | idem |
| `/tmp` vira tmpfs (até 50% da RAM) no Debian 13 | release notes |
| `systemd-sysctl` não lê mais `/etc/sysctl.conf` | idem |
| Debian 13 dropou i386, **manteve** baseline amd64 (sem x86-64-v2) | release notes |
| FreeBSD 15.1 (jun/2026); stable branch com 4 anos de suporte | freebsd.org |
| Zabbix Proxy SQLite confortável abaixo de ~1000 NVPS | blog oficial |
| Major do proxy tem que bater com a do server | idem |
| Kernel 6.17 com machine-check no boot em alguns PowerEdge | wiki PVE 9.1 |

**Escopo de sysctl em LXC** (medido):

| Namespaced (funciona no container) | Global (só no host) |
|---|---|
| `net.ipv4.*`, `net.core.somaxconn` | `vm.*` (todas) |
| `net.ipv4.ip_forward` | `fs.inotify.*` |
| `net.ipv4.ip_local_port_range` | `kernel.pid_max`, `fs.file-max` |

---

## 7. Pendências conhecidas

- [ ] `pve-upgrade.sh` e `proxmox_tune.sh` ainda usam o bloco duplicado —
      migrar para `pkops.sh` (`pkops doctor` lista o que falta)
- [ ] `tune-profile.sh` e `setup-unbound.sh` não emitem eventos `pkops`
- [ ] `validate.sh` não grava estado via `pk_state_set`
- [ ] Sem rotação de `events.log` (o `doctor` avisa acima de 5 MB)
- [ ] Template Zabbix com dependent items e triggers não montado
- [ ] `validate.sh --fix` para o subconjunto seguro (permissão, `daemon.json`,
      `LimitNOFILE`) não implementado
- [ ] `pkops apply` — estado **desejado** declarativo por classe de host
- [ ] Perfil de tuning para Nginx/proxy reverso, PPPoE concentrator, NFS

---

## 8. Como uma IA deve iterar sobre isto

### 8.1 Antes de mudar qualquer coisa

1. **Leia a seção 5 inteira.** Cada linha é um bug que já custou tempo.
   Muitos são falhas silenciosas — o script "funciona" e o efeito não existe.
2. **Confirme a versão alvo.** PVE, Debian e kernel mudam rápido; os fatos
   da seção 6 têm data. Verifique antes de assumir.
3. **Respeite os princípios da seção 3.** Não são preferência de estilo:
   cada um veio de um problema concreto.

### 8.2 Ao adicionar um perfil de tuning

Copie uma função `sysctl_*` e registre o nome em **três** lugares:
`profile_desc()`, `limits_for()` e o `case` de validação em `main()`.
Se precisar de módulo de kernel, acrescente em `load_modules_for()`.

Perfil novo precisa responder: **o que ele contradiz nos outros?** Se não
contradiz nada, provavelmente não precisava ser um perfil separado.

### 8.3 Ao adicionar um checador de deriva

Crie uma função com prefixo `_drift_` em `pkops.sh` que imprima linhas
`SEV|nome|detalhe`. O motor descobre sozinho via `declare -F`. Sem registro
manual, sem lista para manter em sincronia.

### 8.4 Ao adicionar um módulo ao `validate.sh`

Função `mod_<nome>`, `hdr <nome>` no início, `ok_`/`warn_`/`fail_`/`skip_`
para cada verificação, e uma linha `want <nome> && mod_<nome>` no `main`.
**Sempre** `skip_` quando o serviço não existe — módulo ausente não é falha.

### 8.5 Sempre teste antes de entregar

O padrão usado nesta sessão:

```bash
bash -n script.sh                    # sintaxe
# executar a lógica isolada com valores reais e comparar
# idempotência: rodar 2x e conferir que o resultado é idêntico
# tabela de cenários: mostrar que os casos divergem como esperado
```

Foi assim que apareceram os bugs 2, 3, 7 e 19 — nenhum deles é visível
lendo o código.

### 8.6 Método de trabalho

1. **Medir** — qual recurso está saturado? (USE: Utilization, Saturation, Errors)
2. **Documentação canônica** daquele recurso (`kernel.org/doc/.../sysctl/`,
   `man 7 tcp`, `man 5 proc`)
3. **Uma mudança** e medir de novo
4. **Registrar** kernel, valor anterior, valor novo, delta medido

Regra que resolve a maior parte: **toda afirmação de tuning precisa de
versão de kernel e de uma medição.** Sem os dois, é folclore. Se a chave não
está em `/proc/sys`, ela não existe — independente do que o blog disse.

### 8.7 O que não fazer

- Não "otimizar" sem saber a carga — foi por isso que existem perfis
- Não empilhar perfis
- Não usar percentual onde o valor deve ser absoluto (bug 14)
- Não confiar em `$?` implícito
- Não sobrescrever arquivo de configuração de pacote (bug 1)
- Não adicionar reboot automático
- Não trocar bloqueador por aviso "para não incomodar"

---

## 9. Decisões arquiteturais registradas

**Por que perfis exclusivos e não aditivos.** Cargas de trabalho querem
coisas opostas. Empilhar faz uma sobrescrever a outra em silêncio, e o
resultado não serve para nenhuma das duas.

**Por que upgrade e tuning ficam separados.** Ciclos de vida diferentes
(3–4 vezes na vida × toda troca de kernel), reversibilidade diferente
(irreversível × reversível) e — decisivo — **filosofias de erro opostas**:
upgrade aborta em bloqueador, tuning nunca aborta. Fundir obrigaria uma das
duas a ceder.

**Por que teste unitário não entra no `validate.sh`.** Teste unitário roda
antes do deploy, com mock, sem host real. Validação roda depois, no host
real. Misturar leva alguém a rodar a suíte de mock em produção — e o bug 7
mostra que isso escreve nos arquivos de verdade.

**Por que `pkops` é um arquivo com dupla natureza.** Deploy por `scp` numa
frota heterogênea. Biblioteca separada do CLI dobraria o custo de
distribuição sem ganho proporcional.

**Por que evento em vez de chamada direta.** Barramento por sistema de
arquivos desacopla: quem emite não sabe quem escuta. Adicionar
notificação, commit em git ou envio ao Zabbix não exige tocar em nenhum
script existente — só criar um executável em `hooks.d/`.

---

## 10. Referência rápida

```bash
# Estado e gestão
pkops doctor                      # a camada está sã? scripts integrados?
pkops manifest                    # gera manifest.md + .json
pkops drift                       # declarado x real
pkops timeline 40                 # histórico
pkops hooks example               # cria os 4 callbacks de exemplo

# Upgrade de PVE
./pve-upgrade.sh --assess
./pve-upgrade.sh --apply --target 9
./pve-upgrade.sh --validate

# Tuning de guest
./tune-profile.sh --list
./tune-profile.sh --detect
./tune-profile.sh --profile docker

# Validação
./validate.sh
./validate.sh --only unbound,tuning
./validate.sh --json | jq '.checks[] | select(.severity=="FAIL")'

# DNS
./setup-unbound.sh --check
./setup-unbound.sh --acl "203.0.113.0/24" --acl6 "2001:db8::/32"
```

**Códigos de saída padronizados:** `0` tudo ok · `1` há avisos · `2` há falhas.

---

*Princípios de engenharia aplicados: atenção obsessiva ao detalhe, resolução
de causa raiz, mudança mínima por iteração, evidência obrigatória, execução
determinística — Shokunin Katagi + XP.*
