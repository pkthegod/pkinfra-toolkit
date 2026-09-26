#!/usr/bin/env bash
# Baliza do proxmox_tune.sh. Extrai as funcoes REAIS e roda contra uma raiz
# falsa — o teste acompanha o codigo em vez de reimplementa-lo. Cobre o que
# na v3.3 deixou de ser falha silenciosa:
#   - deteccao do firewall do PVE (decide bridge-nf e conntrack)
#   - piso do ARC: teto abaixo do zfs_arc_min e ignorado pelo ZFS
#   - demanda de hugepages lida das VMs
#   - .env com aspas: 'Intel(R)' e '(balanceamento inutil)' quebravam o source
# SC2034: as variaveis sao lidas pelas funcoes extraidas via eval.
# shellcheck disable=SC2034
set -uo pipefail

FONTE="${1:?uso: prova-tune.sh <proxmox_tune.sh>}"
RAIZ=$(mktemp -d); trap 'rm -rf "${RAIZ:?}"' EXIT

extrai() {   # <funcao>...
  local f
  for f in "$@"; do
    sed -n "/^${f}() {/,/^}/p" "$FONTE"
    grep -q "^${f}() {" "$FONTE" || { echo "echo 'funcao ${f} sumiu'; exit 1"; }
  done
}
# shellcheck disable=SC1090
eval "$(extrai pve_fw_enabled zfs_arc_min_for vm_hugepages_demand arcstat_get)"
_log() { :; }

falhas=0
confere() {   # <nome> <esperado> <obtido>
  if [[ "$2" == "$3" ]]; then printf 'OK     %s\n' "$1"
  else printf 'FALHOU %s\n       esperado=[%s] obtido=[%s]\n' "$1" "$2" "$3"; falhas=$((falhas+1)); fi
}

# ── firewall ────────────────────────────────────────────────────────────────
fw() { printf '%s\n' "$@" > "$RAIZ/cluster.fw"; pve_fw_enabled "$RAIZ/cluster.fw" && echo on || echo off; }
confere "firewall: enable 1 em OPTIONS"          on  "$(fw '[OPTIONS]' 'enable: 1')"
confere "firewall: enable 0"                     off "$(fw '[OPTIONS]' 'enable: 0')"
confere "firewall: sem a chave (default off)"    off "$(fw '[OPTIONS]' 'policy_in: DROP')"
confere "firewall: enable fora de OPTIONS nao vale" off "$(fw '[OPTIONS]' 'policy_in: DROP' '[RULES]' 'enable: 1')"
confere "firewall: secao em minuscula e espacos" on  "$(fw '[options]' '  enable :  1  # ligado')"
rm -f "$RAIZ/cluster.fw"
confere "firewall: sem cluster.fw"               off "$(pve_fw_enabled "$RAIZ/cluster.fw" && echo on || echo off)"

# ── piso do ARC ─────────────────────────────────────────────────────────────
G=$((1024*1024*1024))
confere "arc: 256GB, teto 4GB -> baixa o min p/ 2GB" $((2*G)) "$(zfs_arc_min_for $((4*G)) $((8*G)) $((256*G)))"
confere "arc: 256GB, teto 32GB -> nao mexe"          ""       "$(zfs_arc_min_for $((32*G)) $((8*G)) $((256*G)))"
confere "arc: c_min vazio usa RAM/32"                $((2*G)) "$(zfs_arc_min_for $((4*G)) "" $((256*G)))"
confere "arc: teto == piso tambem e ignorado"        $((4*G)) "$(zfs_arc_min_for $((8*G)) 0 $((256*G)))"
confere "arc: c_min atual maior que RAM/32 manda"    $((3*G)) "$(zfs_arc_min_for $((6*G)) $((6*G)) $((64*G)))"

# ── demanda de hugepages ────────────────────────────────────────────────────
Q="$RAIZ/qemu"; mkdir -p "$Q"
printf 'memory: 8192\nhugepages: 2\n' > "$Q/100.conf"
printf 'memory: current=4096\nhugepages: 1024\nballoon: 2048\n' > "$Q/101.conf"
printf 'memory: 2048\n' > "$Q/102.conf"
printf 'memory: 16384\nhugepages: any\nballoon: 0\n\n[snap1]\nhugepages: 2\nmemory: 99999\n' > "$Q/103.conf"
QEMU_CONF_DIR="$Q"
confere "hugepages: 3 VMs, 28GB, 1 tamanho divergente, 1 balloon" "3 28672 1 1" "$(vm_hugepages_demand 2)"
QEMU_CONF_DIR="$RAIZ/vazio"
confere "hugepages: sem VMs"                    "0 0 0 0" "$(vm_hugepages_demand 2)"

# ── arcstats ────────────────────────────────────────────────────────────────
printf 'c                               4    123\nc_min                           4    268435456\nc_max                           4    4294967296\n' > "$RAIZ/arcstats"
ARCSTATS="$RAIZ/arcstats"
confere "arcstats: le c_max"                    4294967296 "$(arcstat_get c_max)"
confere "arcstats: le c_min (nao casa 'c')"     268435456  "$(arcstat_get c_min)"

# ── .env com aspas (bug 3) ──────────────────────────────────────────────────
printf 'model name\t: Intel(R) Xeon(R) CPU E5620 @ 2.40GHz\nflags\t\t: fpu pcid aes\n' > "$RAIZ/cpuinfo"
printf 'MemTotal: 16384000 kB\n' > "$RAIZ/meminfo"
# shellcheck disable=SC1090
eval "$(extrai state_facts_write | sed -e "s#/proc/cpuinfo#$RAIZ/cpuinfo#g" -e "s#/proc/meminfo#$RAIZ/meminfo#g")"
STATE_ROOT="$RAIZ"; FACTS_FILE="$RAIZ/facts.env"; TOOL=prova; VERSION=0
state_facts_write
out=$(bash -c ". '$FACTS_FILE' && echo \"\$FACT_CPU|\$FACT_CORES|\$FACT_AES\"" 2>&1)
confere "facts.env: source sobrevive a Intel(R)" "Intel(R) Xeon(R) CPU E5620 @ 2.40GHz|$(nproc 2>/dev/null || echo 0)|1" "$out"

# shellcheck disable=SC1090
eval "$(extrai tune_state_write tune_state_file tune_signature)"
TUNE_DIR="$RAIZ/tune"; mkdir -p "$TUNE_DIR"; DRY_RUN=0
SCRIPT_VERSION=9.9; SWAPPINESS=10; NUMA_BAL=0; NUMA_REASON="host de 1 no NUMA (balanceamento inutil)"
GOVERNOR=""; ZFS_ARC_GB=0; HUGEPAGES_GB=0; HUGEPAGES_SIZE=2M; STRICT_RPFILTER=0; DISABLE_HA=0; PVE_FW=off
tune_state_write
out=$(bash -c ". '$(tune_state_file)' && echo \"\$TUNE_NUMA_REASON|\$TUNE_FIREWALL|\$TUNE_VERSION\"" 2>&1)
confere "state.env: source sobrevive a parenteses" "host de 1 no NUMA (balanceamento inutil)|off|9.9" "$out"

echo
if [[ $falhas -eq 0 ]]; then echo "TODOS OS CASOS PASSARAM"; else echo "$falhas caso(s) FALHARAM"; exit 1; fi
