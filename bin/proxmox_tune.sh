#!/usr/bin/env bash
# =============================================================================
# proxmox_tune.sh — v3.0
# Update/upgrade seguro + tuning de host Proxmox VE 6/7/8/9
# (Debian 10 "buster" -> Debian 13 "trixie", kernels 5.3 -> 7.0+)
#
# Par de pve-upgrade.sh. Compartilham /var/lib/pve-maint (schema 1).
#   upgrade = pontual, ABORTA em bloqueador
#   tuning  = recorrente (a cada kernel novo), NUNCA aborta por chave
#
# NOVIDADES DA v3.0 (correcoes de conflito com pve-upgrade.sh):
#   [1] numa_balancing agora e TOPOLOGY-AWARE: vira 0 automaticamente se
#       houver VM com 'hostnodes=' (pinning NUMA). Antes forcava 1 e
#       desfazia o pinning silenciosamente.
#   [2] GUARDA DE UPGRADE EM VOO: aborta se os repos apontam para um
#       codename diferente do sistema. Sem isso, --full-upgrade executava
#       um upgrade major sem nenhum preflight.
#   [3] dirty_ratio -> dirty_bytes em hosts com >32GB. 15% de 128GB sao
#       19,6GB de paginas sujas: o flush trava o I/O de todas as VMs.
#   [4] rp_filter default 2 (loose) em vez de 1 (strict). Strict quebra
#       roteamento assimetrico e exit nodes EVPN. Use --strict-rpfilter
#       para forcar 1.
#   [5] nf_conntrack_buckets via modprobe.d (sysctl e read-only apos o
#       carregamento do modulo — antes falhava em silencio).
#   [6] ESTADO COMPARTILHADO: grava tune/state-<kernel>.env. Rodar de novo
#       no mesmo kernel com os mesmos parametros = no-op ("nada a fazer").
#       Kernel novo = re-tuna automaticamente.
#   [7] Avisos de custo: governor performance em CPU sem intel_pstate,
#       e BBR (que so afeta trafego originado no host, nao das VMs).
#
# Uso:
#   bash proxmox_tune.sh --help
#   bash proxmox_tune.sh --dry-run
#   bash proxmox_tune.sh --swappiness 1 --governor performance
#   bash proxmox_tune.sh --zfs-arc 8 --hugepages 8
#   bash proxmox_tune.sh --tune-only --force
# =============================================================================
set -uo pipefail   # SEM '-e' de proposito: erros sao tratados por funcao.
IFS=$'\n\t'

readonly SCRIPT_NAME="proxmox_tune.sh"
readonly SCRIPT_VERSION="3.2.0"
TOOL="proxmox-tune"
VERSION="$SCRIPT_VERSION"

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

readonly LOG_FILE="/var/log/proxmox_tune.log"
RUN_STAMP="$(date +%Y%m%d_%H%M%S)"; readonly RUN_STAMP
readonly BACKUP_DIR="${STATE_ROOT}/backups/${RUN_STAMP}"
readonly SYSCTL_FILE="/etc/sysctl.d/95-proxmox-tune.conf"
readonly MODULES_FILE="/etc/modules-load.d/95-proxmox-tune.conf"
readonly CONNTRACK_MODPROBE="/etc/modprobe.d/95-proxmox-tune-conntrack.conf"
readonly GRUB_FILE="/etc/default/grub"
readonly PBT_CMDLINE="/etc/kernel/cmdline"
readonly ZFS_MODPROBE_FILE="/etc/modprobe.d/99-proxmox-tune-zfs.conf"
readonly GOV_UNIT="/etc/systemd/system/proxmox-tune-cpugov.service"

# ── Flags ────────────────────────────────────────────────────────────────────
DRY_RUN=0
SKIP_UPGRADE=0
FULL_UPGRADE=0
FORCE=0                 # re-aplica mesmo se o estado do kernel ja bater
HUGEPAGES_GB=0
SWAPPINESS=10
GOVERNOR=""
ZFS_ARC_GB=0
STRICT_RPFILTER=0       # 0 = rp_filter 2 (loose, default). 1 = strict.
DISABLE_HA=0            # 1 = desliga pve-ha-lrm/crm em host STANDALONE

# Estado interno
WRITE_CHANGED=0
MEM_TOTAL_MB=0
MEM_AVAIL_MB=0
NUMA_BAL=1              # calculado em detect_numa_policy()
NUMA_REASON=""

if [[ -t 1 ]]; then
    readonly C_RED=$'\033[0;31m'  C_GRN=$'\033[0;32m'  C_YEL=$'\033[1;33m'
    readonly C_CYN=$'\033[0;36m'  C_DIM=$'\033[2m'      C_NC=$'\033[0m'
else
    readonly C_RED='' C_GRN='' C_YEL='' C_CYN='' C_DIM='' C_NC=''
fi

_log() {
    local level="$1"; shift
    local ts; ts=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${ts}] [${level}] $*" >> "$LOG_FILE" 2>/dev/null || true
    case "$level" in
        ERROR) echo "${C_RED}  x $*${C_NC}" >&2 ;;
        WARN)  echo "${C_YEL}  ! $*${C_NC}" ;;
        OK)    echo "${C_GRN}  + $*${C_NC}" ;;
        INFO)  echo "${C_CYN}  - $*${C_NC}" ;;
        STEP)  echo ""; echo "${C_CYN}== $* ==${C_NC}" ;;
        *)     echo "  $*" ;;
    esac
}

run() {
    if [[ "$DRY_RUN" == "1" ]]; then _log INFO "[DRY-RUN] $*"; return 0; fi
    "$@"
}

show_help() {
    cat << EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — tuning de host Proxmox VE 6/7/8/9
Par de pve-upgrade.sh. Estado compartilhado em ${STATE_ROOT}.

USO
  bash ${SCRIPT_NAME} [OPCOES]

QUANDO RODAR
  Depois de CADA upgrade de versao do PVE (e do reboot). O aplicador
  tolerante grava so as chaves que o kernel da vez aceita — kernel novo
  significa conjunto de chaves diferente. O script detecta isso sozinho:
  se ja tunou este kernel com estes parametros, ele nao faz nada.

OPCOES
  -h, --help            Ajuda.
  --dry-run             Simula tudo sem alterar o sistema.
  --skip-upgrade        Pula pacotes (so tuning). Alias: --tune-only.
  --full-upgrade        Usa 'dist-upgrade' em vez de 'upgrade'. E o que a
                        doc oficial do PVE recomenda para pacotes pve-*.
                        BLOQUEADO se houver upgrade de versao em voo.
  --force               Re-aplica mesmo se o estado deste kernel ja bater.
  --swappiness <N>      vm.swappiness (0-100). Default: 10.
                        1 = quase zero swap COM valvula antes do OOM.
                        0 = kernel >=3.5 so swapa em emergencia; o OOM
                            killer pode matar uma VM. Aplicado com aviso.
  --governor <G>        CPU governor (performance/schedutil/powersave).
                        Avisa se a CPU nao tiver intel_pstate: em Nehalem/
                        Westmere o 'performance' trava o TDP no maximo.
  --zfs-arc <N>         Teto do ARC do ZFS em GB (runtime + modprobe.d +
                        initramfs).
  --hugepages <N>       Reserva N GB de HugePages NO BOOT via cmdline.
                        Detecta GRUB vs proxmox-boot-tool automaticamente.
  --disable-ha          Desliga pve-ha-lrm e pve-ha-crm em host STANDALONE.
                        Libera RAM/CPU num no que nunca vai usar HA (util
                        nos R410/R610 com pouca memoria). RECUSA rodar se o
                        no fizer parte de um cluster: derrubar esses
                        servicos com corosync ativo quebra o quorum.
                        Reversivel: systemctl enable --now pve-ha-lrm pve-ha-crm
  --strict-rpfilter     Forca rp_filter=1 (strict). Default e 2 (loose):
                        strict quebra roteamento assimetrico e exit nodes
                        EVPN, cortando trafego sem log obvio.

CUIDADOS EMBUTIDOS
  - Sem 'set -e': chave sysctl inexistente e pulada e logada, nunca aborta.
  - Idempotente: arquivo so e reescrito (e backupeado) se o conteudo mudar.
  - numa_balancing=0 automatico quando ha VM com hostnodes= (pinning NUMA).
  - Aborta se os repos apontarem para codename != sistema (upgrade em voo).
  - HugePages so via cmdline (reboot), nunca alocacao runtime em host vivo.
  - Modulos br_netfilter/nf_conntrack carregados antes do sysctl dependente.

EXEMPLOS
  bash ${SCRIPT_NAME} --dry-run
  bash ${SCRIPT_NAME} --swappiness 1 --governor performance
  bash ${SCRIPT_NAME} --zfs-arc 8 --hugepages 8
  bash ${SCRIPT_NAME} --tune-only --force
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)       show_help; exit 0 ;;
        --dry-run)       DRY_RUN=1 ;;
        --skip-upgrade|--tune-only) SKIP_UPGRADE=1 ;;
        --full-upgrade)  FULL_UPGRADE=1 ;;
        --force)         FORCE=1 ;;
        --strict-rpfilter) STRICT_RPFILTER=1 ;;
        --disable-ha)      DISABLE_HA=1 ;;
        --swappiness)
            shift
            [[ "${1:-}" =~ ^[0-9]+$ && "${1:-999}" -le 100 ]] && SWAPPINESS="$1" || {
                echo "Erro: --swappiness exige 0..100" >&2; exit 2; } ;;
        --governor)
            shift
            [[ "${1:-}" =~ ^[a-z_]+$ ]] && GOVERNOR="$1" || {
                echo "Erro: --governor exige um nome valido" >&2; exit 2; } ;;
        --zfs-arc)
            shift
            [[ "${1:-}" =~ ^[0-9]+$ && "${1:-0}" -ge 1 ]] && ZFS_ARC_GB="$1" || {
                echo "Erro: --zfs-arc exige numero >= 1 (GB)" >&2; exit 2; } ;;
        --hugepages)
            shift
            [[ "${1:-}" =~ ^[0-9]+$ ]] && HUGEPAGES_GB="$1" || {
                echo "Erro: --hugepages exige numero (GB)" >&2; exit 2; } ;;
        *) echo "Erro: flag desconhecida '$1'. Use --help." >&2; exit 2 ;;
    esac
    shift
done

# ── Escrita idempotente ──────────────────────────────────────────────────────
write_if_changed() {
    local file="$1" mode="${2:-0644}"
    WRITE_CHANGED=0
    local tmp; tmp=$(mktemp) || { _log ERROR "mktemp falhou"; return 1; }
    cat > "$tmp"
    if [[ -f "$file" ]] && cmp -s \
            <(grep -v '^# gerado-em:' "$file" 2>/dev/null) \
            <(grep -v '^# gerado-em:' "$tmp"); then
        rm -f "$tmp"; _log INFO "Sem mudancas em ${file} (idempotente)"; return 0
    fi
    WRITE_CHANGED=1
    if [[ "$DRY_RUN" == "1" ]]; then
        _log INFO "[DRY-RUN] escreveria ${file}"; rm -f "$tmp"; return 0
    fi
    backup_file "$file"
    if install -m "$mode" "$tmp" "$file"; then _log OK "Escrito: ${file}"
    else _log ERROR "Falha ao escrever ${file}"; rm -f "$tmp"; return 1; fi
    rm -f "$tmp"
}

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    [[ "$DRY_RUN" == "1" ]] && return 0
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    cp -p "$f" "${BACKUP_DIR}/$(basename "$f").bak" 2>/dev/null && \
        _log INFO "Backup: ${f} -> ${BACKUP_DIR}/"
}

# ── [2] GUARDA: upgrade de versao em voo ─────────────────────────────────────
guard_upgrade_inflight() {
    if state_upgrade_inflight; then
        local running repo
        running=$(. /etc/os-release; echo "$VERSION_CODENAME")
        repo=$(grep -rhoE '\b(buster|bullseye|bookworm|trixie)\b' \
               /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | sort -u | tail -1)
        _log ERROR "Repos apontam para '${repo}' mas o sistema roda '${running}'."
        _log ERROR "Ha um upgrade de VERSAO em andamento."
        _log ERROR "Finalize com ./pve-upgrade.sh --apply, reinicie, valide,"
        _log ERROR "e so entao rode o tuning. ABORTANDO."
        state_event "ABORT_INFLIGHT" "repo=$repo running=$running"
        exit 1
    fi
}

# ── [1] Politica de NUMA balancing ───────────────────────────────────────────
# Com VMs pinadas (hostnodes=), o balanceamento automatico migra paginas e
# desfaz o pinning. Nesse caso ele TEM que ficar desligado.
detect_numa_policy() {
    local nodes pinned=0
    nodes=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
    if ls /etc/pve/qemu-server/*.conf >/dev/null 2>&1; then
        pinned=$(grep -lE '^numa[0-9]+:.*hostnodes=' /etc/pve/qemu-server/*.conf 2>/dev/null | wc -l)
    fi
    if [[ ${nodes:-1} -gt 1 && ${pinned:-0} -gt 0 ]]; then
        NUMA_BAL=0
        NUMA_REASON="${pinned} VM(s) com hostnodes= em ${nodes} nos NUMA"
        _log WARN "numa_balancing=0: ${NUMA_REASON}"
        _log WARN "  (com pinning, o balanceamento automatico desfaz o trabalho)"
    elif [[ ${nodes:-1} -gt 1 ]]; then
        NUMA_BAL=1
        NUMA_REASON="${nodes} nos NUMA, sem VMs pinadas"
        _log INFO "numa_balancing=1: ${NUMA_REASON}"
    else
        NUMA_BAL=0
        NUMA_REASON="host de 1 no NUMA (balanceamento inutil)"
        _log INFO "numa_balancing=0: ${NUMA_REASON}"
    fi
}

# ── Assinatura do estado: mudou parametro ou kernel? ─────────────────────────
tune_signature() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$SCRIPT_VERSION" "$(uname -r)" "$SWAPPINESS" "$NUMA_BAL" \
        "$GOVERNOR" "$ZFS_ARC_GB" "$HUGEPAGES_GB" "$STRICT_RPFILTER$DISABLE_HA" \
        | sha256sum | cut -c1-16
}

tune_state_file() { echo "$TUNE_DIR/state-$(uname -r).env"; }

tune_state_matches() {
    local f; f=$(tune_state_file)
    [[ -f "$f" ]] || return 1
    local saved; saved=$(grep -oP '^TUNE_SIG=\K.*' "$f" 2>/dev/null)
    [[ "$saved" == "$(tune_signature)" ]]
}

tune_state_write() {
    [[ "$DRY_RUN" == "1" ]] && return 0
    mkdir -p "$TUNE_DIR" 2>/dev/null || true
    cat > "$(tune_state_file)" <<EOF
# estado do tuning aplicado neste kernel — lido por pve-upgrade.sh --validate
TUNE_VERSION=$SCRIPT_VERSION
TUNE_SIG=$(tune_signature)
TUNE_APPLIED=$(date -Is)
TUNE_KERNEL=$(uname -r)
TUNE_PVE=$(pveversion 2>/dev/null | head -1 | grep -oP 'pve-manager/\K[^ /]+')
TUNE_SWAPPINESS=$SWAPPINESS
TUNE_NUMA_BAL=$NUMA_BAL
TUNE_NUMA_REASON=$NUMA_REASON
TUNE_GOVERNOR=${GOVERNOR:-nao-alterado}
TUNE_ZFS_ARC_GB=$ZFS_ARC_GB
TUNE_HUGEPAGES_GB=$HUGEPAGES_GB
TUNE_RPFILTER=$([[ $STRICT_RPFILTER -eq 1 ]] && echo strict || echo loose)
EOF
    _log OK "Estado gravado: $(tune_state_file)"
}

# ── Pre-requisitos ───────────────────────────────────────────────────────────
check_requirements() {
    _log STEP "Pre-requisitos"
    [[ "$(id -u)" -eq 0 ]] || { _log ERROR "Execute como root"; exit 1; }
    command -v apt-get >/dev/null || { _log ERROR "apt-get nao encontrado"; exit 1; }
    command -v sysctl  >/dev/null || { _log ERROR "sysctl nao encontrado"; exit 1; }
    touch "$LOG_FILE" 2>/dev/null || true
    state_init

    guard_upgrade_inflight        # [2]

    if command -v pveversion >/dev/null 2>&1; then
        local pvestr pvemajor
        pvestr=$(pveversion 2>/dev/null | head -1)
        _log OK "Proxmox detectado: ${pvestr}"
        pvemajor=$(sed -E 's|^pve-manager/([0-9]+).*|\1|' <<<"$pvestr")
        if [[ "$pvemajor" =~ ^[0-9]+$ ]] && [[ "$pvemajor" -le 8 ]]; then
            _log WARN "PVE ${pvemajor}.x sem suporte ou proximo do fim."
            _log WARN "O tuning funciona, mas rode ./pve-upgrade.sh --assess."
        fi
    else
        _log WARN "pveversion nao encontrado — tuning generico de host KVM"
    fi

    _log INFO "Kernel: $(uname -r)"

    # cruzamento com o estado do upgrade
    if [[ -f "$STATE_ROOT/hw-score" ]]; then
        _log INFO "hw-score: $(cat "$STATE_ROOT/hw-score")/100 -> target PVE $(cat "$STATE_ROOT/hw-target" 2>/dev/null)"
    fi
    if [[ -f "$EVENT_LOG" ]] && ! grep -q "VALIDATE_PASS.*kernel=$(uname -r)" "$EVENT_LOG" 2>/dev/null; then
        if grep -q "REBOOT_REQUIRED" "$EVENT_LOG" 2>/dev/null; then
            _log WARN "Este kernel ainda nao passou por 'pve-upgrade.sh --validate'."
            _log WARN "Recomendado validar o salto antes de tunar."
        fi
    fi

    if [[ "$SWAPPINESS" -eq 0 ]]; then
        _log WARN "swappiness=0: em kernel >= 3.5 isso desativa swap ate quase-OOM."
        _log WARN "Sob pressao o OOM killer pode matar uma VM. Prefira 1."
    fi
    _log OK "Pre-requisitos OK"
}

mem_snapshot() {
    local total avail
    total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    MEM_TOTAL_MB=$((total/1024)); MEM_AVAIL_MB=$((avail/1024))
    _log INFO "RAM total: $((total/1024/1024)) GB | disponivel: $((avail/1024/1024)) GB"
}

# =============================================================================
# UPDATE/UPGRADE
# =============================================================================
safe_upgrade() {
    [[ "$SKIP_UPGRADE" == "1" ]] && { _log INFO "--skip-upgrade — pulando pacotes"; return 0; }
    _log STEP "Update/upgrade de pacotes"

    local mode="upgrade"
    [[ "$FULL_UPGRADE" == "1" ]] && mode="dist-upgrade"

    if [[ "$DRY_RUN" == "1" ]]; then
        _log INFO "[DRY-RUN] apt-get update"
        _log INFO "[DRY-RUN] apt-get -y ${mode} (confdef/confold)"
        return 0
    fi

    local out
    if ! out=$(apt-get update 2>&1); then
        _log ERROR "apt-get update falhou:"; _log ERROR "${out}"
        if grep -q "401" <<<"$out" && grep -Rqs "enterprise.proxmox.com" /etc/apt/ 2>/dev/null; then
            _log WARN "Repo pve-enterprise sem assinatura (HTTP 401)."
            _log WARN "Sem subscription, troque para pve-no-subscription."
        fi
        _log WARN "Pulando upgrade — corrija os repositorios"
        state_event "APT_UPDATE_FAIL" ""
        return 1
    fi
    _log OK "apt-get update concluido"

    _log INFO "Aplicando apt-get ${mode} (preservando configs locais)..."
    if ! out=$(DEBIAN_FRONTEND=noninteractive apt-get -y \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            "$mode" 2>&1); then
        _log WARN "apt-get ${mode} reportou problemas:"; _log WARN "${out}"
        _log WARN "Continuando com o tuning — revise depois"
        state_event "APT_UPGRADE_WARN" "$mode"
        return 1
    fi
    _log OK "apt-get ${mode} concluido"
    state_event "APT_UPGRADE_OK" "$mode"

    if [[ "$FULL_UPGRADE" != "1" ]]; then
        local held
        held=$(apt-get -s dist-upgrade 2>/dev/null | awk '/^Inst /{c++} END{print c+0}')
        if [[ "${held:-0}" -gt 0 ]]; then
            _log WARN "${held} pacote(s) exigem dist-upgrade (ex.: pve-*)."
            _log WARN "Rode: bash ${SCRIPT_NAME} --full-upgrade"
        fi
    fi
}

# =============================================================================
# MODULOS
# =============================================================================
configure_modules() {
    _log STEP "Modulos de kernel"
    local needed=(br_netfilter nf_conntrack) cc=(tcp_bbr)
    local loaded=() m
    for m in "${needed[@]}" "${cc[@]}"; do
        if lsmod 2>/dev/null | grep -q "^${m} "; then
            _log INFO "Ja carregado: ${m}"; loaded+=("$m")
        elif run modprobe "$m" 2>/dev/null; then
            _log OK "Carregado: ${m}"; loaded+=("$m")
        else
            _log WARN "Indisponivel neste kernel: ${m} — pulando"
        fi
    done
    if [[ ${#loaded[@]} -gt 0 ]]; then
        write_if_changed "$MODULES_FILE" <<MODEOF
# ${MODULES_FILE}
# Gerenciado por ${SCRIPT_NAME} v${SCRIPT_VERSION}
# gerado-em: $(date -u +%Y-%m-%dT%H:%M:%SZ) kernel $(uname -r)
$(printf '%s\n' "${loaded[@]}")
MODEOF
    fi

    # [5] nf_conntrack_buckets so e gravavel no carregamento do modulo.
    # Via sysctl falha em silencio; o caminho persistente e modprobe.d.
    write_if_changed "$CONNTRACK_MODPROBE" <<CTEOF
# ${CONNTRACK_MODPROBE}
# Gerenciado por ${SCRIPT_NAME} v${SCRIPT_VERSION}
# gerado-em: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# hashsize = nf_conntrack_max/4. Via sysctl seria read-only apos o load.
options nf_conntrack hashsize=131072
CTEOF
    [[ "$WRITE_CHANGED" == "1" ]] && \
        _log WARN "hashsize do conntrack so vale apos reload do modulo ou reboot"
}

# =============================================================================
# SYSCTL — aplicacao TOLERANTE, chave por chave
# =============================================================================
apply_sysctl_tolerant() {
    local file="$1"
    local applied=() skipped=() valid_lines=()
    local line key val

    while IFS= read -r line; do
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && { valid_lines+=("$line"); continue; }
        key="${line%%=*}"; key="${key// }"
        val="${line#*=}";  val="${val# }"

        if [[ -e "/proc/sys/${key//.//}" ]]; then
            if [[ "$DRY_RUN" == "1" ]]; then
                _log INFO "[DRY-RUN] sysctl ${key} = ${val}"
                applied+=("$key"); valid_lines+=("$line")
            elif sysctl -w "${key}=${val}" >/dev/null 2>&1; then
                applied+=("$key"); valid_lines+=("$line")
            else
                _log WARN "Rejeitada pelo kernel: ${key} ('${val}') — pulando"
                skipped+=("$key")
            fi
        else
            _log WARN "Inexistente neste kernel: ${key} — pulando"
            skipped+=("$key")
        fi
    done

    if [[ ${#valid_lines[@]} -gt 0 ]]; then
        write_if_changed "$file" <<SYSFILEEOF
# ${file}
# Gerenciado por ${SCRIPT_NAME} v${SCRIPT_VERSION}
# gerado-em: $(date -u +%Y-%m-%dT%H:%M:%SZ) kernel $(uname -r)
# Apenas chaves aceitas por este kernel. Re-rode apos trocar de kernel.
$(printf '%s\n' "${valid_lines[@]}")
SYSFILEEOF
    fi
    _log OK "sysctl: ${#applied[@]} aplicadas, ${#skipped[@]} puladas"
    state_event "SYSCTL" "applied=${#applied[@]} skipped=${#skipped[@]} kernel=$(uname -r)"
}

configure_sysctl() {
    _log STEP "Sysctl tuning (tolerante, PVE 6..9)"
    mem_snapshot

    # [3] dirty por percentual nao escala: 15% de 128GB = 19,6GB sujos, e o
    # flush sincrono trava o I/O de todas as VMs. Acima de 32GB usa bytes.
    local dirty_block
    if [[ "$MEM_TOTAL_MB" -gt 32768 ]]; then
        dirty_block="vm.dirty_bytes = 2147483648
vm.dirty_background_bytes = 1073741824"
        _log INFO "RAM ${MEM_TOTAL_MB}MB > 32GB -> dirty_bytes (2GB/1GB) em vez de ratio"
    else
        dirty_block="vm.dirty_ratio = 15
vm.dirty_background_ratio = 5"
        _log INFO "RAM ${MEM_TOTAL_MB}MB -> dirty_ratio (15%/5%)"
    fi
    # dirty_bytes e dirty_ratio sao mutuamente exclusivos: escrever um zera
    # o outro. Por isso emitimos apenas um dos blocos, nunca os dois.

    # [4] rp_filter: strict (1) quebra roteamento assimetrico e exit nodes
    # EVPN. Loose (2) mantem anti-spoofing sem cortar trafego legitimo.
    local rpf=2
    [[ "$STRICT_RPFILTER" -eq 1 ]] && rpf=1
    if [[ -d /etc/pve/sdn ]] && [[ "$rpf" -eq 1 ]]; then
        _log WARN "SDN presente + rp_filter strict: exit nodes EVPN podem parar."
    fi
    _log INFO "rp_filter=${rpf} ($([[ $rpf -eq 1 ]] && echo strict || echo loose))"

    apply_sysctl_tolerant "$SYSCTL_FILE" << SYSCTLEOF
# -- Memoria virtual -----------------------------------------------
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = 50
${dirty_block}
vm.overcommit_memory = 0
vm.max_map_count = 262144

# -- AIO / file descriptors / inotify ------------------------------
fs.aio-max-nr = 1048576
fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192

# -- ARP cache (redes densas) --------------------------------------
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# -- Conntrack (buckets vao via modprobe.d, nao aqui) --------------
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 300
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15

# -- Bridge (exige br_netfilter, carregado antes) ------------------
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-arptables = 0

# -- Rede: buffers e filas -----------------------------------------
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# -- Congestion control --------------------------------------------
# BBR afeta so trafego ORIGINADO no host (backup PBS, migracao,
# replicacao ZFS). Trafego de guest e bridgeado em L2 e nao passa
# pela pilha TCP do host.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# -- TCP comportamento ---------------------------------------------
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_mtu_probing = 1

# -- Seguranca basica ----------------------------------------------
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = ${rpf}
net.ipv4.conf.default.rp_filter = ${rpf}
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0

# -- NUMA / scheduler ----------------------------------------------
# numa_balancing calculado: ${NUMA_REASON}
kernel.numa_balancing = ${NUMA_BAL}
kernel.sched_autogroup_enabled = 0
SYSCTLEOF
}

# =============================================================================
# CMDLINE DO KERNEL
# =============================================================================
detect_bootloader() {
    if command -v proxmox-boot-tool >/dev/null 2>&1 && [[ -f "$PBT_CMDLINE" ]] \
        && proxmox-boot-tool status 2>/dev/null | grep -qi 'uefi'; then
        echo "pbt"
    elif [[ -f "$GRUB_FILE" ]]; then echo "grub"
    else echo "none"; fi
}

strip_hp_tokens() {
    sed -E 's/(^| )hugepagesz=[^ ]+//g; s/(^| )hugepages=[0-9]+//g; s/(^| )transparent_hugepage=[^ ]+//g' <<<"$1" \
        | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

configure_hugepages() {
    if [[ "$HUGEPAGES_GB" -eq 0 ]]; then
        _log INFO "HugePages desligado. Use --hugepages N para reservar N GB no boot."
        return 0
    fi
    _log STEP "HugePages (via cmdline — efeito apos reboot)"
    mem_snapshot

    local req_mb=$((HUGEPAGES_GB * 1024))
    local max_safe_mb=$(( MEM_TOTAL_MB / 2 ))
    local reserve_floor_mb=$(( 8 * 1024 ))

    if [[ "$req_mb" -gt "$max_safe_mb" ]]; then
        _log WARN "${HUGEPAGES_GB}GB excede 50% da RAM — limitando a $((max_safe_mb/1024))GB"
        req_mb="$max_safe_mb"
    fi
    if [[ $(( MEM_TOTAL_MB - req_mb )) -lt "$reserve_floor_mb" ]]; then
        _log ERROR "Deixaria menos de 8GB para o host — ABORTANDO hugepages."
        return 1
    fi
    [[ "$req_mb" -gt "$MEM_AVAIL_MB" ]] && \
        _log WARN "RAM disponivel agora (${MEM_AVAIL_MB}MB) < reserva (${req_mb}MB); no boot reserva antes das VMs"

    local nr_pages=$(( req_mb / 2 ))
    local hp_args="hugepagesz=2M hugepages=${nr_pages} transparent_hugepage=madvise"
    _log INFO "Reservando ${nr_pages} hugepages de 2MB = $((nr_pages*2/1024))GB"

    case "$(detect_bootloader)" in
        pbt)
            _log INFO "proxmox-boot-tool/systemd-boot: editando ${PBT_CMDLINE}"
            local cur new
            cur=$(head -1 "$PBT_CMDLINE" 2>/dev/null || echo "")
            new="$(strip_hp_tokens "$cur") ${hp_args}"
            new=$(tr -s ' ' <<<"$new" | sed 's/^ *//; s/ *$//')
            write_if_changed "$PBT_CMDLINE" <<<"$new"
            [[ "$WRITE_CHANGED" == "1" ]] && \
                run proxmox-boot-tool refresh && _log OK "proxmox-boot-tool refresh"
            ;;
        grub)
            local cur_line cur new new_content
            cur_line=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | tail -1 || true)
            cur="${cur_line#GRUB_CMDLINE_LINUX_DEFAULT=}"
            cur="${cur#\"}"; cur="${cur%\"}"; cur="${cur#\'}"; cur="${cur%\'}"
            new="$(strip_hp_tokens "$cur") ${hp_args}"
            new=$(tr -s ' ' <<<"$new" | sed 's/^ *//; s/ *$//')
            new_content=$(awk -v repl="GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"" '
                BEGIN { done = 0 }
                /^GRUB_CMDLINE_LINUX_DEFAULT=/ { print repl; done = 1; next }
                { print } END { if (!done) print repl }' "$GRUB_FILE")
            printf '%s\n' "$new_content" | write_if_changed "$GRUB_FILE"
            if [[ "$WRITE_CHANGED" == "1" ]]; then
                if command -v update-grub >/dev/null 2>&1; then
                    run update-grub >/dev/null 2>&1 && _log OK "update-grub aplicado"
                elif command -v grub-mkconfig >/dev/null 2>&1; then
                    run grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 && _log OK "grub-mkconfig"
                else _log WARN "update-grub nao encontrado — atualize manualmente"; fi
            fi
            ;;
        *) _log WARN "Nenhum bootloader gerenciavel — pulando hugepages"; return 1 ;;
    esac

    if [[ "$DRY_RUN" != "1" && -w /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null && \
            _log OK "THP em madvise (runtime)"
    fi
    _log WARN "HugePages so valem APOS REBOOT. As VMs precisam de 'hugepages: 2'"
    _log WARN "na config para usar o pool, senao ele fica ocioso."
}

# =============================================================================
# CPU GOVERNOR
# =============================================================================
configure_governor() {
    [[ -z "$GOVERNOR" ]] && { _log INFO "Governor: nao alterado."; return 0; }
    _log STEP "CPU governor -> ${GOVERNOR}"

    local avail_file="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"
    [[ -r "$avail_file" ]] || { _log WARN "cpufreq indisponivel — pulando"; return 0; }
    if ! grep -qw "$GOVERNOR" "$avail_file"; then
        _log WARN "'${GOVERNOR}' nao existe. Disponiveis: $(cat "$avail_file")"
        return 1
    fi

    # [7] Custo em CPU antiga: sem intel_pstate, 'performance' trava o TDP
    # no maximo o tempo todo. Em Nehalem/Westmere isso e conta de luz e calor.
    local driver="?"
    [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]] && \
        driver=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)
    if [[ "$GOVERNOR" == "performance" && "$driver" != "intel_pstate" ]]; then
        _log WARN "driver '${driver}' (sem intel_pstate): 'performance' mantem"
        _log WARN "  a frequencia no maximo o tempo todo. Em Nehalem/Westmere"
        _log WARN "  isso custa energia e calor sem ganho proporcional."
        _log WARN "  Vale em host com VM sensivel a latencia; num host de"
        _log WARN "  backup, considere 'schedutil' ou nao mexer."
    fi

    local g count=0
    for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
        [[ -w "$g" ]] || continue
        if [[ "$DRY_RUN" == "1" ]]; then count=$((count+1))
        elif echo "$GOVERNOR" > "$g" 2>/dev/null; then count=$((count+1)); fi
    done
    _log OK "Governor aplicado em ${count} policy(ies)"

    write_if_changed "$GOV_UNIT" <<UNITEOF
# gerado-em: $(date -u +%Y-%m-%dT%H:%M:%SZ)
[Unit]
Description=proxmox_tune: CPU governor ${GOVERNOR}
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do [ -w "\$\$g" ] && echo ${GOVERNOR} > "\$\$g"; done; exit 0'

[Install]
WantedBy=multi-user.target
UNITEOF
    if [[ "$WRITE_CHANGED" == "1" ]]; then
        run systemctl daemon-reload
        run systemctl enable proxmox-tune-cpugov.service >/dev/null 2>&1 && \
            _log OK "Persistido via ${GOV_UNIT}"
    fi
}

# =============================================================================
# ZFS ARC
# =============================================================================
configure_zfs_arc() {
    [[ "$ZFS_ARC_GB" -eq 0 ]] && { _log INFO "ARC do ZFS: nao alterado."; return 0; }
    _log STEP "ZFS ARC -> teto de ${ZFS_ARC_GB} GB"

    if [[ ! -d /sys/module/zfs ]] && ! command -v zpool >/dev/null 2>&1; then
        _log WARN "Modulo zfs ausente — pulando --zfs-arc"; return 0
    fi

    mem_snapshot
    local arc_mb=$((ZFS_ARC_GB * 1024))
    if [[ "$arc_mb" -gt $(( MEM_TOTAL_MB / 2 )) ]]; then
        _log WARN "excede 50% da RAM — limitando a $((MEM_TOTAL_MB/2/1024))GB"
        arc_mb=$(( MEM_TOTAL_MB / 2 ))
    fi
    local arc_bytes=$(( arc_mb * 1024 * 1024 ))

    if [[ "$DRY_RUN" != "1" && -w /sys/module/zfs/parameters/zfs_arc_max ]]; then
        echo "$arc_bytes" > /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null && \
            _log OK "zfs_arc_max=${arc_bytes} em runtime (encolhe gradualmente)"
    fi

    write_if_changed "$ZFS_MODPROBE_FILE" <<ZFSEOF
# ${ZFS_MODPROBE_FILE}
# Gerenciado por ${SCRIPT_NAME} v${SCRIPT_VERSION}
# gerado-em: $(date -u +%Y-%m-%dT%H:%M:%SZ)
options zfs zfs_arc_max=${arc_bytes}
ZFSEOF
    if [[ "$WRITE_CHANGED" == "1" ]]; then
        if command -v update-initramfs >/dev/null 2>&1; then
            _log INFO "Atualizando initramfs (necessario p/ root em ZFS)..."
            run update-initramfs -u -k all >/dev/null 2>&1 && _log OK "initramfs atualizado"
        fi
        command -v proxmox-boot-tool >/dev/null 2>&1 && [[ -f "$PBT_CMDLINE" ]] && \
            run proxmox-boot-tool refresh >/dev/null 2>&1 && _log OK "proxmox-boot-tool refresh"
    fi
    # ZFS 2.4 renomeou arcstat -> zarcstat
    if command -v zarcstat >/dev/null 2>&1; then
        _log INFO "diagnostico do ARC: zarcstat (ZFS 2.4+)"
    elif command -v arc_summary >/dev/null 2>&1; then
        _log INFO "diagnostico do ARC: arc_summary"
    fi
}

# =============================================================================
# HA SERVICES — opcional, so em host standalone
# Num no isolado o pve-ha-lrm/crm ficam ociosos consumindo RAM e CPU. Em no
# de cluster, desliga-los quebra fencing e quorum — por isso a guarda dura.
# NAO mexemos no corosync: em host standalone ele ja nao roda, e num
# cluster desliga-lo e catastrofico.
# =============================================================================
configure_ha_services() {
    [[ "$DISABLE_HA" -eq 0 ]] && return 0
    _log STEP "Servicos de HA (standalone)"

    if [[ -f /etc/pve/corosync.conf ]]; then
        _log ERROR "corosync.conf presente: este no FAZ PARTE DE UM CLUSTER."
        _log ERROR "Desligar pve-ha-lrm/crm aqui quebra fencing e quorum."
        _log ERROR "IGNORANDO --disable-ha."
        state_event "HA_REFUSED" "no em cluster"
        return 1
    fi
    if command -v pvecm >/dev/null 2>&1 && pvecm status &>/dev/null; then
        _log ERROR "pvecm status respondeu: no aparenta estar em cluster."
        _log ERROR "IGNORANDO --disable-ha."
        state_event "HA_REFUSED" "pvecm status ok"
        return 1
    fi

    local svc
    for svc in pve-ha-lrm pve-ha-crm; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            run systemctl disable --now "$svc" >/dev/null 2>&1 && _log OK "desligado: $svc"
        else
            _log INFO "ja inativo: $svc"
        fi
    done
    _log INFO "reverter: systemctl enable --now pve-ha-lrm pve-ha-crm"
    state_event "HA_DISABLED" "standalone"
}

# =============================================================================
# VERIFICACAO FINAL
# =============================================================================
verify() {
    _log STEP "Verificacao pos-tuning"
    local cc qdisc sw nb rpf
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    sw=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
    nb=$(sysctl -n kernel.numa_balancing 2>/dev/null || echo "-")
    rpf=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo "?")
    _log INFO "cc=${cc} qdisc=${qdisc} swappiness=${sw} numa_balancing=${nb} rp_filter=${rpf}"

    _log INFO "Modulos: $(lsmod 2>/dev/null | awk '/^(br_netfilter|nf_conntrack|tcp_bbr) /{print $1}' | tr '\n' ' ')"

    local gov="-"
    [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]] && \
        gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    _log INFO "CPU governor: ${gov}"

    [[ -r /sys/module/zfs/parameters/zfs_arc_max ]] && \
        _log INFO "zfs_arc_max: $(cat /sys/module/zfs/parameters/zfs_arc_max) bytes (0 = default)"

    ( systemctl is-active ksmtuned >/dev/null 2>&1 || systemctl is-active ksm >/dev/null 2>&1 ) && \
        _log INFO "KSM ativo (dedup de RAM entre VMs)"

    _log INFO "HugePages runtime: $(awk '/HugePages_Total/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"

    # Colisao de chaves entre arquivos de /etc/sysctl.d (vence o nome maior)
    local dup
    dup=$(grep -hoP '^\s*\K[a-z0-9_.]+(?=\s*=)' /etc/sysctl.d/*.conf /etc/sysctl.conf 2>/dev/null \
          | sort | uniq -d)
    if [[ -n "$dup" ]]; then
        _log WARN "chaves definidas em mais de um arquivo (vence o de nome maior):"
        local k
        while read -r k; do
            [[ -z "$k" ]] && continue
            _log WARN "  $k -> $(grep -lE "^\s*${k//./\\.}\s*=" /etc/sysctl.d/*.conf /etc/sysctl.conf 2>/dev/null | tr '\n' ' ')"
        done <<<"$dup"
    fi

    mem_snapshot
    state_facts_write
    tune_state_write
    state_event "TUNE_APPLIED" "kernel=$(uname -r) sig=$(tune_signature) numa_bal=$NUMA_BAL"

    echo ""
    _log OK "Tuning concluido. Log: ${LOG_FILE} | Estado: $(tune_state_file)"
    [[ "$DRY_RUN" == "1" ]] && _log WARN "Foi DRY-RUN — nada foi alterado."
    [[ "$HUGEPAGES_GB" -gt 0 && "$DRY_RUN" != "1" ]] && \
        _log WARN "REINICIE para ativar as hugepages."
    return 0
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo "${C_DIM}${SCRIPT_NAME} v${SCRIPT_VERSION} — $(date '+%H:%M:%S')${C_NC}"
    [[ "$DRY_RUN" == "1" ]] && _log WARN "MODO DRY-RUN — nenhuma alteracao"

    check_requirements
    detect_numa_policy         # [1] antes do sysctl, define NUMA_BAL

    # [6] Ja tunado neste kernel com estes parametros?
    if tune_state_matches && [[ "$FORCE" -eq 0 && "$SKIP_UPGRADE" -eq 1 ]]; then
        _log OK "Kernel $(uname -r) ja tunado com estes parametros — nada a fazer."
        _log INFO "Use --force para re-aplicar."
        . "$(tune_state_file)" 2>/dev/null || true
        _log INFO "Aplicado em: ${TUNE_APPLIED:-?} por v${TUNE_VERSION:-?}"
        exit 0
    fi
    if state_tune_current && ! tune_state_matches; then
        _log INFO "Estado deste kernel existe mas mudou (versao ou parametro) — re-aplicando"
    elif ! state_tune_current; then
        _log INFO "Primeiro tuning neste kernel ($(uname -r))"
    fi

    mem_snapshot
    safe_upgrade
    configure_modules          # ANTES do sysctl — ordem importa
    configure_sysctl
    configure_hugepages
    configure_governor
    configure_zfs_arc
    configure_ha_services
    verify
}

main "$@"
