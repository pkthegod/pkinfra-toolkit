#!/usr/bin/env bash
# =============================================================================
# pkassess.sh — v1.0
# Levantamento de recursos + benchmark + PRESCRICAO de acoes.
#
# E o portao de entrada do toolkit: os outros scripts assumem que voce ja
# sabe o que rodar. Este descobre e te diz, com os comandos prontos.
#
# QUATRO EIXOS, NUNCA UMA MEDIA
#   HW    capacidade do hardware   (PCID, AES-NI, AVX2, RAM, cores)
#   SW    atualidade do software   (versao vs fim de suporte)
#   IO    performance de disco     (fio, relativo a CLASSE do disco)
#   TUNE  estado do tuning         (aplicado? coerente com o kernel? deriva?)
#
# Media esconde informacao. Um R710/PVE7/SSD (HW90 SW25 IO85 TUNE0) tem media
# 50; um R410/PVE9/HDD (HW35 SW95 IO20 TUNE100) tem media 62 — e e a pior
# maquina das duas. As acoes tambem sao opostas: a primeira precisa de
# UPGRADE, a segunda de HARDWARE NOVO. Por isso o veredito sai de uma tabela
# de decisao sobre os quatro eixos, nao de uma soma.
#
# Uso:
#   ./pkassess.sh                 rapido (~10s, sem benchmark de disco)
#   ./pkassess.sh --full          com fio (~2-4 min)
#   ./pkassess.sh --json          para agregacao de frota
#   ./pkassess.sh --full --json | jq .
# =============================================================================
set -uo pipefail

TOOL="pkassess"; VERSION="1.0"
[[ -f /usr/local/lib/pkops.sh ]] && . /usr/local/lib/pkops.sh && pk_init 2>/dev/null || true

FULL=0; JSON=0; BENCH_MB=512
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)  FULL=1 ;;
    --json)  JSON=1 ;;
    --size)  shift; BENCH_MB="${1:-512}" ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "flag desconhecida: $1"; exit 2 ;;
  esac
  shift
done

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_D=$'\e[2m'; C_0=$'\e[0m'
[[ -t 1 && $JSON -eq 0 ]] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""; }
p()   { [[ $JSON -eq 0 ]] && printf '%s\n' "$*"; return 0; }
kv()  { [[ $JSON -eq 0 ]] && printf '  %-24s %s\n' "$1" "$2"; return 0; }
h1()  { [[ $JSON -eq 0 ]] && { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }; return 0; }
good(){ [[ $JSON -eq 0 ]] && printf '  %s+%s %s\n' "$C_G" "$C_0" "$*"; return 0; }
bad() { [[ $JSON -eq 0 ]] && printf '  %s-%s %s\n' "$C_R" "$C_0" "$*"; return 0; }
mid() { [[ $JSON -eq 0 ]] && printf '  %s~%s %s\n' "$C_Y" "$C_0" "$*"; return 0; }

# =============================================================================
# 1. INVENTARIO
# =============================================================================
CPUFLAGS=$(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo)
hasf() { grep -qw "$1" <<<"$CPUFLAGS"; }

CPU_MODEL=$(awk -F: '/^model name/{sub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)
CORES=$(nproc)
SOCKETS=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2);print $2}')
[[ "$SOCKETS" =~ ^[0-9]+$ ]] || SOCKETS=1
RAM_MB=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
RAM_AVAIL_MB=$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo)
SWAP_MB=$(awk '/SwapTotal/{printf "%d",$2/1024}' /proc/meminfo)
NUMA_NODES=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
KERNEL=$(uname -r)
CODENAME=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-desconhecido}")
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo desconhecido)
VIRT=$(systemd-detect-virt 2>/dev/null || echo none)
PVE_VER=$(pveversion 2>/dev/null | head -1 | grep -oP 'pve-manager/\K[^ /]+')
PVE_MAJOR=$(cut -d. -f1 <<<"${PVE_VER:-0}")

x86_level() {
  local v2=1 v3=1 f
  for f in cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3; do hasf "$f" || v2=0; done
  for f in avx avx2 bmi1 bmi2 f16c fma abm movbe;    do hasf "$f" || v3=0; done
  [[ $v3 -eq 1 ]] && echo 3 || { [[ $v2 -eq 1 ]] && echo 2 || echo 1; }
}
X86LVL=$(x86_level)

# papel do host
ROLE="guest"
[[ -n "$PVE_VER" ]] && ROLE="pve-host"
[[ "$VIRT" == "lxc" ]] && ROLE="lxc"
[[ "$VIRT" == "none" && -z "$PVE_VER" ]] && ROLE="bare-metal"

# disco raiz e sua CLASSE (define o IOPS esperado)
ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null)
ROOT_FS=$(findmnt -no FSTYPE / 2>/dev/null)
DISK_CLASS="desconhecido"
case "$ROOT_SRC" in
  *nvme*)  DISK_CLASS="nvme" ;;
  /dev/vd*|*virtio*) DISK_CLASS="virtio" ;;
esac
if [[ "$DISK_CLASS" == "desconhecido" ]]; then
  case "$ROOT_FS" in
    zfs) DISK_CLASS="zfs" ;;
    *)
      base=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)
      [[ -z "$base" ]] && base=$(basename "$ROOT_SRC" 2>/dev/null | sed 's/[0-9]*$//')
      if [[ -f "/sys/block/${base}/queue/rotational" ]]; then
        [[ "$(cat "/sys/block/${base}/queue/rotational")" == "1" ]] && DISK_CLASS="hdd" || DISK_CLASS="ssd"
      fi ;;
  esac
fi
DISK_FREE_GB=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
DISK_USED_PCT=$(df -P / | awk 'NR==2{gsub(/%/,"",$5);print $5}')

# steal time: sinal EXCLUSIVO de guest. Alto = host superprovisionado,
# e nenhum tuning dentro da VM resolve isso.
STEAL=0
if [[ "$ROLE" != "pve-host" && "$ROLE" != "bare-metal" ]]; then
  STEAL=$(LC_ALL=C vmstat 1 3 2>/dev/null | tail -1 | awk '{print $(NF-1)}')
  [[ "$STEAL" =~ ^[0-9]+$ ]] || STEAL=0
fi

# =============================================================================
# 2. EIXO HW — capacidade do hardware
# =============================================================================
HW=100; HW_NOTAS=()
if hasf pcid; then :; else
  HW=$((HW-35)); HW_NOTAS+=("sem PCID: KPTI custa 20-40% em syscall/IO (CPU pre-Westmere)")
fi
hasf aes || { HW=$((HW-15)); HW_NOTAS+=("sem AES-NI: cripto em software"); }
[[ $X86LVL -lt 3 ]] && { HW=$((HW-10)); HW_NOTAS+=("x86-64-v${X86LVL}: sem caminhos AVX2"); }
if   [[ $RAM_MB -lt 4096 ]];  then HW=$((HW-20)); HW_NOTAS+=("RAM ${RAM_MB}MB muito baixa")
elif [[ $RAM_MB -lt 8192 ]];  then HW=$((HW-10)); HW_NOTAS+=("RAM ${RAM_MB}MB apertada")
elif [[ $RAM_MB -lt 16384 ]]; then HW=$((HW-5)); fi
[[ $CORES -lt 4 ]] && { HW=$((HW-10)); HW_NOTAS+=("${CORES} vCPU: pouco para serviço"); }
[[ $HW -lt 0 ]] && HW=0

# =============================================================================
# 3. EIXO SW — atualidade (fim de suporte)
# =============================================================================
SW=100; SW_NOTAS=(); SW_ACAO=""
if [[ "$ROLE" == "pve-host" ]]; then
  case "$PVE_MAJOR" in
    9) SW=100 ;;
    8) SW=55; SW_NOTAS+=("PVE 8 no fim do ciclo (EOL estimado jul/2026)"); SW_ACAO="pve-upgrade.sh --apply --target 9" ;;
    7) SW=25; SW_NOTAS+=("PVE 7 SEM suporte — sem correcao de seguranca"); SW_ACAO="pve-upgrade.sh --apply --target 8" ;;
    6) SW=10; SW_NOTAS+=("PVE 6 SEM suporte ha anos"); SW_ACAO="pve-upgrade.sh --apply --target 7" ;;
    *) SW=50; SW_NOTAS+=("versao PVE nao reconhecida: ${PVE_VER}") ;;
  esac
else
  case "$CODENAME" in
    trixie)   SW=100 ;;
    bookworm) SW=75; SW_NOTAS+=("Debian 12: suportado, mas 13 ja e estavel") ;;
    bullseye) SW=35; SW_NOTAS+=("Debian 11 em LTS, fim proximo"); SW_ACAO="upgrade de release para bookworm" ;;
    buster)   SW=10; SW_NOTAS+=("Debian 10 SEM suporte"); SW_ACAO="upgrade de release, um passo por vez" ;;
    *)        SW=50; SW_NOTAS+=("release nao reconhecida: ${CODENAME}") ;;
  esac
fi

# =============================================================================
# 4. CARGA DETECTADA -> perfil de tuning sugerido
# =============================================================================
detect_profile() {
  local u; u=$(systemctl list-unit-files 2>/dev/null)
  grep -q '^unbound\.service'        <<<"$u" && { echo dns-unbound; return; }
  grep -qE '^(named|bind9)\.service' <<<"$u" && { echo dns; return; }
  grep -q '^zabbix-proxy\.service'   <<<"$u" && { echo proxy; return; }
  grep -qE '^(ooklaserver|speedtest)\.service' <<<"$u" && { echo medidor; return; }
  grep -q '^genieacs-'               <<<"$u" && { echo acs; return; }
  if grep -q '^docker\.service' <<<"$u"; then
    [[ "$VIRT" == "lxc" ]] && echo lxc-docker || echo docker; return
  fi
  echo generico
}
SUG_PROFILE=$(detect_profile)
SERVICES=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
  | awk '{print $1}' | grep -oP '^(named|bind9|unbound|zabbix-proxy|zabbix-agent|docker|postgresql|mongod|nginx|ooklaserver|genieacs-[a-z]+)' \
  | sort -u | tr '\n' ' ')

# =============================================================================
# 5. EIXO TUNE — estado do tuning
# =============================================================================
TUNE=0; TUNE_NOTAS=(); TUNE_ACAO=""; TUNE_PROFILE_ATUAL=""
_pf=$(ls /etc/sysctl.d/96-tune-profile-*.conf 2>/dev/null | head -1)
if [[ -n "$_pf" ]]; then
  TUNE_PROFILE_ATUAL=$(basename "$_pf" | sed -E 's/^96-tune-profile-(.*)\.conf$/\1/')
  TUNE=100
  # coerente com o kernel?
  if [[ -f /var/lib/pkops/state/tuning.env ]]; then
    _k=$(grep -oP '^PK_KERNEL="?\K[^"]*' /var/lib/pkops/state/tuning.env 2>/dev/null)
    if [[ -n "$_k" && "$_k" != "$KERNEL" ]]; then
      TUNE=40; TUNE_NOTAS+=("aplicado no kernel ${_k}, rodando ${KERNEL}")
      TUNE_ACAO="tune-profile.sh --profile ${TUNE_PROFILE_ATUAL}"
    fi
  fi
  # perfil certo para a carga?
  if [[ "$TUNE_PROFILE_ATUAL" != "$SUG_PROFILE" && "$SUG_PROFILE" != "generico" ]]; then
    TUNE=$((TUNE-30)); TUNE_NOTAS+=("perfil '${TUNE_PROFILE_ATUAL}' mas a carga sugere '${SUG_PROFILE}'")
    TUNE_ACAO="tune-profile.sh --profile ${SUG_PROFILE}"
  fi
  # deriva: valor do arquivo bate com o efetivo?
  _drift=0
  while IFS= read -r l; do
    [[ -z "${l// }" || "$l" =~ ^[[:space:]]*# ]] && continue
    _k2="${l%%=*}"; _k2="${_k2// }"; _v="${l#*=}"; _v="${_v# }"
    [[ -e "/proc/sys/${_k2//.//}" ]] || continue
    _c=$(sysctl -n "$_k2" 2>/dev/null)
    [[ "$(tr -s ' ' <<<"$_c")" == "$(tr -s ' ' <<<"$_v")" ]] || _drift=$((_drift+1))
  done < "$_pf"
  [[ $_drift -gt 0 ]] && { TUNE=$((TUNE-20)); TUNE_NOTAS+=("${_drift} chave(s) com deriva do declarado"); }
else
  TUNE_NOTAS+=("nenhum perfil aplicado")
  TUNE_ACAO="tune-profile.sh --profile ${SUG_PROFILE}"
fi
[[ $TUNE -lt 0 ]] && TUNE=0

# tuning do host PVE
PVE_TUNE="nao"
[[ -f "/var/lib/pkops/tune/state-${KERNEL}.env" ]] && PVE_TUNE="sim"

# =============================================================================
# 6. EIXO IO — benchmark (relativo a CLASSE do disco)
# =============================================================================
IOPS_R=0; IOPS_W=0; FSYNC=0; IO=50; IO_NOTAS=(); BENCH_RAN=0
BENCH_DIR="${TMPDIR:-/var/tmp}/pkassess.$$"

bench_cleanup() { rm -rf "$BENCH_DIR" 2>/dev/null; }
trap bench_cleanup EXIT INT TERM

run_bench() {
  local need_gb=$(( BENCH_MB / 1024 + 1 ))
  if [[ ${DISK_FREE_GB:-0} -lt $((need_gb + 2)) ]]; then
    IO_NOTAS+=("disco sem espaco para benchmark (${DISK_FREE_GB}GB livres)"); return 1
  fi
  mkdir -p "$BENCH_DIR" || return 1

  if command -v fio >/dev/null 2>&1; then
    local out
    # leitura aleatoria 4k — a metrica que importa para VM/banco
    out=$(fio --name=r --directory="$BENCH_DIR" --size="${BENCH_MB}m" --bs=4k \
          --rw=randread --iodepth=16 --ioengine=libaio --direct=1 --runtime=15 \
          --time_based --group_reporting --output-format=json 2>/dev/null)
    IOPS_R=$(grep -oP '"iops"\s*:\s*\K[0-9.]+' <<<"$out" | head -1 | cut -d. -f1)
    out=$(fio --name=w --directory="$BENCH_DIR" --size="${BENCH_MB}m" --bs=4k \
          --rw=randwrite --iodepth=16 --ioengine=libaio --direct=1 --runtime=15 \
          --time_based --group_reporting --output-format=json 2>/dev/null)
    IOPS_W=$(grep -oP '"iops"\s*:\s*\K[0-9.]+' <<<"$out" | head -1 | cut -d. -f1)
    # fsync: o numero que decide performance de banco de dados
    out=$(fio --name=s --directory="$BENCH_DIR" --size=64m --bs=4k \
          --rw=write --fsync=1 --iodepth=1 --ioengine=sync --runtime=10 \
          --time_based --group_reporting --output-format=json 2>/dev/null)
    FSYNC=$(grep -oP '"iops"\s*:\s*\K[0-9.]+' <<<"$out" | head -1 | cut -d. -f1)
    BENCH_RAN=1
  elif command -v pveperf >/dev/null 2>&1; then
    local o; o=$(pveperf 2>/dev/null)
    FSYNC=$(grep -oP '^FSYNCS/SECOND:\s*\K[0-9.]+' <<<"$o" | cut -d. -f1)
    IO_NOTAS+=("fio ausente — usando pveperf (so FSYNC)"); BENCH_RAN=1
  else
    IO_NOTAS+=("nem fio nem pveperf instalados: apt install fio"); return 1
  fi
  for v in IOPS_R IOPS_W FSYNC; do [[ "${!v}" =~ ^[0-9]+$ ]] || eval "$v=0"; done
  return 0
}

score_io() {
  [[ $BENCH_RAN -eq 0 ]] && { IO=50; IO_NOTAS+=("sem benchmark — use --full"); return; }
  # limiar por CLASSE. Pontuar IOPS absoluto seria errado: HDD e NVMe
  # diferem em 3 ordens de grandeza e ambos podem estar saudaveis.
  local exp_r exp_f
  case "$DISK_CLASS" in
    nvme)   exp_r=50000; exp_f=8000 ;;
    ssd)    exp_r=10000; exp_f=2000 ;;
    virtio) exp_r=8000;  exp_f=1500 ;;
    zfs)    exp_r=5000;  exp_f=1000 ;;
    hdd)    exp_r=150;   exp_f=80   ;;
    *)      exp_r=3000;  exp_f=500  ;;
  esac
  local sr sf
  sr=$(( IOPS_R * 100 / exp_r )); [[ $sr -gt 100 ]] && sr=100
  sf=$(( FSYNC  * 100 / exp_f )); [[ $sf -gt 100 ]] && sf=100
  IO=$(( (sr + sf * 2) / 3 ))   # fsync pesa o dobro: e o que trava banco e VM
  [[ $sf -lt 40 ]] && IO_NOTAS+=("fsync ${FSYNC}/s baixo p/ ${DISK_CLASS} (esperado ~${exp_f}) — gargalo de banco/VM")
  [[ $sr -lt 40 ]] && IO_NOTAS+=("leitura aleatoria ${IOPS_R} IOPS baixa p/ ${DISK_CLASS} (esperado ~${exp_r})")
  [[ $IO -ge 70 ]] && IO_NOTAS+=("disco saudavel para a classe ${DISK_CLASS}")
}

# =============================================================================
# 7. SAIDA
# =============================================================================
barra() { # <valor>
  # NAO usar 'local v=$1 n=$((v/5))': o bash expande TODOS os argumentos
  # antes de 'local' executar, entao v ainda nao existe e set -u aborta.
  local v="$1"
  local n=$(( v / 5 )) i s=""
  for ((i=0;i<20;i++)); do [[ $i -lt $n ]] && s="${s}#" || s="${s}."; done
  local c="$C_G"; [[ $v -lt 70 ]] && c="$C_Y"; [[ $v -lt 45 ]] && c="$C_R"
  printf '%s%s%s %3d' "$c" "$s" "$C_0" "$v"
}

if [[ $JSON -eq 0 ]]; then
  p "${C_B}=======================================================${C_0}"
  p "  pkassess v${VERSION} — $(hostname)"
  p "${C_B}=======================================================${C_0}"

  h1 "Inventario"
  kv "papel"        "$ROLE"
  kv "produto"      "$PRODUCT"
  kv "virtualizacao" "$VIRT"
  kv "CPU"          "$CPU_MODEL"
  kv "cores/sockets" "${CORES} / ${SOCKETS}   x86-64-v${X86LVL}   NUMA: ${NUMA_NODES}"
  kv "PCID / AES-NI" "$(hasf pcid && echo sim || echo NAO) / $(hasf aes && echo sim || echo NAO)"
  kv "RAM"          "${RAM_MB} MB (disponivel ${RAM_AVAIL_MB} MB)  swap ${SWAP_MB} MB"
  kv "disco /"      "${ROOT_SRC} (${ROOT_FS}) classe=${DISK_CLASS}  ${DISK_USED_PCT}% usado, ${DISK_FREE_GB}GB livres"
  kv "SO"           "Debian ${CODENAME}  kernel ${KERNEL}"
  [[ -n "$PVE_VER" ]] && kv "Proxmox VE" "$PVE_VER"
  [[ -n "$SERVICES" ]] && kv "servicos" "$SERVICES"
  if [[ "$ROLE" != "pve-host" && "$ROLE" != "bare-metal" ]]; then
    if [[ ${STEAL:-0} -ge 5 ]]; then bad "steal time ${STEAL}% — o HOST esta superprovisionado"
    else kv "steal time" "${STEAL}%"; fi
  fi
fi

if [[ $FULL -eq 1 ]]; then
  h1 "Benchmark de disco (${BENCH_MB}MB, ~40s)"
  [[ $JSON -eq 0 ]] && p "  ${C_D}medindo... nao interrompa${C_0}"
  run_bench || true
fi
score_io

if [[ $JSON -eq 0 ]]; then
  [[ $BENCH_RAN -eq 1 ]] && {
    h1 "Resultado do benchmark"
    kv "leitura aleatoria 4k" "${IOPS_R} IOPS"
    kv "escrita aleatoria 4k" "${IOPS_W} IOPS"
    kv "fsync/s"              "${FSYNC}   ${C_D}(o numero que decide banco e VM)${C_0}"
  }

  h1 "Pontuacao"
  printf '  %-6s %s\n' "HW"   "$(barra $HW)"
  printf '  %-6s %s\n' "SW"   "$(barra $SW)"
  printf '  %-6s %s%s\n' "IO" "$(barra $IO)" "$([[ $BENCH_RAN -eq 0 ]] && echo "  ${C_D}(estimado — use --full)${C_0}")"
  printf '  %-6s %s\n' "TUNE" "$(barra $TUNE)"

  for n in "${HW_NOTAS[@]:-}";   do [[ -n "$n" ]] && mid "HW: $n"; done
  for n in "${SW_NOTAS[@]:-}";   do [[ -n "$n" ]] && mid "SW: $n"; done
  for n in "${IO_NOTAS[@]:-}";   do [[ -n "$n" ]] && mid "IO: $n"; done
  for n in "${TUNE_NOTAS[@]:-}"; do [[ -n "$n" ]] && mid "TUNE: $n"; done
fi

# =============================================================================
# 8. VEREDITO — tabela de decisao sobre os 4 eixos, na ordem de prioridade
# =============================================================================
VEREDITO=""; SEVERIDADE="ok"; ACOES=()

# ordem importa: resolver software vencido antes de tunar, e nao tunar
# guest quando o gargalo esta no host
if [[ ${STEAL:-0} -ge 5 ]]; then
  VEREDITO="GARGALO NO HOST, NAO NESTA VM"; SEVERIDADE="alerta"
  ACOES+=("steal time de ${STEAL}% significa host superprovisionado")
  ACOES+=("nenhum tuning DENTRO da VM resolve isso")
  ACOES+=("va ao host: pkassess.sh no hipervisor e revise a alocacao de vCPU")
elif [[ $SW -lt 40 ]]; then
  VEREDITO="ATUALIZAR ANTES DE QUALQUER TUNING"; SEVERIDADE="critico"
  ACOES+=("software sem suporte: sem correcao de seguranca")
  [[ -n "$SW_ACAO" ]] && ACOES+=("$SW_ACAO")
  ACOES+=("tunar sistema vencido e investir no lugar errado")
elif [[ $HW -lt 45 ]]; then
  VEREDITO="HARDWARE NO FIM DA VIDA"; SEVERIDADE="alerta"
  ACOES+=("score de hardware ${HW}/100 — o custo de manter supera o ganho")
  hasf pcid || ACOES+=("sem PCID: trocar por Xeon serie 5600 (Westmere) resolve, e custa pouco usado")
  ACOES+=("alternativas: manter em PVE 8 isolado, virar storage/backup, ou aposentar")
elif [[ $IO -lt 40 && $BENCH_RAN -eq 1 ]]; then
  VEREDITO="GARGALO DE DISCO"; SEVERIDADE="alerta"
  ACOES+=("IO ${IO}/100 para a classe ${DISK_CLASS} — tuning de CPU/rede nao vai ajudar")
  [[ "$DISK_CLASS" == "hdd" ]] && ACOES+=("HDD com VMs: migrar para SSD e o unico ganho real")
  ACOES+=("verifique controladora, cache de escrita e alinhamento antes de tunar")
elif [[ $TUNE -eq 0 ]]; then
  VEREDITO="APLICAR TUNING"; SEVERIDADE="acao"
  ACOES+=("nenhum perfil aplicado; carga detectada sugere '${SUG_PROFILE}'")
  ACOES+=("tune-profile.sh --profile ${SUG_PROFILE} --dry-run")
  ACOES+=("tune-profile.sh --profile ${SUG_PROFILE}")
elif [[ $TUNE -lt 70 ]]; then
  VEREDITO="TUNING DEFASADO"; SEVERIDADE="acao"
  ACOES+=("perfil aplicado mas desatualizado (${TUNE}/100)")
  [[ -n "$TUNE_ACAO" ]] && ACOES+=("$TUNE_ACAO")
elif [[ $SW -lt 70 ]]; then
  VEREDITO="SOLIDO — PLANEJE O UPGRADE"; SEVERIDADE="ok"
  ACOES+=("sistema saudavel; software ainda suportado mas ja com sucessor estavel")
  [[ -n "$SW_ACAO" ]] && ACOES+=("quando houver janela: ${SW_ACAO}")
else
  VEREDITO="SISTEMA SOLIDO"; SEVERIDADE="ok"
  ACOES+=("nada a fazer — hardware capaz, software atual, tuning coerente")
  ACOES+=("mantenha o acompanhamento: validate.sh e pkops drift no cron")
fi

# acoes complementares (independentes do veredito principal)
[[ "$ROLE" == "pve-host" && "$PVE_TUNE" == "nao" ]] && \
  ACOES+=("host PVE sem tuning para este kernel: proxmox_tune.sh")
[[ ${DISK_USED_PCT:-0} -ge 85 ]] && \
  ACOES+=("disco ${DISK_USED_PCT}% cheio — limpe antes de qualquer upgrade")
[[ $SWAP_MB -eq 0 && $RAM_MB -lt 8192 ]] && \
  ACOES+=("sem swap com ${RAM_MB}MB de RAM: OOM killer sem valvula de escape")
[[ ${NUMA_NODES:-1} -gt 1 && "$ROLE" == "pve-host" ]] && \
  ACOES+=("${NUMA_NODES} nos NUMA: verifique pinning das VMs (hostnodes=)")
[[ $BENCH_RAN -eq 0 && $FULL -eq 0 ]] && \
  ACOES+=("rode com --full para medir disco e fechar o eixo IO")

if [[ $JSON -eq 0 ]]; then
  h1 "Veredito"
  case "$SEVERIDADE" in
    critico) printf '  %s%s%s\n' "$C_R" "$VEREDITO" "$C_0" ;;
    alerta)  printf '  %s%s%s\n' "$C_Y" "$VEREDITO" "$C_0" ;;
    acao)    printf '  %s%s%s\n' "$C_B" "$VEREDITO" "$C_0" ;;
    *)       printf '  %s%s%s\n' "$C_G" "$VEREDITO" "$C_0" ;;
  esac
  p ""
  h1 "Prescricao"
  i=1
  for a in "${ACOES[@]}"; do printf '  %d. %s\n' "$i" "$a"; i=$((i+1)); done
  p ""
  p "  ${C_D}validar depois:  validate.sh${C_0}"
  p "  ${C_D}registrar:       pkops manifest${C_0}"
else
  printf '{"host":"%s","tool":"%s","version":"%s","ts":"%s",' "$(hostname)" "$TOOL" "$VERSION" "$(date -Is)"
  printf '"role":"%s","product":"%s","virt":"%s",' "$ROLE" "$PRODUCT" "$VIRT"
  printf '"cpu":{"model":"%s","cores":%d,"sockets":%d,"x86_level":%d,"pcid":%s,"aes":%s},' \
    "$CPU_MODEL" "$CORES" "$SOCKETS" "$X86LVL" \
    "$(hasf pcid && echo true || echo false)" "$(hasf aes && echo true || echo false)"
  printf '"mem":{"total_mb":%d,"avail_mb":%d,"swap_mb":%d,"numa_nodes":%d},' \
    "$RAM_MB" "$RAM_AVAIL_MB" "$SWAP_MB" "$NUMA_NODES"
  printf '"disk":{"class":"%s","fs":"%s","used_pct":%d,"free_gb":%d},' \
    "$DISK_CLASS" "$ROOT_FS" "${DISK_USED_PCT:-0}" "${DISK_FREE_GB:-0}"
  printf '"os":{"debian":"%s","kernel":"%s","pve":"%s"},' "$CODENAME" "$KERNEL" "${PVE_VER:-}"
  printf '"steal_pct":%d,"suggested_profile":"%s","current_profile":"%s",' \
    "${STEAL:-0}" "$SUG_PROFILE" "${TUNE_PROFILE_ATUAL:-}"
  printf '"bench":{"ran":%s,"iops_read":%d,"iops_write":%d,"fsync":%d},' \
    "$([[ $BENCH_RAN -eq 1 ]] && echo true || echo false)" "${IOPS_R:-0}" "${IOPS_W:-0}" "${FSYNC:-0}"
  printf '"scores":{"hw":%d,"sw":%d,"io":%d,"tune":%d},' "$HW" "$SW" "$IO" "$TUNE"
  printf '"verdict":{"severity":"%s","text":"%s","actions":[' "$SEVERIDADE" "$VEREDITO"
  first=1; for a in "${ACOES[@]}"; do [[ $first -eq 0 ]] && printf ','; first=0; printf '"%s"' "${a//\"/\\\"}"; done
  printf ']}}\n'
fi

# registra no pkops, se disponivel
if declare -f pk_state_set >/dev/null 2>&1; then
  pk_state_set assessment "hw=$HW" "sw=$SW" "io=$IO" "tune=$TUNE" \
    "role=$ROLE" "verdict=$SEVERIDADE" "suggested=$SUG_PROFILE" >/dev/null 2>&1 || true
  pk_emit "assessment.done" "hw=$HW sw=$SW io=$IO tune=$TUNE verdito=${SEVERIDADE}" >/dev/null 2>&1 || true
fi

case "$SEVERIDADE" in
  critico) exit 3 ;;
  alerta)  exit 2 ;;
  acao)    exit 1 ;;
  *)       exit 0 ;;
esac
