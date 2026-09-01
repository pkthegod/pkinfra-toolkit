#!/usr/bin/env bash
#
# pve-upgrade.sh v3.6.0 — upgrade idempotente Proxmox VE 6 -> 7 -> 8 -> 9.2
#
# Par de proxmox_tune.sh. Compartilham /var/lib/pve-maint (schema 1).
#   upgrade = pontual (3-4x na vida do servidor), ABORTA em bloqueador
#   tuning  = recorrente (a cada kernel novo),    NUNCA aborta
#
# FLUXO POR SERVIDOR:
#   1. ./pve-upgrade.sh --assess      score de hardware + versao-alvo
#   2. ./pve-upgrade.sh               dry-run
#   3. ./pve-upgrade.sh --apply       executa ate o proximo reboot
#   4. reboot
#   5. ./pve-upgrade.sh --validate    valida o salto + compara benchmark
#   6. ./proxmox_tune.sh              re-tuna no kernel novo
#   7. repete 2-6 ate o target
#
# CHEGAR AO 9.2 EXIGE UMA PASSADA EXTRA: o salto 8->9 aterrissa no 9.0 e
# para. Os minors 9.0 -> 9.1 -> 9.2 (kernel 7.0) so vem rodando --apply DE
# NOVO depois do reboot. "Cheguei ao PVE 9" nao e "cheguei ao 9.2".
#
# PORTAO: antes de CADA dist-upgrade, confere que o proxmox-ve tem
#         candidato e que a simulacao nao o remove. Repo enterprise sem
#         subscricao (401) e a causa mais comum de o salto 7->8 abortar.
#
# MODOS:  --assess  --validate  --status  --check
# FLAGS:  --target N[.M]  --yes  --allow-ssh  --allow-console
#         --skip-checker  --no-checker  --checker-timeout N
#         --force-hw  --force-cgroup  --keep-enterprise
#
# --skip-checker IGNORA falhas do pveNtoN+1, mas ele ainda RODA.
# --no-checker   nao roda o checador. E o que resolve travamento nele.
#
# OS DOIS --force NAO SAO A MESMA COISA:
#   --force-hw      ignora o veto de score do --assess. Custa PERFORMANCE.
#   --force-cgroup  atropela o bloqueio de CT legado no 8->9. O CT NAO
#                   INICIA MAIS — cgroupv1 foi removido do PVE 9.
# Eram uma flag so ate a v3.3.0, e quem forcava hardware levava junto, em
# silencio, o bypass que para servico.
#
# MAPA:  PVE 6=buster/5.4  7=bullseye/5.15  8=bookworm/6.2-6.14
#        PVE 9=trixie: 9.0=6.14  9.1=6.17  9.2=7.0 (QEMU 11, ZFS 2.4)
#
set -uo pipefail

TOOL="pve-upgrade"
VERSION="3.6.0"

# ==== BLOCO DE ESTADO COMPARTILHADO (schema 1) ==============================
# IDENTICO em pve-upgrade.sh e proxmox_tune.sh.
# Ao alterar, altere nos DOIS e incremente STATE_SCHEMA.
STATE_SCHEMA=2
STATE_ROOT="/var/lib/pve-maint"
STATE_LEGACY="/var/lib/pve-upgrade"
EVENT_LOG="$STATE_ROOT/events.log"
FACTS_FILE="$STATE_ROOT/facts.env"
BENCH_DIR="$STATE_ROOT/bench"
TUNE_DIR="$STATE_ROOT/tune"

state_init() {
    mkdir -p "$STATE_ROOT" "$BENCH_DIR" "$TUNE_DIR" 2>/dev/null || true
    # migracao do diretorio antigo (idempotente)
    if [[ -d "$STATE_LEGACY" && ! -f "$STATE_ROOT/.migrated" ]]; then
        cp -an "$STATE_LEGACY/." "$STATE_ROOT/" 2>/dev/null || true
        : > "$STATE_ROOT/.migrated"
    fi
    echo "$STATE_SCHEMA" > "$STATE_ROOT/.schema" 2>/dev/null || true
}

state_event() {   # <evento> [detalhe]
    mkdir -p "$STATE_ROOT" 2>/dev/null || true
    printf '%s|%s|%s|%s|%s|%s\n' \
        "$(date -Is)" "$(hostname)" "$TOOL" "$VERSION" "$1" "${2:-}" \
        >> "$EVENT_LOG" 2>/dev/null || true
}

# Fatos de hardware — escritos por quem rodar primeiro, lidos pelos dois.
# NOTA: tudo e calculado em variaveis ANTES do heredoc. Nao use $( ) com
# aspas simples dentro do heredoc: o '\$' nao e removido e quebra o awk.
state_facts_write() {
    mkdir -p "$STATE_ROOT" 2>/dev/null || true
    local flags cpu ram cores numa pcid aes prod pve deb
    flags=$(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo)
    cpu=$(awk -F: '/^model name/{sub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)
    ram=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    cores=$(nproc 2>/dev/null || echo 0)
    numa=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
    grep -qw pcid <<<"$flags" && pcid=1 || pcid=0
    grep -qw aes  <<<"$flags" && aes=1  || aes=0
    prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
    pve=$(pveversion 2>/dev/null | head -1 | grep -oP 'pve-manager/\K[^ /]+')
    deb=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-unknown}")

    cat > "$FACTS_FILE" <<FACTS
# gerado por ${TOOL} v${VERSION} em $(date -Is)
FACT_HOST=$(hostname)
FACT_PRODUCT=${prod}
FACT_CPU=${cpu}
FACT_CORES=${cores}
FACT_RAM_MB=${ram}
FACT_NUMA_NODES=${numa}
FACT_PCID=${pcid}
FACT_AES=${aes}
FACT_KERNEL=$(uname -r)
FACT_PVE=${pve:-desconhecido}
FACT_DEBIAN=${deb}
FACTS
}

state_facts_read() { [[ -f "$FACTS_FILE" ]] && . "$FACTS_FILE" 2>/dev/null || true; }

# Existe tuning aplicado e valido para o kernel que esta rodando agora?
state_tune_current() { [[ -f "$TUNE_DIR/state-$(uname -r).env" ]]; }

# Ordem de RELEASE dos codinomes. Ordenar por alfabeto era o bug: bullseye
# vem depois de bookworm no dicionario, mas bookworm e a release mais nova.
deb_rank() {
    case "${1:-}" in
        buster)   echo 10 ;;
        bullseye) echo 11 ;;
        bookworm) echo 12 ;;
        trixie)   echo 13 ;;
        *)        echo 0  ;;
    esac
}

# Codinomes citados pelos repositorios, um por linha, sem repetir.
repo_codenames() {
    grep -rhoE '\b(buster|bullseye|bookworm|trixie)\b' \
         /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | sort -u
}

# O codinome mais novo citado — por release, nunca por alfabeto.
repo_codename_newest() {
    local c best="" bestr=0 r
    while read -r c; do
        [[ -z "$c" ]] && continue
        r=$(deb_rank "$c")
        [[ $r -gt $bestr ]] && { bestr=$r; best="$c"; }
    done < <(repo_codenames)
    echo "$best"
}

# Codinomes ANTERIORES ao do sistema ainda presentes nos repos. Nao e upgrade
# em voo: e residuo do salto anterior. Confunde o apt e confunde o operador,
# mas tratar como "upgrade em andamento" e o que travava o tuning.
repo_codenames_stale() {
    local sys c out="" rsys
    sys=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
    [[ -z "$sys" ]] && return 0
    rsys=$(deb_rank "$sys")
    while read -r c; do
        [[ -z "$c" ]] && continue
        [[ $(deb_rank "$c") -lt $rsys ]] && out="$out $c"
    done < <(repo_codenames)
    echo "${out# }"
}

# Upgrade EM VOO = os repos ja apontam para release MAIS NOVA que a do
# sistema. Direcional de proposito: repo mais VELHO que o sistema e residuo,
# e residuo nao se "retoma" — se limpa.
state_upgrade_inflight() {
    local running newest
    running=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
    newest=$(repo_codename_newest)
    [[ -n "$newest" && -n "$running" ]] || return 1
    [[ $(deb_rank "$newest") -gt $(deb_rank "$running") ]]
}

# Sobe a arvore de processos procurando um ancestral. Preciso: nao usa
# pgrep global, que dispara com termproxy de OUTRA sessao no mesmo host.
state_has_ancestor() {   # <regex de comm>
    local pat="$1" pid=$$ depth=0 comm
    while [[ "$pid" -gt 1 && $depth -lt 30 ]]; do
        comm=$(cat "/proc/$pid/comm" 2>/dev/null) || return 1
        [[ "$comm" =~ $pat ]] && return 0
        pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
        [[ -z "$pid" ]] && return 1
        depth=$((depth+1))
    done
    return 1
}
state_in_web_console() { state_has_ancestor '^(termproxy|vncterm|spiceterm)$'; }
state_in_ssh()         { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]] || state_has_ancestor '^sshd$'; }
state_in_mux()         { [[ -n "${TMUX:-}${STY:-}" ]] || state_has_ancestor '^(tmux|screen)'; }
# ==== FIM DO BLOCO COMPARTILHADO ============================================

BACKUP_DIR="$STATE_ROOT/backups/$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$STATE_ROOT/run-upgrade-$(date +%Y%m%d-%H%M%S).log"

APPLY=0; ASSUME_YES=0; ALLOW_SSH=0; SKIP_CHECKER=0; ALLOW_CONSOLE=0
FORCE_HW=0; FORCE_CGROUP=0
NO_CHECKER=0; KEEP_ENTERPRISE=0; CHECKER_TIMEOUT=600
# TARGET_FULL pode ter minor ("9.2"); TARGET e so o major, usado no despacho
# de fase. A separacao nao e cosmetica: [[ 9 -ge 9.2 ]] aborta o script porque
# o bash trata como aritmetica e "9.2" nao e inteiro valido.
TARGET_FULL="9.2"; TARGET=9; MODE="run"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)        APPLY=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    --status)       MODE="status" ;;
    --check)        MODE="check" ;;
    --assess)       MODE="assess" ;;
    --validate)     MODE="validate" ;;
    --allow-ssh)     ALLOW_SSH=1 ;;
    --allow-console) ALLOW_CONSOLE=1 ;;
    --skip-checker) SKIP_CHECKER=1 ;;
    --no-checker)   NO_CHECKER=1 ;;
    --keep-enterprise) KEEP_ENTERPRISE=1 ;;
    --checker-timeout)
        CHECKER_TIMEOUT="${2:-600}"; shift
        if [[ ! "$CHECKER_TIMEOUT" =~ ^[0-9]+$ ]]; then
          echo "--checker-timeout precisa ser numero de segundos"; exit 2
        fi
        ;;
    --force-hw)     FORCE_HW=1 ;;
    --force-cgroup) FORCE_CGROUP=1 ;;
    --target)
        TARGET_FULL="${2:-}"; shift
        [[ "$TARGET_FULL" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
          || { echo "--target invalido: '$TARGET_FULL' (use 7, 8, 9 ou 9.2)"; exit 2; }
        TARGET="${TARGET_FULL%%.*}"
        ;;
    --help|-h)      sed -n '2,43p' "$0"; exit 0 ;;
    *) echo "flag desconhecida: $1 (use --help)"; exit 2 ;;
  esac
  shift
done

# ------------------------------------------------------------ saida

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
[[ -t 1 ]] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; }

log()  { printf '%s\n' "$*" | tee -a "$RUN_LOG" 2>/dev/null || printf '%s\n' "$*"; }
info() { log "${C_B}::${C_0} $*"; }
ok()   { log "${C_G}OK${C_0} $*"; }
warn() { log "${C_Y}!!${C_0} $*"; }
err()  { log "${C_R}XX${C_0} $*"; }
head1(){ log ""; log "${C_B}==== $* ====${C_0}"; }

die() { err "$*"; state_event "ABORT" "$*"; exit 1; }

run() {
  if [[ $APPLY -eq 1 ]]; then
    log "   \$ $*"; "$@" >>"$RUN_LOG" 2>&1; local rc=$?
    [[ $rc -ne 0 ]] && warn "retorno $rc (ver $RUN_LOG)"
    return $rc
  else
    log "   ${C_Y}[dry]${C_0} $*"; return 0
  fi
}

confirm() {
  [[ $APPLY -eq 0 || $ASSUME_YES -eq 1 ]] && return 0
  local r; read -rp "   >> $1 [digite SIM]: " r </dev/tty; [[ "$r" == "SIM" ]]
}

backup_file() {
  [[ -f "$1" ]] || return 0
  [[ $APPLY -eq 1 ]] && { mkdir -p "$BACKUP_DIR$(dirname "$1")"; cp -a "$1" "$BACKUP_DIR$(dirname "$1")/"; }
  return 0
}

# ------------------------------------------------------------ estado do host

pve_major() {
  local v
  v=$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9]+' | head -1)
  [[ -z "$v" ]] && v=$(dpkg-query -W -f='${Version}' proxmox-ve 2>/dev/null | grep -oP '^\K[0-9]+')
  echo "${v:-0}"
}
pve_full()   { pveversion 2>/dev/null | head -1 | grep -oP 'pve-manager/\K[^ /]+'; }
deb_code()   { . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-unknown}"; }
ver_ge()     { dpkg --compare-versions "$1" ge "$2"; }
# Ceph CONFIGURADO, nao apenas o binario presente. O ceph-common chega como
# dependencia em host que nunca configurou Ceph; testar pelo binario fazia
# 'ceph health' voltar vazio e a validacao REPROVAR o host por um servico
# que ele nao usa. Ausencia de Ceph nao e defeito deste host.
has_ceph()   { [[ -f /etc/pve/ceph.conf ]]; }
is_uefi()    { [[ -d /sys/firmware/efi ]]; }
root_is_zfs(){ findmnt -no FSTYPE / 2>/dev/null | grep -q zfs; }
ram_mb()     { awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo; }
is_cluster() { [[ -f /etc/pve/corosync.conf ]]; }
dmi_product(){ cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown; }
is_dell_11g(){ dmi_product | grep -qiE 'PowerEdge (R[2-9]10|T[36]10|M610|M710)'; }
is_poweredge(){ dmi_product | grep -qi 'PowerEdge'; }

reboot_pending() {
  local newest
  newest=$(dpkg-query -W -f='${Package}\n' 'proxmox-kernel-*-pve' 'pve-kernel-*-pve' 2>/dev/null \
           | grep -oP '\d+\.\d+\.\d+-\d+' | sort -V | tail -1)
  [[ -n "$newest" ]] && [[ "$(uname -r)" != *"$newest"* ]]
}

CPUFLAGS=""
cpu_flags() { [[ -n "$CPUFLAGS" ]] || CPUFLAGS=$(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo); echo "$CPUFLAGS"; }
has_flag()  { grep -qw "$1" <<<"$(cpu_flags)"; }

x86_level() {
  local v2=1 v3=1 v4=1 f
  for f in cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3;     do has_flag "$f" || v2=0; done
  for f in avx avx2 bmi1 bmi2 f16c fma abm movbe;       do has_flag "$f" || v3=0; done
  for f in avx512f avx512bw avx512cd avx512dq avx512vl; do has_flag "$f" || v4=0; done
  if   [[ $v4 -eq 1 ]]; then echo 4; elif [[ $v3 -eq 1 ]]; then echo 3
  elif [[ $v2 -eq 1 ]]; then echo 2; else echo 1; fi
}

cgroupv1_cts() {
  local bad=""
  command -v pct >/dev/null 2>&1 || { echo ""; return; }
  while read -r id _; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    pct config "$id" 2>/dev/null | grep -qiE 'centos-[67]|ubuntu-1[46]|debian-8' && bad="$bad $id"
  done < <(pct list 2>/dev/null | tail -n +2)
  echo "$bad"
}

pci_passthrough_count() { grep -lE '^hostpci[0-9]+:' /etc/pve/qemu-server/*.conf 2>/dev/null | wc -l; }

# ------------------------------------------------------------ benchmark

bench_save() {
  command -v pveperf >/dev/null || { warn "pveperf indisponivel"; return 1; }
  mkdir -p "$BENCH_DIR"
  # declaracao separada da atribuicao: `local f=$(...)` engole o status de
  # saida do subshell (SC2155) e um pve_major que falhe passaria calado.
  local f
  f="$BENCH_DIR/pve$(pve_major)-$(uname -r).txt"
  [[ -f "$f" ]] && { info "baseline ja existe: $(basename "$f")"; return 0; }
  info "rodando pveperf (~30s)"
  local out; out=$(pveperf 2>/dev/null) || return 1
  { echo "# $(date -Is) pve=$(pve_full) kernel=$(uname -r)"; echo "$out"; } > "$f"
  ok "baseline salvo: $(basename "$f")"
  state_event "BENCH_SAVED" "pve$(pve_major) kernel=$(uname -r)"
}

bench_metric() { grep -oP "^$2:\s*\K[0-9.]+" "$1" 2>/dev/null | head -1; }

bench_compare() {
  head1 "Benchmark entre versoes"
  local n; n=$(ls "$BENCH_DIR"/pve*.txt 2>/dev/null | wc -l)
  [[ ${n:-0} -lt 2 ]] && { info "so ha $n baseline; comparacao aparece apos o proximo salto"; return 0; }
  local cur prev
  cur=$(ls -t "$BENCH_DIR"/pve*.txt | sed -n 1p)
  prev=$(ls -t "$BENCH_DIR"/pve*.txt | sed -n 2p)
  log "  anterior : $(basename "$prev")"
  log "  atual    : $(basename "$cur")"; log ""
  printf '  %-18s %12s %12s %9s\n' "metrica" "anterior" "atual" "delta"
  local m a b d
  for m in "REGEX/SECOND" "BUFFERED READS" "FSYNCS/SECOND"; do
    a=$(bench_metric "$prev" "$m"); b=$(bench_metric "$cur" "$m")
    [[ -z "$a" || -z "$b" ]] && continue
    d=$(awk -v a="$a" -v b="$b" 'BEGIN{printf "%+.1f%%", (b-a)/a*100}')
    printf '  %-18s %12s %12s %9s\n' "$m" "$a" "$b" "$d"
    awk -v a="$a" -v b="$b" 'BEGIN{exit !((a-b)/a > 0.15)}' && \
      warn "  ^ queda >15% em '$m' — cache frio? mitigacoes? governor?"
  done
  state_event "BENCH_COMPARED" "$(basename "$prev") vs $(basename "$cur")"
}

# ------------------------------------------------------------ guests

guests_snapshot() {
  mkdir -p "$STATE_ROOT"
  { qm list 2>/dev/null | tail -n +2 | awk '{print "vm", $1, $3}'
    pct list 2>/dev/null | tail -n +2 | awk '{print "ct", $1, $2}'; } | sort \
    > "$STATE_ROOT/guests-pre.txt"
  ok "estado de $(wc -l < "$STATE_ROOT/guests-pre.txt") guests registrado"
}

guests_compare() {
  local pre="$STATE_ROOT/guests-pre.txt"
  [[ -f "$pre" ]] || { info "sem snapshot previo de guests"; return 0; }
  local now="$STATE_ROOT/guests-now.txt"
  { qm list 2>/dev/null | tail -n +2 | awk '{print "vm", $1, $3}'
    pct list 2>/dev/null | tail -n +2 | awk '{print "ct", $1, $2}'; } | sort > "$now"
  if diff -q "$pre" "$now" >/dev/null 2>&1; then
    ok "todos os guests no mesmo estado de antes"
  else
    warn "diferencas de estado nos guests:"
    diff "$pre" "$now" | grep -E '^[<>]' | sed 's/^</  antes:/; s/^>/  agora:/' | tee -a "$RUN_LOG"
  fi
}

# ------------------------------------------------------------ sysctl (colisao)

# Chaves definidas em mais de um arquivo de /etc/sysctl.d — quem vence e o
# de nome lexicograficamente maior. Reportar evita "tuning que nao pega".
sysctl_collisions() {
  local files=(/etc/sysctl.d/*.conf /etc/sysctl.conf)
  local dup
  dup=$(grep -hoP '^\s*\K[a-z0-9_.]+(?=\s*=)' "${files[@]}" 2>/dev/null \
        | sort | uniq -d)
  [[ -z "$dup" ]] && return 0
  warn "chaves sysctl definidas em mais de um arquivo (vence o de nome maior):"
  local k
  while read -r k; do
    [[ -z "$k" ]] && continue
    local where
    where=$(grep -lE "^\s*${k//./\\.}\s*=" "${files[@]}" 2>/dev/null | tr '\n' ' ')
    log "     $k  ->  $where"
  done <<<"$dup"
  warn "valor efetivo: sysctl -n <chave>"
}

# ------------------------------------------------------------ assess

hw_assess() {
  head1 "AVALIACAO DE HARDWARE — $(hostname)"
  state_init; state_facts_write

  local model lvl ram cores prod
  model=$(awk -F: '/^model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)
  lvl=$(x86_level); ram=$(ram_mb); cores=$(nproc); prod=$(dmi_product)

  log "  maquina    : $prod"
  log "  CPU        : $model"
  log "  cores/thr  : $cores   nivel x86-64: v$lvl"
  log "  RAM        : ${ram} MB"
  log "  PVE atual  : $(pve_full) / Debian $(deb_code) / kernel $(uname -r)"
  log "  boot       : $(is_uefi && echo UEFI || echo BIOS)$(root_is_zfs && echo ' + ZFS root')"

  local score=100
  local -a blockers=() penalties=()

  head1 "Fatores de performance"
  if has_flag pcid; then ok "PCID presente — custo do KPTI controlado"
  else
    score=$((score-35)); penalties+=("sem PCID (Nehalem/pre-2010): KPTI custa 20-40%")
    err "PCID AUSENTE — kernel novo doi bastante nesta CPU"
  fi
  if has_flag aes; then ok "AES-NI presente"
  else score=$((score-15)); penalties+=("sem AES-NI: cripto em software"); warn "AES-NI ausente"; fi
  if [[ $lvl -ge 3 ]]; then ok "x86-64-v$lvl (AVX2 ativo)"
  else score=$((score-10)); penalties+=("x86-64-v$lvl: sem caminhos AVX2"); info "x86-64-v$lvl"; fi
  if [[ $ram -lt 16000 ]]; then
    score=$((score-20)); penalties+=("RAM ${ram}MB: /tmp tmpfs usa ate $((ram/2))MB")
    warn "RAM baixa para Debian 13"
  elif [[ $ram -lt 32000 ]]; then
    score=$((score-5)); penalties+=("RAM ${ram}MB: monitore /tmp tmpfs")
  else ok "RAM confortavel para o /tmp tmpfs do Debian 13"; fi

  head1 "Especifico do hardware"
  if is_dell_11g; then
    warn "Dell 11G ($prod):"
    warn " - kernels 6.17+/7.0 tem relatos de machine-check no boot em PowerEdge"
    warn "   mitigacao: SR-IOV Global + I/OAT DMA no BIOS"
    warn "   plano B:   proxmox-boot-tool kernel pin <6.14.x>"
    if dpkg -l pve-firmware 2>/dev/null | grep -q '^ii'; then
      ok "   pve-firmware instalado (cobre bnx2/bnx2x)"
    else
      score=$((score-10)); penalties+=("pve-firmware ausente: NIC bnx2 sem firmware")
      err "   pve-firmware AUSENTE — instale antes de subir (rede pode sumir)"
    fi
  elif is_poweredge; then
    info "PowerEdge: se falhar boot no 6.17+/7.0, habilite SR-IOV + I/OAT ou pin no 6.14"
  fi

  head1 "Bloqueadores / limitadores"
  local bad; bad=$(cgroupv1_cts)
  if [[ -n "${bad// /}" ]]; then
    warn "CTs legados (systemd <= 230):$bad"
    warn " - PVE 7/8: exigem systemd.unified_cgroup_hierarchy=0 na cmdline"
    err  " - PVE 9: NAO INICIAM (cgroupv1 removido)"
    blockers+=("CTs legados p/ PVE 9:$bad")
  else ok "nenhum container com systemd <= 230"; fi

  local npci; npci=$(pci_passthrough_count)
  if [[ ${npci:-0} -gt 0 ]]; then
    score=$((score-15)); penalties+=("$npci VMs com PCI passthrough: regressoes no 6.14/6.17")
    warn "$npci VMs usam hostpci — teste logo apos o salto"
  else ok "nenhuma VM com PCI passthrough"; fi

  if has_ceph; then
    local cv; cv=$(ceph version 2>/dev/null | grep -oP 'version \K\d+')
    [[ -n "$cv" ]] && info "Ceph v$cv (PVE7:15+  PVE8:17+  PVE9:19.2)"
    [[ -n "$cv" && ${cv:-0} -lt 19 ]] && blockers+=("Ceph v$cv < Squid 19.2 p/ PVE 9")
  fi

  sysctl_collisions

  head1 "Benchmark (pveperf)"
  bench_save || true

  head1 "Veredito"
  [[ ${#blockers[@]}  -gt 0 ]] && { err  "Bloqueadores p/ PVE 9:"; printf '     - %s\n' "${blockers[@]}"  | tee -a "$RUN_LOG"; }
  [[ ${#penalties[@]} -gt 0 ]] && { warn "Penalidades:";           printf '     - %s\n' "${penalties[@]}" | tee -a "$RUN_LOG"; }

  log ""; log "  Score: ${score}/100"; log ""
  log "  Referencia Dell 11G (decide a CPU, nao o chassi):"
  log "    R410/R610 Nehalem  (E5504/E5520/X5570) ...... ~20-35 -> PVE 8"
  log "    R610/R710 Westmere (E5620/X5650/X5670) ...... ~85-90 -> PVE 9.2"
  log "    Haswell+ (E5 v3+) ........................... ~100   -> PVE 9.2"
  log ""

  local rec=9.2
  if   [[ ${#blockers[@]} -gt 0 ]]; then rec=8; err "Resolva os bloqueadores antes do PVE 9."
  elif [[ $score -ge 70 ]]; then ok "RECOMENDADO: subir ate o PVE 9.2."
  elif [[ $score -ge 45 ]]; then
    warn "VIAVEL COM RESSALVAS: PVE 9.2 roda com perda de performance."
    warn "  PVE 8 saiu de suporte (~jul/2026); ficar parado tambem e risco."
  else rec=8
    err "NAO RECOMENDADO subir ao PVE 9 por PERFORMANCE."
    err "  Melhor uso: PVE 8 isolado, storage/backup, ou aposentar."
  fi

  # O veto acima e de PERFORMANCE e nao se sustenta sozinho quando o driver
  # e seguranca: o PVE 8 saiu de suporte e o kernel 7.0 so existe no 9.2.
  # Sem dizer isso aqui, o host fica parado no 8 por um motivo que ninguem
  # reavaliou — e o --assess vira o carimbo que justifica a exposicao.
  if ! dpkg --compare-versions "$rec" ge "9.2"; then
    warn "CONSEQUENCIA: parando em $rec, este host fica ABAIXO do kernel 7.0"
    warn "  (7.0 = PVE 9.2; 9.1 = 6.17; 9.0 = 6.14)"
    warn "  Se o driver for seguranca, as opcoes reais sao trocar o hardware,"
    warn "  aposentar o host, ou assumir a perda: --target 9.2 --force-hw"
  fi

  log ""; log "  Proximo: ./pve-upgrade.sh --apply --target $rec"
  state_event "ASSESS" "score=$score rec=$rec prod=$prod lvl=v$lvl ram=$ram"
  echo "$score" > "$STATE_ROOT/hw-score"
  echo "$rec"   > "$STATE_ROOT/hw-target"
}

# ------------------------------------------------------------ validate

validate_stack() {
  head1 "VALIDACAO — PVE $(pve_full) / kernel $(uname -r)"
  state_init
  local fail=0

  head1 "1/7 Servicos"
  local svcs="pve-cluster pvedaemon pveproxy pvestatd"
  is_cluster && svcs="$svcs corosync"
  local s
  for s in $svcs; do
    systemctl is-active --quiet "$s" && ok "$s ativo" || { err "$s INATIVO"; fail=1; }
  done

  head1 "2/7 pmxcfs"
  if [[ -f /etc/pve/local/pve-ssl.pem || -d /etc/pve/nodes ]]; then ok "/etc/pve montado"
  else err "/etc/pve vazio — pmxcfs nao subiu"; fail=1; fi

  head1 "3/7 Storages"
  local badst
  badst=$(pvesm status 2>/dev/null | awk 'NR>1 && $3!="active" && $3!="available" {print $1" ("$3")"}')
  [[ -z "$badst" ]] && ok "todos os storages ativos" \
    || { warn "storages fora do ar:"; echo "$badst" | sed 's/^/     /' | tee -a "$RUN_LOG"; }

  head1 "4/7 Rede"
  local br
  for br in $(awk '/^auto vmbr/{print $2}' /etc/network/interfaces 2>/dev/null); do
    ip link show "$br" 2>/dev/null | grep -q 'state UP' && ok "bridge $br UP" \
      || { err "bridge $br DOWN"; fail=1; }
  done
  ip route get 1.1.1.1 >/dev/null 2>&1 && ok "rota default ok" || { err "sem rota default"; fail=1; }
  local missing
  missing=$(awk '/^iface (en|eth)/{print $2}' /etc/network/interfaces 2>/dev/null \
    | while read -r i; do ip link show "$i" >/dev/null 2>&1 || echo "$i"; done)
  [[ -n "$missing" ]] && { err "NICs do config que sumiram (renomeadas?): $missing"; fail=1; }

  head1 "5/7 Guests"
  guests_compare

  head1 "6/7 Benchmark"
  bench_save; bench_compare

  head1 "7/7 Tuning"
  if state_tune_current; then
    ok "tuning aplicado neste kernel ($(uname -r))"
    . "$TUNE_DIR/state-$(uname -r).env" 2>/dev/null || true
    log "     tune v${TUNE_VERSION:-?}  swappiness=${TUNE_SWAPPINESS:-?}  numa_balancing=${TUNE_NUMA_BAL:-?}"
  else
    warn "SEM tuning para o kernel atual — o conjunto de chaves sysctl mudou"
    warn "   rode: ./proxmox_tune.sh"
  fi
  sysctl_collisions

  if is_cluster; then
    head1 "Cluster"
    pvecm status 2>/dev/null | grep -q 'Quorate:.*Yes' && ok "quorum OK" || { err "SEM QUORUM"; fail=1; }
  fi
  if has_ceph; then
    head1 "Ceph"
    local ch; ch=$(ceph health 2>/dev/null)
    case "$ch" in
      HEALTH_OK*)   ok "$ch" ;;
      HEALTH_WARN*) warn "$ch" ;;
      *)            err "${ch:-ceph inacessivel}"; fail=1 ;;
    esac
  fi

  local pend
  pend=$(find /etc \( -name '*.dpkg-dist' -o -name '*.dpkg-new' \) 2>/dev/null | head -5)
  [[ -n "$pend" ]] && { warn "conffiles pendentes:"; echo "$pend" | sed 's/^/     /'; }

  head1 "Resultado"
  state_facts_write
  if [[ $fail -eq 0 ]]; then
    ok "validacao passou"
    state_event "VALIDATE_PASS" "pve=$(pve_full) kernel=$(uname -r)"
    state_tune_current || warn "proximo passo: ./proxmox_tune.sh (antes do proximo salto)"
  else
    err "validacao FALHOU — corrija antes de prosseguir"
    state_event "VALIDATE_FAIL" "pve=$(pve_full)"; exit 1
  fi
}

# ------------------------------------------------------------ preflight

preflight() {
  head1 "FASE 00 — Preflight"
  [[ $EUID -eq 0 ]] || die "precisa ser root"
  command -v pveversion >/dev/null || die "nao parece um host Proxmox VE"
  state_init; state_facts_write

  info "PVE $(pve_full) | Debian $(deb_code) | kernel $(uname -r) | target $TARGET_FULL"

  if [[ -f "$STATE_ROOT/hw-target" && $FORCE_HW -eq 0 ]]; then
    local hwt; hwt=$(cat "$STATE_ROOT/hw-target" 2>/dev/null)
    # dpkg, nunca [[ -gt ]]: o alvo passou a ter minor e o teste aritmetico
    # do bash morre em "9.2: invalid arithmetic operator".
    if [[ ! "$hwt" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      warn "hw-target ilegivel ('$hwt') — rode --assess de novo; seguindo sem veto"
    elif dpkg --compare-versions "$TARGET_FULL" gt "$hwt"; then
      err "--assess recomendou target=$hwt neste host; voce pediu $TARGET_FULL."
      err "  Se o hw-target foi gravado antes da v3.3.0, ele nao conhecia o"
      err "  9.2: rode ./pve-upgrade.sh --assess de novo e releia o veredito."
      err "  Parar em $hwt deixa o host abaixo do kernel 7.0 (so o 9.2 tem)."
      die "use --target $hwt, ou --force-hw se aceitar a perda de performance"
    fi
  elif [[ ! -f "$STATE_ROOT/hw-target" ]]; then
    warn "rode ./pve-upgrade.sh --assess antes, para calibrar a versao-alvo"
  fi

  # Console web: so bloqueia se termproxy/vncterm for ANCESTRAL REAL deste
  # shell. A checagem antiga usava pgrep global e disparava por causa de
  # uma aba do noVNC aberta em outra sessao do mesmo host.
  if state_in_web_console; then
    if [[ $ALLOW_CONSOLE -eq 1 ]]; then
      warn "console web do Proxmox — ele CAI durante o dist-upgrade (--allow-console)"
    else
      err "este shell e filho de termproxy/vncterm (console web do Proxmox)."
      err "Ele e derrubado no meio do dist-upgrade. Use SSH+tmux ou IPMI."
      die "se tiver certeza que nao e o caso, use --allow-console"
    fi
  fi
  # tmux/screen: cobra em SSH; em IPMI/console fisico nao faz sentido.
  if state_in_ssh && ! state_in_mux; then
    [[ $ALLOW_SSH -eq 1 ]] && warn "SSH sem tmux — queda de conexao aborta o upgrade" \
      || die "rode dentro de tmux/screen (ou --allow-ssh)"
  fi

  warn "Confirme IPMI/iDRAC/console fisico: NICs podem mudar de nome."

  local free_mb; free_mb=$(df -Pm / | awk 'NR==2{print $4}')
  [[ ${free_mb:-0} -lt 5000 ]] && die "so ${free_mb}MB livres em / (minimo 5GB)"
  ok "espaco em /: ${free_mb}MB"

  [[ $(pve_major) -le 6 ]] && ! grep -q '^root:[^:!*]' /etc/shadow 2>/dev/null \
    && die "root sem senha — o pacote sudo pode ser removido no upgrade"

  if dpkg -l linux-image-amd64 2>/dev/null | grep -q '^ii'; then
    warn "'linux-image-amd64' conflita com proxmox-ve"; run apt-get remove -y linux-image-amd64
  fi

  if is_dell_11g && ! dpkg -l pve-firmware 2>/dev/null | grep -q '^ii'; then
    warn "Dell 11G sem pve-firmware — NIC bnx2 pode perder firmware; instalando"
    run apt-get install -y pve-firmware
  fi

  local nodes; nodes=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
  if [[ ${nodes:-1} -gt 1 ]] && [[ "$(cat /sys/kernel/mm/ksm/run 2>/dev/null)" == "1" ]]; then
    local shar; shar=$(cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null || echo 0)
    warn "multi-socket NUMA ($nodes nos) + KSM economizando ~$(( shar * 4 / 1024 ))MB"
    state_event "KSM_BASELINE" "nodes=$nodes sharing_pages=$shar"
  fi

  # Hook DPkg::Post-Invoke do post-pve-install.sh (patch do nag): roda a CADA
  # invocacao do dpkg durante o dist-upgrade. Se ele falhar, o apt reporta
  # erro e o salto para no meio.
  if [[ -f /etc/apt/apt.conf.d/no-nag-script ]]; then
    warn "hook de patch do nag detectado (/etc/apt/apt.conf.d/no-nag-script)"
    warn "  ele executa a cada dpkg durante o dist-upgrade"
    warn "  se o upgrade falhar de forma estranha, tire-o do caminho:"
    warn "    mv /etc/apt/apt.conf.d/no-nag-script /root/"
  fi

  guests_snapshot
  bench_save || true

  warn "Backup valido de TODAS as VMs/CTs e pre-requisito."
  confirm "backups verificados e acesso out-of-band disponivel?" || die "abortado"

  is_cluster && warn "CLUSTER — atualize UM no por vez, migre guests antes"
  state_event "PREFLIGHT_OK" "pve=$(pve_full) target=$TARGET_FULL"
  ok "preflight concluido"
}

# ------------------------------------------------------------ repos

strip_backports() {
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    grep -qE '^[^#].*backports' "$f" || continue
    backup_file "$f"
    run sed -i -E 's|^([^#].*backports.*)$|# [pve-upgrade] \1|' "$f"
  done
}

repos_to_archive_buster() {
  head1 "Repos buster -> archive CDN"
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    grep -q 'buster' "$f" || continue
    backup_file "$f"
    run sed -i -e 's|http://[a-z.]*\.debian\.org|http://archive.debian.org|g' \
               -e 's|http://security\.debian\.org|http://archive.debian.org|g' \
               -e 's|https\?://download\.proxmox\.com|http://archive.proxmox.com|g' "$f"
  done
  [[ ! -f /etc/apt/apt.conf.d/99no-check-valid-until && $APPLY -eq 1 ]] && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
  state_event "REPOS_ARCHIVE_BUSTER" ""
}

# Detecta enterprise vs no-subscription nos DOIS formatos.
# deb822 usa 'Components:' e desliga com 'Enabled: false' (comentar linha de
# stanza gera entrada malformada). O grep antigo por hostname nao via isso e
# classificava como enterprise um repo ja desativado.
repo_flavor() {
  local f
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    grep -qE '^[[:space:]]*Enabled:[[:space:]]*false' "$f" && continue
    grep -qE '^[[:space:]]*Components:.*pve-enterprise' "$f" && { echo enterprise; return; }
  done
  grep -rqE '^[[:space:]]*deb[[:space:]]+.*enterprise\.proxmox\.com/debian/pve' \
       /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null \
    && { echo enterprise; return; }
  echo no-subscription
}

repos_switch_list() {
  local from="$1" to="$2" sec_from="$3" sec_to="$4"
  head1 "Repos: $from -> $to"
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    grep -q "$from" "$f" || continue
    backup_file "$f"
    run sed -i -e "s|${sec_from}|${sec_to}|g" -e "s|${from}|${to}|g" "$f"
  done
  local flavor; flavor=$(repo_flavor); info "repo: $flavor"
  if [[ $APPLY -eq 1 ]]; then
    if [[ "$flavor" == "enterprise" ]]; then
      echo "deb https://enterprise.proxmox.com/debian/pve ${to} pve-enterprise" \
        > /etc/apt/sources.list.d/pve-enterprise.list
    else
      echo "deb http://download.proxmox.com/debian/pve ${to} pve-no-subscription" \
        > /etc/apt/sources.list.d/pve-no-subscription.list
      [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]] && \
        sed -i -E 's|^deb|# deb|' /etc/apt/sources.list.d/pve-enterprise.list
    fi
    if has_ceph; then
      local cephrel=""
      [[ "$to" == "bullseye" ]] && cephrel="ceph-octopus"
      [[ "$to" == "bookworm" ]] && cephrel="ceph-quincy"
      [[ -n "$cephrel" ]] && echo "deb http://download.proxmox.com/debian/${cephrel} ${to} no-subscription" \
        > /etc/apt/sources.list.d/ceph.list
    fi
  fi
  strip_backports
  state_event "REPOS_SWITCHED" "$from -> $to ($flavor)"
}

repos_switch_trixie() {
  head1 "Repos: bookworm -> trixie (deb822)"
  local flavor; flavor=$(repo_flavor)
  local keyring=/usr/share/keyrings/proxmox-archive-keyring.gpg
  info "repo: $flavor"
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    grep -q 'bookworm' "$f" || continue
    backup_file "$f"
    run sed -i -e 's|bookworm-security|trixie-security|g' -e 's|bookworm|trixie|g' "$f"
  done
  [[ ! -f "$keyring" ]] && run apt-get install -y proxmox-archive-keyring
  if [[ $APPLY -eq 1 ]]; then
    if [[ "$flavor" == "enterprise" ]]; then
      cat > /etc/apt/sources.list.d/pve-enterprise.sources <<EOF
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Signed-By: $keyring
EOF
      rm -f /etc/apt/sources.list.d/pve-enterprise.list
    else
      cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: $keyring
EOF
      rm -f /etc/apt/sources.list.d/pve-no-subscription.list \
            /etc/apt/sources.list.d/pve-install-repo.list \
            /etc/apt/sources.list.d/pve-enterprise.list
    fi
    if has_ceph; then
      local uri comp
      if [[ "$flavor" == "enterprise" ]]; then
        uri="https://enterprise.proxmox.com/debian/ceph-squid"; comp="enterprise"
      else
        uri="http://download.proxmox.com/debian/ceph-squid"; comp="no-subscription"
      fi
      cat > /etc/apt/sources.list.d/ceph.sources <<EOF
Types: deb
URIs: $uri
Suites: trixie
Components: $comp
Signed-By: $keyring
EOF
      rm -f /etc/apt/sources.list.d/ceph.list
    fi
  fi
  strip_backports
  state_event "REPOS_SWITCHED" "bookworm -> trixie (deb822/$flavor)"
}

# ------------------------------------------------------------ apt


# Garante repo do PVE servindo o codinome ATUAL, antes de subir ao ultimo minor.
#
# O salto exige chegar ao ultimo minor da serie (7.4-15 para ir ao 8). Isso so
# acontece se houver repo do PVE servindo o codinome em que o host esta HOJE.
# Host instalado por ISO vem so com o pve-enterprise, que sem subscricao
# responde 401: o dist-upgrade nao traz nada, a versao nao sobe, e o salto
# morre no ver_ge dizendo "a doc exige 7.4-15" — sem em momento algum dizer
# que a causa e o repositorio. Era o erro mais caro de diagnosticar do script.
repos_ensure_pve_current() {
    local code; code=$(deb_code)
    case "$code" in
        bullseye|bookworm|trixie) ;;
        *) info "codinome '$code' fora do escopo (buster usa archive)"; return 0 ;;
    esac

    # Verdade de campo: existe candidato instalavel? Nao adianta procurar a
    # linha do repo — ela pode existir e o repo estar respondendo 401.
    run apt-get update >/dev/null 2>&1 || true
    local cand
    cand=$(apt-cache policy proxmox-ve 2>/dev/null | awk '/Candidate:/{print $2}')
    if [[ -n "$cand" && "$cand" != "(none)" ]]; then
        ok "repo do PVE serve '$code' (candidato $cand)"
        return 0
    fi

    warn "sem candidato para proxmox-ve em '$code'"
    warn "  sem corrigir, o host NAO chega ao ultimo minor e o salto aborta"

    local flavor; flavor=$(repo_flavor)
    if [[ "$flavor" == "enterprise" ]]; then
        warn "repo ENTERPRISE ativo, sem subscricao valida (responde 401)"
        if [[ $KEEP_ENTERPRISE -eq 1 ]]; then
            err "--keep-enterprise pedido: nao vou mexer nos repositorios."
            die "corrija a subscricao, ou rode sem --keep-enterprise"
        fi
        local f
        for f in /etc/apt/sources.list.d/pve-enterprise.list \
                 /etc/apt/sources.list.d/pve-enterprise.sources; do
            [[ -f "$f" ]] || continue
            backup_file "$f"
            if [[ "$f" == *.sources ]]; then
                # deb822: comentar a linha gera stanza malformada. O
                # desligamento suportado e a chave Enabled.
                if grep -qE '^[[:space:]]*Enabled:' "$f"; then
                    run sed -i -E 's|^[[:space:]]*Enabled:.*|Enabled: false|' "$f"
                elif [[ $APPLY -eq 1 ]]; then
                    printf 'Enabled: false\n' >> "$f"
                else
                    log "   ${C_Y}[dry]${C_0} echo 'Enabled: false' >> $f"
                fi
            else
                run sed -i -E 's|^[[:space:]]*deb|# deb|' "$f"
            fi
            warn "desativado: $f"
            warn "  se a subscricao voltar, reative e remova o repo publico"
        done
    fi

    local linha="deb http://download.proxmox.com/debian/pve ${code} pve-no-subscription"
    local alvo=/etc/apt/sources.list.d/pve-no-subscription.list
    if [[ $APPLY -eq 1 ]]; then
        printf '%s\n' "$linha" > "$alvo"
    else
        log "   ${C_Y}[dry]${C_0} echo '$linha' > $alvo"
    fi
    ok "repo publico adicionado para '$code'"
    state_event "REPO_PVE_ADDED" "$code no-subscription (era $flavor)"

    apt_refresh
    cand=$(apt-cache policy proxmox-ve 2>/dev/null | awk '/Candidate:/{print $2}')
    if [[ $APPLY -eq 1 && ( -z "$cand" || "$cand" == "(none)" ) ]]; then
        die "ainda sem candidato apos adicionar o repo publico — revise a rede/DNS"
    fi
    [[ -n "$cand" && "$cand" != "(none)" ]] && ok "candidato agora: $cand"
    return 0
}

apt_refresh() { run apt-get update || die "apt update falhou — revise os repositorios"; }

# Portao anti-remocao do meta-pacote proxmox-ve.
#
# Repo do PVE desalinhado do codinome, ou repo ENTERPRISE sem subscricao (que
# responde 401), deixam 'proxmox-ve' sem candidato. O solver do apt entao
# resolve as dependencias REMOVENDO o meta-pacote, e o pve-apt-hook aborta com
# codigo 1 no meio do dist-upgrade — deixando o dpkg pela metade, que e o pior
# estado possivel para um hypervisor.
#
# A mensagem do hook engana: diz que "voce esta tentando remover o proxmox-ve"
# quando a remocao e CONSEQUENCIA da resolucao, nao pedido do operador. E o
# 'touch /please-remove-proxmox-ve' que ela sugere nunca se aplica aqui: levaria
# junto pve-manager, qemu-server, qm, pct e a interface web.
#
# Barrar antes custa dois comandos read-only. Descobrir depois custa o host.
#
# Roda TAMBEM em dry-run, de proposito: o valor do dry-run e justamente dizer
# que o salto falharia, antes de voce abrir a janela de manutencao.
# Em --apply o portao mata. Em dry-run ele avisa e deixa o plano seguir:
# um dry-run so vale se mostrar o roteiro inteiro, inclusive o que quebraria.
guard_stop() {
    [[ $APPLY -eq 1 ]] && die "$1"
    warn "[dry-run] em --apply isto ABORTARIA: $1"
    return 0
}

apt_guard_proxmox_ve() {
    command -v apt-cache >/dev/null 2>&1 || return 0
    # host sem o meta-pacote (guest, ou PVE ainda nao instalado): nada a proteger
    dpkg-query -W proxmox-ve >/dev/null 2>&1 || return 0

    local cand flavor
    cand=$(apt-cache policy proxmox-ve 2>/dev/null | awk '/Candidate:/{print $2}')
    if [[ -z "$cand" || "$cand" == "(none)" ]]; then
        flavor=$(repo_flavor)
        err "proxmox-ve SEM CANDIDATO instalavel apos o apt update."
        err "  prosseguir faria o apt propor a REMOCAO do meta-pacote."
        if [[ "$flavor" == "enterprise" ]]; then
            err "  o repo ativo e o ENTERPRISE, que exige subscricao valida."
            err "  sem assinatura ele responde 401 e o candidato desaparece."
            err "  para migrar este host ao repo publico:"
            err "    sed -i -E 's|^deb|# deb|' /etc/apt/sources.list.d/pve-enterprise.list"
            err "    echo 'deb http://download.proxmox.com/debian/pve $(deb_code) pve-no-subscription' > /etc/apt/sources.list.d/pve-no-subscription.list"
            err "    apt-get update"
        else
            err "  confira se o repo do PVE aponta para o codinome '$(deb_code)':"
            err "    grep -rE 'proxmox.com/debian/pve' /etc/apt/sources.list.d/"
        fi
        state_event "GUARD_NO_CANDIDATE" "deb=$(deb_code) flavor=$flavor"
        guard_stop "abortando antes do dist-upgrade"
        return 0
    fi
    ok "proxmox-ve candidato: $cand"

    # Ter candidato nao basta: um conflito de dependencia ainda pode levar o
    # solver a escolher a remocao. Simular e definitivo e nao custa nada.
    local sim rc
    sim=$(apt-get -s dist-upgrade 2>&1); rc=$?
    if [[ $rc -ne 0 ]]; then
        warn "a simulacao do dist-upgrade retornou $rc — apt em estado inconsistente?"
        warn "  tente 'apt-get -f install' e rode de novo"
    elif grep -qE '^Remv[[:space:]]+proxmox-ve\b' <<<"$sim"; then
        err "a SIMULACAO do dist-upgrade REMOVE o proxmox-ve."
        err "  isso destruiria o hypervisor: pve-manager, qemu-server, qm, pct, web."
        err "  NAO use 'touch /please-remove-proxmox-ve' — a remocao nao e o objetivo."
        err "  veja o que o apt pretende remover:"
        err "    apt-get -s dist-upgrade | grep '^Remv'"
        state_event "GUARD_WOULD_REMOVE" "deb=$(deb_code)"
        guard_stop "abortando antes do dist-upgrade"
    else
        ok "simulacao nao remove proxmox-ve"
    fi
}

apt_dist_upgrade() {
  local label="$1"
  apt_guard_proxmox_ve
  info "dist-upgrade ($label) — 5 a 60min conforme o disco"
  if [[ $APPLY -eq 1 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get -y \
      -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
      dist-upgrade 2>&1 | tee -a "$RUN_LOG"
    local rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 ]]; then
      err "dist-upgrade retornou $rc"; warn "tente: apt -f install; depois rode de novo"
      state_event "DIST_UPGRADE_FAIL" "$label rc=$rc"; exit 1
    fi
  else
    log "   ${C_Y}[dry]${C_0} apt-get dist-upgrade (confold)"
  fi
  state_event "DIST_UPGRADE_OK" "$label"
}

report_conffiles() {
  local pend
  pend=$(find /etc \( -name '*.dpkg-dist' -o -name '*.dpkg-new' \) 2>/dev/null | head -20)
  [[ -z "$pend" ]] && return 0
  warn "conffiles novos aguardando revisao (sua versao foi mantida):"
  echo "$pend" | while read -r f; do log "     $f"; done
  warn "a doc recomenda aceitar a versao nova de: lvm.conf, sshd_config, chrony.conf"
}

run_checker() {
  local tool="$1"

  if [[ $NO_CHECKER -eq 1 ]]; then
    warn "--no-checker: $tool NAO foi executado [PERIGOSO]"
    warn "  o checador oficial cobre repos, espaco, kernel e config incompativel"
    state_event "CHECKER_SKIPPED" "$tool"
    return 0
  fi

  head1 "Checagem: $tool --full"
  command -v "$tool" >/dev/null || die "$tool nao encontrado"

  # timeout + saida em PIPE, nunca em $( ).
  #
  # O checador faz consultas de rede aos repositorios. Com repo inacessivel
  # (enterprise 401, mirror mudo, DNS quebrado) ele bloqueia na conexao. Em
  # command substitution isso congelava o script SEM IMPRIMIR NADA — a saida
  # so apareceria no fim, que nunca chegava. Era o "trava sem erro".
  #
  # Aqui a saida vai para a tela enquanto roda, e o timeout garante que uma
  # trava vire mensagem em vez de espera infinita.
  local tmp rc
  tmp=$(mktemp) || die "mktemp falhou"
  timeout "${CHECKER_TIMEOUT}" "$tool" --full 2>&1 | tee -a "$RUN_LOG" "$tmp"
  rc=${PIPESTATUS[0]}

  if [[ $rc -eq 124 ]]; then
    rm -f "$tmp"
    err "$tool nao terminou em ${CHECKER_TIMEOUT}s — interrompido."
    err "  causa tipica: repositorio inacessivel; o checador trava na conexao."
    err "  confira:  apt-get update"
    err "  ou pule:  --no-checker   (e assuma o risco de nao ter checado)"
    err "  ou estenda: --checker-timeout <segundos>"
    state_event "CHECKER_TIMEOUT" "$tool ${CHECKER_TIMEOUT}s"
    die "checagem travada"
  fi

  local fails warns
  fails=$(grep -ciE '^\s*FAIL' "$tmp" || true)
  warns=$(grep -ciE '^\s*WARN' "$tmp" || true)
  rm -f "$tmp"
  state_event "CHECKER" "$tool fail=$fails warn=$warns rc=$rc"

  if [[ ${fails:-0} -gt 0 ]]; then
    err "$fails FAILURES"
    [[ $SKIP_CHECKER -eq 1 ]] && warn "--skip-checker: prosseguindo [PERIGOSO]" \
      || die "corrija as falhas e rode de novo (ou --skip-checker)"
  fi
  [[ ${warns:-0} -gt 0 ]] && warn "$warns warnings — revise acima"
  ok "$tool sem falhas bloqueantes"
}

pause_reboot() {
  head1 "REBOOT NECESSARIO"
  warn "$1"
  warn "Sequencia apos o reboot:"
  warn "  1. ./pve-upgrade.sh --validate"
  warn "  2. ./proxmox_tune.sh          (kernel novo = chaves sysctl novas)"
  warn "  3. ./pve-upgrade.sh --apply   (proximo salto)"
  state_event "REBOOT_REQUIRED" "$(pve_full)"
  exit 0
}

# ------------------------------------------------------------ fases

phase_6_to_7() {
  head1 "FASE 10 — PVE 6.x -> 7"
  local bad; bad=$(cgroupv1_cts)
  if [[ -n "${bad// /}" ]]; then
    warn "CTs legados:$bad — o PVE 7 usa cgroupv2 puro por padrao."
    warn "Para mante-los TEMPORARIAMENTE, apos o upgrade adicione a cmdline:"
    warn "  systemd.unified_cgroup_hierarchy=0"
    warn "Isso acaba no PVE 9. Planeje a migracao desses CTs agora."
    confirm "ciente dos CTs legados, continuar?" || die "abortado"
  fi
  repos_to_archive_buster; apt_refresh; apt_dist_upgrade "6.x -> 6.4"
  ver_ge "$(pve_full)" "6.4-0" || warn "esperado 6.4+, obtido $(pve_full)"
  run_checker pve6to7
  repos_switch_list "buster" "bullseye" "buster/updates" "bullseye-security"
  apt_refresh; apt_dist_upgrade "Debian 10->11 / PVE 6->7"
  state_event "PVE7_INSTALLED" "$(pve_full)"
  pause_reboot "PVE 7 instalado."
}

phase_7_to_8() {
  head1 "FASE 50 — PVE 7.x -> 8"
  strip_backports; repos_ensure_pve_current; apt_refresh; apt_dist_upgrade "7.x -> 7.4"
  ver_ge "$(pve_full)" "7.4-15" || die "$(pve_full): a doc exige 7.4-15+"
  run_checker pve7to8
  if has_ceph; then
    local cv; cv=$(ceph version 2>/dev/null | grep -oP 'version \K\d+')
    [[ -n "$cv" && ${cv:-0} -lt 17 ]] && die "Ceph v$cv — precisa Quincy 17.2 antes do PVE 8"
  fi
  repos_switch_list "bullseye" "bookworm" "bullseye-security" "bookworm-security"
  apt_refresh; apt_dist_upgrade "Debian 11->12 / PVE 7->8"
  state_event "PVE8_INSTALLED" "$(pve_full)"
  if is_uefi && ! root_is_zfs && ! dpkg -l grub-efi-amd64 2>/dev/null | grep -q '^ii'; then
    run apt-get install -y grub-efi-amd64
  fi
  report_conffiles
  pause_reboot "PVE 8 instalado. Reinicie mesmo se ja usava kernel 6.2 opt-in."
}

phase_8_to_9() {
  head1 "FASE 70 — PVE 8.x -> 9"
  strip_backports; repos_ensure_pve_current; apt_refresh; apt_dist_upgrade "8.x -> 8.4"
  ver_ge "$(pve_full)" "8.4.1" || die "$(pve_full) — a doc exige 8.4.1+ antes do 9"

  local bad; bad=$(cgroupv1_cts)
  if [[ -n "${bad// /}" ]]; then
    err "containers legados:$bad — PVE 9 removeu cgroupv1, NAO iniciam."
    # Flag PROPRIA. O veto de hardware e de performance e nao pode arrastar
    # junto, calado, o bypass de um bloqueio que deixa servico fora do ar.
    [[ $FORCE_CGROUP -eq 1 ]] \
      && warn "--force-cgroup: prosseguindo [PERIGOSO — os CTs acima nao sobem mais]" \
      || die "migre esses containers antes do PVE 9 (ou --force-cgroup, ciente disso)"
  fi
  if has_ceph; then
    local cv; cv=$(ceph version 2>/dev/null | grep -oP 'version \K\d+')
    [[ -n "$cv" && ${cv:-0} -lt 19 ]] && die "Ceph v$cv — PVE 9 exige Squid 19.2"
  fi

  run_checker pve8to9

  local mig=/usr/share/pve-manager/migrations/pve-lvm-disable-autoactivation
  [[ -x "$mig" ]] && { info "desabilitando autoactivation LVM de guests"; run "$mig"; }

  dpkg -l systemd-boot 2>/dev/null | grep -qE '^ii\s+systemd-boot\s' && {
    info "removendo meta-pacote systemd-boot"; run apt-get remove -y systemd-boot; }

  systemctl is-enabled systemd-journald-audit.socket &>/dev/null && {
    info "desabilitando systemd-journald-audit.socket"
    run systemctl disable --now systemd-journald-audit.socket; }

  # /etc/sysctl.conf deixa de ser lido no PVE 9.
  # Migramos com prefixo 60- para NAO sobrepor o tuning (95-) nem o NUMA (99-).
  # Chaves em colisao sao reportadas para decisao consciente.
  if [[ -s /etc/sysctl.conf ]] && grep -qE '^[^#]' /etc/sysctl.conf; then
    warn "/etc/sysctl.conf NAO e lido no PVE 9 — migrando para /etc/sysctl.d/"
    local dest=/etc/sysctl.d/60-migrado-sysctl-conf.conf
    local colid=""
    if [[ -f /etc/sysctl.d/95-proxmox-tune.conf ]]; then
      colid=$(comm -12 \
        <(grep -oP '^\s*\K[a-z0-9_.]+(?=\s*=)' /etc/sysctl.conf | sort -u) \
        <(grep -oP '^\s*\K[a-z0-9_.]+(?=\s*=)' /etc/sysctl.d/95-proxmox-tune.conf | sort -u))
    fi
    backup_file /etc/sysctl.conf
    if [[ $APPLY -eq 1 ]]; then
      { echo "# migrado de /etc/sysctl.conf por $TOOL v$VERSION em $(date -Is)"
        echo "# prefixo 60- de proposito: perde para 95-proxmox-tune e 99-numa"
        grep -E '^[^#]' /etc/sysctl.conf; } > "$dest"
      ok "criado $dest"
    fi
    if [[ -n "$colid" ]]; then
      warn "chaves em colisao com o tuning (o tuning vence):"
      echo "$colid" | sed 's/^/     /' | tee -a "$RUN_LOG"
      warn "revise se o valor antigo ainda faz sentido"
    fi
  fi

  repos_switch_trixie
  apt_refresh
  apt_dist_upgrade "Debian 12->13 / PVE 8->9"
  state_event "PVE9_INSTALLED" "$(pve_full)"
  post_pve9_fixups
  pause_reboot "PVE 9 instalado. Reinicie mesmo se ja usava kernel 6.14 opt-in."
}

# O alvo pode ter minor, e o major sozinho nao prova que se chegou nele: o
# salto 8->9 aterrissa no 9.0 e os minors seguintes exigem outra passada.
# Sem este relatorio o operador encerra no 9.0 achando que terminou.
minor_target_report() {
  local cur; cur=$(pve_full)
  [[ -z "$cur" ]] && return 0
  if ver_ge "$cur" "$TARGET_FULL"; then
    ok "alvo $TARGET_FULL alcancado (PVE $cur)"
  else
    warn "AINDA NAO NO ALVO: PVE $cur, alvo $TARGET_FULL"
    warn "  rode --apply de novo depois do reboot."
    warn "  se nada mudar, o canal '$(repo_flavor)' ainda nao publicou o $TARGET_FULL"
  fi
}

phase_minor_update() {
  head1 "FASE MINOR — dentro do PVE $(pve_major)"
  apt_refresh
  local n; n=$(apt-get -s dist-upgrade 2>/dev/null | grep -c '^Inst' || true)
  [[ ${n:-0} -eq 0 ]] && { ok "nenhum pacote pendente — host no ultimo minor"; minor_target_report; return 0; }
  info "$n pacotes pendentes"
  if is_poweredge && [[ $(pve_major) -eq 9 ]]; then
    warn "PowerEdge + PVE 9: minors trazem kernel 6.17/7.0 — se o boot falhar,"
    warn "  volte com: proxmox-boot-tool kernel pin <versao 6.14>"
    warn "  ATENCAO: pinar no 6.14 mantem o host ABAIXO do kernel 7.0."
  fi
  apt_dist_upgrade "minor PVE $(pve_major)"
  minor_target_report
  reboot_pending && pause_reboot "Kernel novo instalado."
  ok "minor update concluido sem troca de kernel"
}

post_pve9_fixups() {
  head1 "FASE 90 — Ajustes pos PVE 9"
  if is_uefi && ! root_is_zfs && ! dpkg -l grub-efi-amd64 2>/dev/null | grep -q '^ii'; then
    run apt-get install -y grub-efi-amd64
  fi
  local ram; ram=$(ram_mb)
  [[ $ram -lt 32000 ]] && {
    warn "/tmp agora e tmpfs (ate $((ram/2))MB aqui)"
    warn "  limite:  systemctl edit tmp.mount  ->  Options=size=2G"; }
  grep -q 'systemctl restart frr' /etc/network/interfaces 2>/dev/null && {
    err "'post-up systemctl restart frr' TRAVA O BOOT no PVE 9 — troque por:"
    err "  post-up systemctl is-active --quiet frr && systemctl restart frr || true"; }
  grep -rqE '^machine:.*1[0-9]\.[0-9]' /etc/pve/qemu-server/*.conf 2>/dev/null && \
    warn "VMs com machine >= 10.0: Veeam quebrado; pin em 9.2+pve1 se usar Veeam."

  # .list remanescentes geram warning do APT no PVE 9 (nao quebram nada).
  # Preferir o 'apt modernize-sources' oficial a apagar arquivos: um
  # 'rm -f *.list' levaria junto repos de terceiros (plugins, agentes).
  local leftover
  leftover=$(grep -rlE '^[[:space:]]*deb[[:space:]]' \
             /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | tr '\n' ' ')
  if [[ -n "${leftover// /}" ]]; then
    info "ainda ha sources em formato .list: $leftover"
    info "  converter mantendo backup .bak:  apt modernize-sources"
  fi

  # Ceph Tentacle 20.2 e o default de INSTALACOES NOVAS a partir do 9.2.
  # NAO trocamos o repo automaticamente: subir Squid->Tentacle junto com
  # o salto de SO nao e suportado. E migracao separada, feita depois.
  if has_ceph; then
    local cv; cv=$(ceph version 2>/dev/null | grep -oP 'version \K\d+')
    if [[ "${cv:-0}" -eq 19 ]]; then
      info "Ceph Squid 19 ok. Tentacle 20.2 existe a partir do PVE 9.2, mas"
      info "  a migracao e separada (wiki Ceph_Squid_to_Tentacle). Nao faca junto."
    fi
  fi

  report_conffiles
  state_event "POST9_OK" ""
}

# ------------------------------------------------------------ status

show_status() {
  head1 "Estado — $TOOL v$VERSION (schema $STATE_SCHEMA)"
  state_init
  log "  host      : $(hostname)  ($(dmi_product))"
  log "  PVE       : $(pve_full)  (major $(pve_major))"
  log "  Debian    : $(deb_code)   kernel: $(uname -r)"
  log "  CPU       : $(awk -F: '/^model name/{gsub(/^ +/,"",$2);print $2;exit}' /proc/cpuinfo)"
  log "  x86 level : v$(x86_level)   RAM: $(ram_mb)MB   NUMA: $(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l) no(s)"
  log "  boot      : $(is_uefi && echo UEFI || echo BIOS)$(root_is_zfs && echo ' + ZFS')"
  log "  Ceph      : $(has_ceph && echo sim || echo nao)   cluster: $(is_cluster && echo sim || echo nao)"
  [[ -f "$STATE_ROOT/hw-score" ]] && \
    log "  hw score  : $(cat "$STATE_ROOT/hw-score")/100 -> target $(cat "$STATE_ROOT/hw-target")"
  if state_tune_current; then
    . "$TUNE_DIR/state-$(uname -r).env" 2>/dev/null || true
    log "  tuning    : v${TUNE_VERSION:-?} aplicado neste kernel (${TUNE_APPLIED:-?})"
  else
    log "  tuning    : ${C_Y}ausente para o kernel atual${C_0}"
  fi
  state_upgrade_inflight && warn "UPGRADE EM VOO: repos != sistema"
  reboot_pending && warn "reboot pendente (kernel novo instalado)"

  if ls "$BENCH_DIR"/pve*.txt >/dev/null 2>&1; then
    head1 "Baselines de benchmark"
    ls -t "$BENCH_DIR"/pve*.txt | while read -r f; do log "  $(head -1 "$f" | cut -c3-)"; done
  fi
  if [[ -f "$EVENT_LOG" ]]; then
    head1 "Historico (ultimos 15, ambos os scripts)"
    # SC2034: h e vr nao sao impressos, mas sustentam as POSICOES do campo.
    # Sem eles, tl/ev/det leriam a coluna errada da linha de evento.
    # shellcheck disable=SC2034
    tail -15 "$EVENT_LOG" | while IFS='|' read -r ts h tl vr ev det; do
      printf '  %s  %-12s %-20s %s\n' "${ts:0:19}" "$tl" "$ev" "$det"
    done
  fi
  head1 "Proximo passo"
  case "$(pve_major)" in
    6|7|8) log "  ./pve-upgrade.sh --assess (se ainda nao) -> --apply" ;;
    9)
      if ver_ge "$(pve_full)" "9.2"; then
        log "  no 9.2 (kernel 7.0) — so minors de manutencao: --apply"
      else
        log "  ./pve-upgrade.sh --apply  (minors ate 9.2 / kernel 7.0)"
      fi ;;
  esac
  state_tune_current || log "  ./proxmox_tune.sh  (tuning ausente para este kernel)"
}

# ------------------------------------------------------------ main

main() {
  state_init
  case "$MODE" in
    status)   show_status; exit 0 ;;
    assess)   hw_assess; exit 0 ;;
    validate) validate_stack; exit 0 ;;
    check)
      case "$(pve_major)" in
        6) run_checker pve6to7 ;; 7) run_checker pve7to8 ;;
        8) run_checker pve8to9 ;; 9) ok "ja no PVE 9" ;;
      esac; exit 0 ;;
  esac

  head1 "$TOOL v$VERSION ($([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN))"
  [[ $APPLY -eq 0 ]] && info "nada sera alterado. use --apply para executar."

  preflight

  if reboot_pending; then
    warn "kernel novo instalado mas nao em uso"
    confirm "seguir mesmo assim? (recomendado: reboot antes)" \
      || die "reinicie, rode --validate e depois --apply"
  fi

  # RETOMADA. Os repos ja apontam para o codinome novo mas o sistema ainda
  # esta no antigo: um salto anterior parou depois de trocar os repositorios.
  # Reentrar pela fase do inicio tentaria subir ao ultimo minor da serie
  # ANTIGA usando repositorio da NOVA — incoerente, e a causa de o script
  # "nao ser idempotente" na pratica. O detector ja existia; nao estava ligado.
  if state_upgrade_inflight; then
    local rc_repo rc_sys
    rc_repo=$(repo_codename_newest); rc_sys=$(deb_code)
    warn "UPGRADE EM VOO: repos em '$rc_repo', sistema em '$rc_sys'"
    warn "  um salto anterior parou DEPOIS de trocar os repositorios."
    warn "  retomando o dist-upgrade; nao repito a subida de minor."
    state_event "RESUME_INFLIGHT" "repo=$rc_repo sys=$rc_sys"
    apt_refresh
    apt_dist_upgrade "retomada: $rc_sys -> $rc_repo"
    [[ "$rc_repo" == "trixie" ]] && post_pve9_fixups
    report_conffiles
    pause_reboot "Retomada concluida ($rc_sys -> $rc_repo)."
  fi

  local maj; maj=$(pve_major)
  if [[ $maj -ge $TARGET ]]; then
    ok "major $maj ja atende o alvo $TARGET_FULL — verificando minors"
    phase_minor_update
    [[ $maj -eq 9 ]] && post_pve9_fixups
    show_status; exit 0
  fi

  case "$maj" in
    6) phase_6_to_7 ;;
    7) phase_7_to_8 ;;
    8) phase_8_to_9 ;;
    *) die "versao PVE nao reconhecida: $maj" ;;
  esac
}

main "$@"
