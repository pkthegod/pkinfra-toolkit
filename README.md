# pkinfra-toolkit

Ferramentas de upgrade, tuning e validação para frota Debian / Proxmox VE.

**Versão do pacote:** 2026.07.29

---

## Instalação

```bash
tar xzf pkinfra-toolkit-2026.07.29.tar.gz
cd pkinfra-toolkit-2026.07.29
sha256sum -c CHECKSUMS.sha256     # confere integridade
./install.sh --dry-run            # ver o que faria
./install.sh                      # instala conforme o papel detectado
```

O instalador detecta se é host Proxmox ou guest e instala só o que faz
sentido. `--all` força tudo.

---

## Conteúdo

| Arquivo | Versão | Papel |
|---|---|---|
| `bin/pkassess.sh` | 1.0 | **levantamento, benchmark e prescricao — comece aqui** |
| `lib/pkops.sh` | 1.0 | estado, eventos, callbacks, manifest, drift |
| `bin/pve-upgrade.sh` | 3.2.0 | upgrade PVE 6→7→8→9 |
| `bin/proxmox_tune.sh` | 3.1.0 | tuning do host PVE |
| `bin/tune-profile.sh` | 1.0 | tuning de guest — 8 perfis de carga |
| `bin/setup-unbound.sh` | 2.0 | resolvedor recursivo validante |
| `bin/validate.sh` | 1.0 | validação de runtime + tuning |
| `docs/TOOLKIT.md` | — | **referência completa** |

Após instalar, tudo fica em `/usr/local/sbin/` e a referência em
`/usr/local/share/pkinfra/TOOLKIT.md`.

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

### Guest de serviço

```bash
pkops doctor
tune-profile.sh --detect           # adivinha pelo que está instalado
tune-profile.sh --profile <p> --dry-run
tune-profile.sh --profile <p>
systemctl restart <serviço>        # limites só valem no restart
validate.sh
```

### Gestão

```bash
pkops manifest                     # estado atual em Markdown + JSON
pkops drift                        # declarado × real
pkops timeline                     # histórico de eventos

for h in $(cat hosts.txt); do
  ssh "$h" 'validate.sh --json' > /tmp/frota/$h.json
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

Leia a **seção 5 do `TOOLKIT.md`** — catálogo de 28 bugs encontrados e
corrigidos. Vários são falhas silenciosas: o script "funciona" e o efeito
não existe. Reintroduzir qualquer um é regressão.
