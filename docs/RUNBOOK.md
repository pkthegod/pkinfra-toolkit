# Runbook: PVE antigo + VM no mesmo host

Roteiro para executar. Cada fase tem **ponto de parada**, **como verificar**
e **como voltar**. Marque conforme avança.

**Premissa do cenário:** host Proxmox VE 7.4 e uma VM de serviço rodando
nele. Vale igual para PVE 6, só muda o número de saltos.

---

## Regras que valem o roteiro inteiro

1. **`--dry-run` antes de tudo.** Sem exceção.
2. **`tmux` obrigatório no host.** O `pve-upgrade.sh` recusa rodar sem, e
   com razão: queda de SSH no meio do `dist-upgrade` deixa dpkg pela metade.
3. **Acesso out-of-band confirmado** (iDRAC/IPMI) antes de tocar no host.
   Kernel novo pode renomear NIC.
4. **Backup verificado**, não "tem backup". Restaure um teste.
5. **Um passo por vez.** Interromper é seguro; tudo é idempotente.

---

## FASE 0 — Reconhecimento (não altera nada)

> Tempo: ~10 min · Risco: zero · **Faça isso hoje, o resto quando quiser**

### 0.1 Levar o pacote

```bash
# na sua estação
scp pkinfra-toolkit-2026.07.29.tar.gz root@HOST-PVE:/root/
```

Para a VM, três caminhos — use o que existir:

```bash
# a) do host para a VM, se houver rede entre eles
scp /root/pkinfra-toolkit-*.tar.gz root@IP-DA-VM:/root/

# b) a VM tem internet própria
#    (baixe do seu repositório interno)

# c) sem rede: pelo console da VM, com o pacote em base64
#    base64 -w0 pacote.tar.gz > p.b64   e cola do outro lado
```

### 0.2 Instalar nos dois

```bash
tar xzf pkinfra-toolkit-2026.07.29.tar.gz
cd pkinfra-toolkit-2026.07.29
sha256sum -c CHECKSUMS.sha256      # integridade
./install.sh --dry-run             # ver o que faria
./install.sh
```

O instalador detecta o papel sozinho. **Mesmo tar, resultado diferente:**

| | Host PVE | VM |
|---|---|---|
| `pkops` | sim | sim |
| `pkassess.sh` | sim | sim |
| `validate.sh` (v2, `--deep`) | sim | sim |
| `tune-profile.sh` | sim | sim |
| `setup-unbound.sh` | sim | sim |
| `pve-upgrade.sh` | **sim** | não |
| `proxmox_tune.sh` | **sim** | não |

### 0.3 Avaliar — **a VM PRIMEIRO**

Ordem contraintuitiva e importante: a VM lê **steal time**, que só faz
sentido com o host sob carga normal. Depois que você derrubar o host, essa
informação some.

```bash
# DENTRO da VM
pkassess.sh --full
```

Olhe primeiro o steal:

- **`steal ≥ 5%`** → o veredito vira `GARGALO NO HOST`. O host está
  superprovisionado em vCPU. Nenhum tuning dentro da VM resolve. Isso muda
  a prioridade: revise a alocação antes de pensar em upgrade.
- **`steal < 5%`** → siga normalmente.

```bash
# no HOST PVE
pkassess.sh --full
```

### 0.4 Guardar o baseline

```bash
# nos dois
pkassess.sh --full --json > /root/baseline-$(hostname)-$(date +%F).json
pkops manifest
```

**Esse arquivo é a prova de que o trabalho valeu.** No fim você compara.

- [ ] Pacote instalado nos dois
- [ ] `pkassess` rodado nos dois, steal time anotado
- [ ] Baseline JSON salvo fora das máquinas

---

## FASE 1 — Preparação (ainda não muda nada crítico)

> Tempo: variável · Risco: baixo

### 1.1 Resolver bloqueadores antes de tudo

```bash
# no HOST
pve-upgrade.sh --assess
```

Ele grava `hw-target`. Se disser **PVE 8 máximo**, respeite — o preflight
vai recusar `--target 9` depois.

Bloqueadores que **param o upgrade** e precisam ser tratados agora:

| Bloqueador | Como tratar |
|---|---|
| CT com CentOS 7 / Ubuntu 16.04 | migrar ou aceitar que ficam no PVE 8 |
| Ceph abaixo da versão exigida | upgrade do Ceph **antes**, separado |
| Disco `/` acima de 85% | limpar: `journalctl --vacuum-size=200M`, cache do apt |
| `pve-firmware` ausente (Dell 11G) | `apt install pve-firmware` — sem ele a NIC bnx2 pode sumir |

### 1.2 Backup e snapshot

```bash
# no HOST
vzdump <VMID> --mode snapshot --compress zstd --storage <backup>
qm listsnapshot <VMID>
```

Se o storage suportar, tire snapshot também — rollback em segundos:

```bash
qm snapshot <VMID> antes-upgrade
```

### 1.3 Confirmar o acesso out-of-band

Abra o console iDRAC/IPMI **agora** e deixe a aba aberta. Se a rede cair
depois do reboot, é por ali que você entra.

- [ ] `--assess` rodado, target anotado
- [ ] Bloqueadores resolvidos
- [ ] Backup feito e **testado**
- [ ] Snapshot da VM
- [ ] Console out-of-band aberto e funcionando

---

## FASE 2 — Host: upgrade

> Tempo: 1–2h por salto · Risco: **alto** · Janela de manutenção

### 2.1 Preparar a sessão

```bash
ssh root@HOST-PVE
tmux new -s upg          # se cair, 'tmux attach -t upg' recupera
```

> Está no shell web do Proxmox? Abra tmux **dentro dele**. O servidor tmux
> reparenta para o PID 1, então sobrevive quando o `pveproxy` reiniciar e
> matar sua aba. Reconecte e `tmux attach`.

### 2.2 Migrar ou desligar guests

Nó em cluster: migre. Nó isolado: desligue de forma ordenada.

```bash
qm shutdown <VMID> && qm status <VMID>
```

### 2.3 Dry-run e execução

```bash
pve-upgrade.sh                          # dry-run, leia a saída inteira
pve-upgrade.sh --apply --target 8
```

O script para sozinho no ponto de reboot. **Ele nunca reinicia por conta.**

### 2.4 Reiniciar e validar

```bash
reboot
# reconecte
pve-upgrade.sh --validate
```

Sete estágios. Preste atenção especial em:

- **rede** — NIC renomeada aparece aqui; é o motivo do console aberto
- **guests** — diff contra o snapshot da Fase 0
- **benchmark** — `pveperf` comparado com a versão anterior

Queda maior que 15% em qualquer métrica dispara alerta. Cache frio logo
após reboot dá falso positivo; espere 10 min e rode de novo.

### 2.5 Tunar o host

```bash
proxmox_tune.sh --dry-run
proxmox_tune.sh
```

Ele detecta se há VM com `hostnodes=` e ajusta `numa_balancing`
automaticamente — não desfaz pinning que você tenha feito.

### 2.6 Repetir até o 9.2

```bash
pve-upgrade.sh --apply --target 9.2   # só se o --assess autorizou
```

**O salto 8→9 para no 9.0.** Os minors 9.0 → 9.1 → 9.2 — e o kernel 7.0,
que só existe no 9.2 — exigem rodar `--apply` **de novo** depois do reboot,
quantas vezes for preciso. O script diz em qual pé está:

```bash
pve-upgrade.sh --status               # mostra se o alvo foi alcançado
```

- [ ] tmux ativo
- [ ] Guests migrados ou desligados
- [ ] Dry-run lido inteiro
- [ ] `--apply` concluído
- [ ] Reboot
- [ ] `--validate` sem FAIL
- [ ] `proxmox_tune.sh` aplicado

**Se travar no meio:** rode `pve-upgrade.sh --status`. Ele lê o estado do
sistema real, não de arquivo de progresso — reexecutar retoma do ponto
certo. Se o `dist-upgrade` falhou, `apt -f install` e rode de novo.

---

## FASE 3 — VM: tuning

> Tempo: ~15 min · Risco: baixo · **Só depois do host estar de pé**

Por que depois: o upgrade do host muda QEMU e pode mudar os flags de CPU
expostos à VM. Tunar antes te obriga a revalidar depois de qualquer jeito.

### 3.1 Subir e reavaliar

```bash
# no HOST
qm start <VMID>

# DENTRO da VM
pkassess.sh --full
```

Compare o steal time com o da Fase 0. QEMU mais novo costuma melhorar.

### 3.2 Aplicar o perfil

```bash
tune-profile.sh --detect             # adivinha pela carga instalada
tune-profile.sh --profile <p> --dry-run
tune-profile.sh --profile <p>
```

Confira se o perfil sugerido bate com o que a VM realmente faz. O
`--detect` olha os serviços instalados; se a VM tem Docker **e** Zabbix
proxy, ele escolhe um — decida você qual é a carga dominante.

### 3.3 Reiniciar os serviços

```bash
systemctl restart <serviço>
```

**Sem isso o `LimitNOFILE` não vale.** Drop-in de systemd só aplica no
próximo start do processo.

### 3.4 Validar e testar

```bash
validate.sh --deep
```

A camada `--deep` é a que importa aqui: ela pergunta ao serviço em vez de
perguntar ao systemd. Se o host serve DNS, ela cobra resposta recursiva
real, TCP, EDNS, flag `AD`, `SERVFAIL` em domínio quebrado, AXFR recusado e
serial servido igual ao do arquivo de zona.

Se algum RED aparecer, cada linha já vem com **esperado**, **obtido** e a
correção. Para levar o resultado adiante:

```bash
validate.sh --deep --report > /root/laudo-$(hostname)-$(date +%F).md
```

- [ ] VM subiu, steal comparado
- [ ] Perfil aplicado e conferido
- [ ] Serviços reiniciados
- [ ] `validate.sh --deep` sem RED (veredito **OK**)

---

## FASE 4 — Consolidação

> Tempo: ~10 min · Faça, não pule

### 4.1 Provar o ganho

```bash
pkassess.sh --full --json > /root/depois-$(hostname)-$(date +%F).json

# comparação lado a lado
jq -n --slurpfile a /root/baseline-*.json --slurpfile d /root/depois-*.json \
  '{antes: $a[0].scores, depois: $d[0].scores,
    veredito_antes: $a[0].verdict.text, veredito_depois: $d[0].verdict.text}'
```

Se `SW` saltou de 25 para 55+ e `TUNE` de 0 para 100, você tem o número.

### 4.2 Ligar o histórico automático

```bash
mv /etc/pkops/hooks.d/30-git.sh.example /etc/pkops/hooks.d/30-git.sh
chmod +x /etc/pkops/hooks.d/30-git.sh
pkops manifest
```

A partir daqui, toda mudança de estado vira commit.
`git -C /var/lib/pkops log -p manifest.md` mostra a linha do tempo.

### 4.3 Acompanhamento contínuo

```cron
0 6 * * *    /usr/local/sbin/pkops manifest && /usr/local/sbin/pkops drift
0 7 * * 1    /usr/local/sbin/pkassess.sh --json > /var/lib/pkops/last-assess.json
# passiva: só lê estado, pode rodar de 15 em 15 min sem custo
*/15 * * * * /usr/local/sbin/validate.sh --quiet --json > /var/lib/pkops/last-validate.json
# ativa: consulta o serviço de verdade — 1x por hora basta
23 * * * *   /usr/local/sbin/validate.sh --deep --json > /var/lib/pkops/last-deep.json
```

O exit code é o gatilho: `0` tudo GREEN, `1` há YELLOW, `2` há RED. Em
Zabbix, o item lê o JSON e a trigger olha `.summary.fail`.

- [ ] JSON do depois salvo e comparado
- [ ] Hook de git ativo
- [ ] Cron configurado (passiva frequente + ativa horária)

---

## Ganhos de segurança

Não é efeito colateral — é boa parte do motivo.

| Ganho | Onde |
|---|---|
| **Volta ao suporte de segurança** | PVE 7 sem correções → PVE 8/9 com |
| Detecção de resolvedor aberto | `validate.sh` módulo dns/unbound |
| Permissão de arquivo com senha | detecta `zabbix_proxy.conf` em 644 |
| `LimitNOFILE` correto | esgotamento de FD é vetor de DoS |
| `tcp_syncookies`, `accept_redirects=0` | todos os perfis |
| `rp_filter` sem quebrar EVPN | loose por padrão, strict opcional |
| Trust anchor do DNSSEC | detecta validação desligada em silêncio |
| Rotação de log do Docker | disco cheio derruba o host |
| Hook estranho no dpkg | preflight avisa sobre `no-nag-script` |

---

## Se der errado

| Sintoma | Ação |
|---|---|
| Host não sobe | console out-of-band → menu do GRUB → kernel anterior |
| Boot falha com machine-check (PowerEdge) | BIOS: SR-IOV Global + I/OAT DMA, ou `proxmox-boot-tool kernel pin <6.14.x>` |
| Rede não sobe | console: `ip link` — NIC renomeada; corrigir `/etc/network/interfaces` |
| `dist-upgrade` parou no meio | `apt -f install` e reexecutar o script |
| VM não inicia | `qm rollback <VMID> antes-upgrade` |
| Tuning piorou algo | `rm /etc/sysctl.d/96-tune-profile-*.conf && reboot` |
| Perdeu o acesso SSH | console out-of-band; nada aqui altera `sshd_config` |

**A rede de segurança real é a Fase 1.3.** Console out-of-band aberto
resolve todos os casos acima; sem ele, alguns viram viagem até o rack.

---

## Onde a idempotência te salva

| Situação | O que acontece |
|---|---|
| Rodar `pkassess` 10× | mesma leitura, nada muda |
| Rodar `tune-profile` 2× igual | segunda vez: "sem mudanças" |
| Rodar `pve-upgrade --apply` de novo | detecta a versão real e retoma |
| SSH caiu no meio | `tmux attach -t upg` |
| Trocar de perfil | remove o anterior, pede confirmação |
| Reinstalar o pacote | hook seu é preservado, estado é preservado |

Isso significa que **você pode parar em qualquer fase e voltar amanhã.**
Nenhum estado fica pela metade porque nada é guardado em arquivo de
progresso — tudo é derivado do sistema real.
