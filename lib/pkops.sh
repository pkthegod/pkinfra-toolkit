#!/usr/bin/env bash
# =============================================================================
# pkops.sh — v1.0  (Platform Kit Ops)
#
# Camada de estado, eventos e callbacks compartilhada entre os scripts de
# infraestrutura. Generaliza o bloco que ja existia entre pve-upgrade.sh e
# proxmox_tune.sh, agora sem duplicacao: UM arquivo, sourced por todos.
#
# DUPLA NATUREZA (de proposito):
#   sourced   -> biblioteca. Expoe pk_init, pk_emit, pk_state_set, pk_stale...
#   executado -> CLI. pkops manifest | drift | timeline | hooks | doctor
# Um arquivo so para dar scp na frota inteira.
#
# INSTALACAO
#   install -m 0755 pkops.sh /usr/local/lib/pkops.sh
#   ln -sf /usr/local/lib/pkops.sh /usr/local/sbin/pkops
#
# USO COMO BIBLIOTECA (nos seus scripts)
#   TOOL="meu-script"; VERSION="1.0"
#   . /usr/local/lib/pkops.sh
#   pk_init
#   pk_emit "algo.aconteceu" "detalhe=x"
#   pk_state_set tuning profile=dns kernel="$(uname -r)"
#   pk_stale tuning && echo "estado defasado, re-aplicar"
#
# USO COMO CLI
#   pkops manifest       gera /var/lib/pkops/manifest.md (+ .json)
#   pkops drift          compara estado DECLARADO x REAL
#   pkops timeline       historico de eventos, legivel
#   pkops doctor         diagnostico da propria camada
#   pkops hooks list|test
#   pkops fleet          agrega JSON do validate.sh (stdin ou arquivos)
# =============================================================================

PKOPS_VERSION="1.0"
PKOPS_SCHEMA=2

PK_ROOT="${PK_ROOT:-/var/lib/pkops}"
PK_STATE="${PK_ROOT}/state"
PK_EVENTS="${PK_ROOT}/events.log"
PK_FACTS="${PK_ROOT}/facts.env"
PK_MANIFEST_MD="${PK_ROOT}/manifest.md"
PK_MANIFEST_JSON="${PK_ROOT}/manifest.json"
PK_DRIFT="${PK_ROOT}/drift.log"
PK_HOOKS="${PK_HOOKS:-/etc/pkops/hooks.d}"
PK_LEGACY=(/var/lib/pve-maint /var/lib/pve-upgrade /var/lib/tune-profile)

# TOOL/VERSION vem do script que faz o source; default se rodar sozinho
TOOL="${TOOL:-pkops}"
VERSION="${VERSION:-$PKOPS_VERSION}"

# =============================================================================
# BIBLIOTECA
# =============================================================================

pk_init() {
    mkdir -p "$PK_ROOT" "$PK_STATE" "$PK_HOOKS" 2>/dev/null || return 1
    # migracao dos diretorios antigos: COPIA (nao move), idempotente
    if [[ ! -f "${PK_ROOT}/.migrated" ]]; then
        local d
        for d in "${PK_LEGACY[@]}"; do
            [[ -d "$d" ]] || continue
            cp -an "$d/." "$PK_ROOT/" 2>/dev/null || true
            # events.log antigo tinha o mesmo formato; concatena sem duplicar
            [[ -f "$d/events.log" && -f "$PK_EVENTS" ]] && \
                sort -u "$d/events.log" "$PK_EVENTS" -o "$PK_EVENTS" 2>/dev/null || true
        done
        : > "${PK_ROOT}/.migrated"
    fi
    echo "$PKOPS_SCHEMA" > "${PK_ROOT}/.schema" 2>/dev/null
    return 0
}

# --- eventos: o barramento de comunicacao entre os scripts -------------------
# Formato compativel com o events.log que ja existe:
#   ISO8601|host|tool|versao|evento|detalhe
pk_emit() { # <evento> [detalhe]
    local ev="$1" det="${2:-}" ts host
    ts=$(date -Is); host=$(hostname)
    mkdir -p "$PK_ROOT" 2>/dev/null
    printf '%s|%s|%s|%s|%s|%s\n' "$ts" "$host" "$TOOL" "$VERSION" "$ev" "$det" \
        >> "$PK_EVENTS" 2>/dev/null
    pk_hooks_fire "$ev" "$det" "$ts"
    return 0
}

# --- callbacks ---------------------------------------------------------------
# Cada executavel em hooks.d recebe: $1=evento $2=detalhe $3=timestamp
# e no ambiente: PK_TOOL, PK_VERSION, PK_HOST, PK_ROOT.
# Hook que falha NUNCA derruba quem emitiu — so registra.
pk_hooks_fire() { # <evento> <detalhe> <ts>
    [[ -d "$PK_HOOKS" ]] || return 0
    [[ "${PK_NO_HOOKS:-0}" == "1" ]] && return 0
    local h rc
    for h in "$PK_HOOKS"/*.sh; do
        [[ -x "$h" ]] || continue
        PK_TOOL="$TOOL" PK_VERSION="$VERSION" PK_HOST="$(hostname)" PK_ROOT="$PK_ROOT" \
          timeout 10 "$h" "$1" "$2" "$3" >/dev/null 2>&1
        rc=$?
        [[ $rc -ne 0 ]] && printf '%s|%s|pkops|%s|hook.failed|%s rc=%s\n' \
            "$3" "$(hostname)" "$PKOPS_VERSION" "$(basename "$h")" "$rc" >> "$PK_EVENTS" 2>/dev/null
    done
    return 0
}

# --- estado declarado --------------------------------------------------------
# Cada componente tem um .env. Sempre grava kernel e timestamp junto: e assim
# que pk_stale sabe se o estado ainda vale.
pk_state_set() { # <componente> k=v [k=v...]
    local comp="$1"; shift
    mkdir -p "$PK_STATE" 2>/dev/null
    local f="${PK_STATE}/${comp}.env" tmp kv k
    tmp=$(mktemp) || return 1
    # preserva chaves antigas nao sobrescritas
    if [[ -f "$f" ]]; then
        grep -vE "^(PK_APPLIED_AT|PK_KERNEL|PK_TOOL|PK_TOOL_VERSION)=" "$f" > "$tmp" 2>/dev/null
        for kv in "$@"; do
            k="${kv%%=*}"
            grep -vE "^${k}=" "$tmp" > "${tmp}.n" 2>/dev/null && mv "${tmp}.n" "$tmp"
        done
    fi
    for kv in "$@"; do printf '%s\n' "$kv" >> "$tmp"; done
    {
        printf 'PK_APPLIED_AT=%s\n' "$(date -Is)"
        printf 'PK_KERNEL=%s\n' "$(uname -r)"
        printf 'PK_TOOL=%s\n' "$TOOL"
        printf 'PK_TOOL_VERSION=%s\n' "$VERSION"
    } >> "$tmp"
    install -m 0644 "$tmp" "$f"; rm -f "$tmp"
    pk_emit "state.set" "component=${comp} $*"
    return 0
}

pk_state_get() { # <componente> [chave]
    local f="${PK_STATE}/${1}.env"
    [[ -f "$f" ]] || return 1
    if [[ -n "${2:-}" ]]; then grep -oP "^${2}=\K.*" "$f" | head -1
    else cat "$f"; fi
}

pk_state_list() {
    # glob direto em vez de `ls | xargs basename`: nao depende de como o ls
    # formata nome nenhum, e o nullglob evita devolver o proprio padrao
    # quando o diretorio esta vazio.
    local f n
    shopt -q nullglob; local tinha_nullglob=$?
    shopt -s nullglob
    for f in "$PK_STATE"/*.env; do
        n=${f##*/}
        printf '%s\n' "${n%.env}"
    done
    [[ $tinha_nullglob -eq 0 ]] || shopt -u nullglob
}

# --- defasagem ---------------------------------------------------------------
# Um estado esta DEFASADO se foi aplicado em outro kernel. Todo tuning de
# sysctl depende do kernel: chave que existia some, chave nova aparece.
pk_stale() { # <componente> -> 0 se DEFASADO
    local k; k=$(pk_state_get "$1" PK_KERNEL 2>/dev/null) || return 1
    [[ -n "$k" && "$k" != "$(uname -r)" ]]
}

pk_facts() {
    mkdir -p "$PK_ROOT" 2>/dev/null
    local flags cpu ram cores numa pcid aes prod virt pve deb
    flags=$(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo)
    cpu=$(awk -F: '/^model name/{sub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)
    ram=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    cores=$(nproc 2>/dev/null || echo 0)
    numa=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
    grep -qw pcid <<<"$flags" && pcid=1 || pcid=0
    grep -qw aes  <<<"$flags" && aes=1  || aes=0
    prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
    virt=$(systemd-detect-virt 2>/dev/null || echo none)
    pve=$(pveversion 2>/dev/null | head -1 | grep -oP 'pve-manager/\K[^ /]+')
    deb=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-unknown}")
    # ASPAS OBRIGATORIAS: "Intel(R) Xeon(R)" sem aspas e erro de sintaxe no
    # source, e o erro aborta a leitura do resto do arquivo em silencio.
    cat > "$PK_FACTS" <<FACTS
# gerado por ${TOOL} v${VERSION} em $(date -Is)
FACT_HOST="$(hostname)"
FACT_PRODUCT="${prod}"
FACT_VIRT="${virt}"
FACT_CPU="${cpu}"
FACT_CORES="${cores}"
FACT_RAM_MB="${ram}"
FACT_NUMA_NODES="${numa}"
FACT_PCID="${pcid}"
FACT_AES="${aes}"
FACT_KERNEL="$(uname -r)"
FACT_DEBIAN="${deb}"
FACT_PVE="${pve:-nao}"
FACTS
    return 0
}

pk_facts_read() { [[ -f "$PK_FACTS" ]] && . "$PK_FACTS" 2>/dev/null; return 0; }

# =============================================================================
# CLI
# =============================================================================

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
[[ -t 1 ]] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; }
_p()  { printf '%s\n' "$*"; }
_h()  { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

# --- checadores de deriva: DECLARADO x REAL ----------------------------------
# Cada um imprime linhas "SEV|nome|detalhe". Adicionar checador novo = uma
# funcao com prefixo _drift_ ; o motor descobre sozinho.
_drift_sysctl_profile() {
    local prof; prof=$(pk_state_get tuning profile 2>/dev/null) || return 0
    [[ -z "$prof" ]] && return 0
    local pf="/etc/sysctl.d/96-tune-profile-${prof}.conf"
    [[ -f "$pf" ]] || { echo "FAIL|perfil ${prof}|arquivo ${pf} sumiu"; return 0; }
    local line key val cur n=0
    while IFS= read -r line; do
        [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
        key="${line%%=*}"; key="${key// }"; val="${line#*=}"; val="${val# }"
        [[ -e "/proc/sys/${key//.//}" ]] || continue
        cur=$(sysctl -n "$key" 2>/dev/null)
        [[ "$(tr -s ' ' <<<"$cur")" == "$(tr -s ' ' <<<"$val")" ]] || {
            echo "WARN|${key}|declarado=${val} efetivo=${cur}"; n=$((n+1)); }
    done < "$pf"
    [[ $n -eq 0 ]] && echo "OK|perfil ${prof}|sem deriva"
}

_drift_kernel_stale() {
    local c
    for c in $(pk_state_list); do
        if pk_stale "$c"; then
            echo "WARN|${c}|aplicado no kernel $(pk_state_get "$c" PK_KERNEL), rodando $(uname -r)"
        else
            echo "OK|${c}|estado coerente com o kernel atual"
        fi
    done
}

_drift_facts() {
    [[ -f "$PK_FACTS" ]] || { echo "WARN|facts|nunca coletados"; return 0; }
    local old_k old_r
    old_k=$(grep -oP '^FACT_KERNEL="?\K[^"]*' "$PK_FACTS")
    old_r=$(grep -oP '^FACT_RAM_MB="?\K[^"]*' "$PK_FACTS")
    local now_r; now_r=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    [[ "$old_k" != "$(uname -r)" ]] && echo "WARN|facts.kernel|gravado ${old_k}, atual $(uname -r)"
    [[ "${old_r:-0}" -ne "${now_r:-0}" ]] && echo "WARN|facts.ram|gravado ${old_r}MB, atual ${now_r}MB (balloon? hotplug?)"
    [[ "$old_k" == "$(uname -r)" && "${old_r:-0}" -eq "${now_r:-0}" ]] && echo "OK|facts|coerentes"
}

_drift_hooks() {
    local n=0 h
    for h in "$PK_HOOKS"/*.sh; do [[ -f "$h" ]] || continue; n=$((n+1))
        [[ -x "$h" ]] || echo "WARN|hook $(basename "$h")|existe mas NAO e executavel (nunca roda)"
    done
    echo "OK|hooks|${n} registrado(s)"
}

cmd_drift() {
    pk_init
    _h "Deriva: declarado x real"
    local sev name det total_w=0 total_f=0 fn
    for fn in $(declare -F | awk '{print $3}' | grep '^_drift_'); do
        while IFS='|' read -r sev name det; do
            [[ -z "$sev" ]] && continue
            case "$sev" in
                OK)   printf '  %sOK%s   %-38s %s\n' "$C_G" "$C_0" "$name" "$det" ;;
                WARN) printf '  %sWARN%s %-38s %s\n' "$C_Y" "$C_0" "$name" "$det"; total_w=$((total_w+1)) ;;
                FAIL) printf '  %sFAIL%s %-38s %s\n' "$C_R" "$C_0" "$name" "$det"; total_f=$((total_f+1)) ;;
            esac
            [[ "$sev" != "OK" ]] && printf '%s|%s|%s|%s\n' "$(date -Is)" "$sev" "$name" "$det" >> "$PK_DRIFT"
        done < <("$fn")
    done
    _h "Resumo"
    printf '  %sWARN %d%s   %sFAIL %d%s\n' "$C_Y" "$total_w" "$C_0" "$C_R" "$total_f" "$C_0"
    [[ $total_w -gt 0 || $total_f -gt 0 ]] && _p "  historico: ${PK_DRIFT}"
    [[ $total_f -gt 0 ]] && return 2
    [[ $total_w -gt 0 ]] && return 1
    return 0
}

cmd_manifest() {
    pk_init; pk_facts; pk_facts_read
    local c k v
    {
        printf '# Estado do host: %s\n\n' "$(hostname)"
        printf '_Gerado por pkops v%s em %s — nao edite a mao._\n\n' "$PKOPS_VERSION" "$(date -Is)"
        printf '## Hardware e SO\n\n'
        printf '| item | valor |\n|---|---|\n'
        printf '| Produto | %s |\n' "${FACT_PRODUCT:-?}"
        printf '| Virtualizacao | %s |\n' "${FACT_VIRT:-?}"
        printf '| CPU | %s |\n' "${FACT_CPU:-?}"
        printf '| Cores / RAM | %s / %s MB |\n' "${FACT_CORES:-?}" "${FACT_RAM_MB:-?}"
        printf '| Nos NUMA | %s |\n' "${FACT_NUMA_NODES:-?}"
        printf '| PCID / AES-NI | %s / %s |\n' "${FACT_PCID:-?}" "${FACT_AES:-?}"
        printf '| Debian | %s |\n' "${FACT_DEBIAN:-?}"
        printf '| Kernel | %s |\n' "${FACT_KERNEL:-?}"
        printf '| Proxmox VE | %s |\n\n' "${FACT_PVE:-nao}"

        printf '## Componentes declarados\n\n'
        if [[ -z "$(pk_state_list)" ]]; then
            printf '_Nenhum componente registrou estado ainda._\n\n'
        else
            printf '| componente | ferramenta | aplicado em | kernel | coerente |\n'
            printf '|---|---|---|---|---|\n'
            for c in $(pk_state_list); do
                pk_stale "$c" && v='**NAO**' || v='sim'
                printf '| %s | %s v%s | %s | %s | %s |\n' "$c" \
                    "$(pk_state_get "$c" PK_TOOL)" "$(pk_state_get "$c" PK_TOOL_VERSION)" \
                    "$(pk_state_get "$c" PK_APPLIED_AT)" "$(pk_state_get "$c" PK_KERNEL)" "$v"
            done
            printf '\n'
            for c in $(pk_state_list); do
                printf '### %s\n\n```\n' "$c"
                grep -vE '^PK_' "${PK_STATE}/${c}.env" 2>/dev/null
                printf '```\n\n'
            done
        fi

        printf '## Servicos relevantes\n\n'
        printf '| servico | estado | LimitNOFILE |\n|---|---|---|\n'
        local s
        for s in named bind9 unbound zabbix-proxy zabbix-agent docker postgresql \
                 pveproxy pve-cluster nginx mongod genieacs-cwmp; do
            systemctl list-unit-files "${s}.service" &>/dev/null || continue
            printf '| %s | %s | %s |\n' "$s" \
                "$(systemctl is-active "$s" 2>/dev/null)" \
                "$(systemctl show "$s" -p LimitNOFILE --value 2>/dev/null)"
        done
        printf '\n'

        printf '## Ultimos eventos\n\n```\n'
        [[ -f "$PK_EVENTS" ]] && tail -15 "$PK_EVENTS" | while IFS='|' read -r ts h t vv ev det; do
            printf '%s  %-14s %-22s %s\n' "${ts:0:19}" "$t" "$ev" "$det"
        done
        printf '```\n\n'

        printf '## Deriva no momento da geracao\n\n```\n'
        PK_NO_HOOKS=1 cmd_drift 2>/dev/null | sed -e 's/\x1b\[[0-9;]*m//g' -e '/^$/d'
        printf '```\n'
    } > "$PK_MANIFEST_MD"

    # versao para maquina
    {
        printf '{"host":"%s","generated":"%s","pkops":"%s","facts":{' \
            "$(hostname)" "$(date -Is)" "$PKOPS_VERSION"
        local first=1
        while IFS='=' read -r k v; do
            [[ "$k" =~ ^FACT_ ]] || continue
            v="${v%\"}"; v="${v#\"}"          # tira as aspas do arquivo
            [[ $first -eq 0 ]] && printf ','; first=0
            printf '"%s":"%s"' "${k#FACT_}" "${v//\"/\\\"}"
        done < "$PK_FACTS"
        printf '},"components":{'
        first=1
        for c in $(pk_state_list); do
            [[ $first -eq 0 ]] && printf ','; first=0
            pk_stale "$c" && v=true || v=false
            printf '"%s":{"applied_at":"%s","kernel":"%s","tool":"%s","stale":%s}' \
                "$c" "$(pk_state_get "$c" PK_APPLIED_AT)" "$(pk_state_get "$c" PK_KERNEL)" \
                "$(pk_state_get "$c" PK_TOOL)" "$v"
        done
        printf '}}\n'
    } > "$PK_MANIFEST_JSON"

    _p "${C_G}OK${C_0} ${PK_MANIFEST_MD}"
    _p "${C_G}OK${C_0} ${PK_MANIFEST_JSON}"
    pk_emit "manifest.generated" "componentes=$(pk_state_list | wc -l)"
}

cmd_timeline() {
    pk_init
    local n="${1:-40}"
    _h "Historico (ultimos ${n})"
    [[ -f "$PK_EVENTS" ]] || { _p "  sem eventos"; return 0; }
    # SC2034: vv nao e lido, mas TEM de existir — o read e posicional e sem
    # ele os campos ev/det viriam deslocados. Remover a variavel quebra o
    # parsing da linha de evento.
    # shellcheck disable=SC2034
    tail -"$n" "$PK_EVENTS" | while IFS='|' read -r ts h t vv ev det; do
        local col="$C_0"
        case "$ev" in
            *fail*|*FAIL*|ABORT*) col="$C_R" ;;
            *warn*|*stale*)       col="$C_Y" ;;
            *ok*|*OK*|*applied*|*PASS*) col="$C_G" ;;
        esac
        printf '  %s  %-14s %s%-24s%s %s\n' "${ts:0:19}" "$t" "$col" "$ev" "$C_0" "$det"
    done
}

cmd_hooks() {
    pk_init
    case "${1:-list}" in
        list)
            _h "Hooks em ${PK_HOOKS}"
            local h found=0
            for h in "$PK_HOOKS"/*.sh; do
                [[ -f "$h" ]] || continue; found=1
                [[ -x "$h" ]] && printf '  %sativo%s   %s\n' "$C_G" "$C_0" "$(basename "$h")" \
                             || printf '  %sinerte%s  %s (chmod +x para ativar)\n' "$C_Y" "$C_0" "$(basename "$h")"
            done
            [[ $found -eq 0 ]] && _p "  nenhum hook instalado"
            ;;
        test)
            _h "Disparando evento de teste"
            pk_emit "pkops.test" "origem=cli ts=$(date +%s)"
            _p "  evento emitido; veja 'pkops timeline'"
            ;;
        example)
            mkdir -p "$PK_HOOKS"
            cat > "${PK_HOOKS}/10-jsonl.sh.example" <<'HOOKEOF'
#!/usr/bin/env bash
# $1=evento $2=detalhe $3=timestamp | env: PK_TOOL PK_VERSION PK_HOST PK_ROOT
printf '{"ts":"%s","host":"%s","tool":"%s","event":"%s","detail":"%s"}\n' \
  "$3" "$PK_HOST" "$PK_TOOL" "$1" "${2//\"/\\\"}" >> "${PK_ROOT}/events.jsonl"
HOOKEOF
            cat > "${PK_HOOKS}/20-zabbix.sh.example" <<'HOOKEOF'
#!/usr/bin/env bash
# Manda o evento para um item trapper do Zabbix.
command -v zabbix_sender >/dev/null || exit 0
ZBX_SERVER="${ZBX_SERVER:-127.0.0.1}"
zabbix_sender -z "$ZBX_SERVER" -s "$PK_HOST" -k "pkops.event" \
  -o "$1 ${2}" >/dev/null 2>&1 || true
HOOKEOF
            cat > "${PK_HOOKS}/30-git.sh.example" <<'HOOKEOF'
#!/usr/bin/env bash
# Versiona o manifest a cada mudanca de estado. Historico auditavel de graca.
[[ "$1" == state.set || "$1" == manifest.generated ]] || exit 0
cd "$PK_ROOT" || exit 0
[[ -d .git ]] || { git init -q; git config user.email pkops@local; git config user.name pkops; }
git add manifest.md manifest.json state/ 2>/dev/null
git diff --cached --quiet 2>/dev/null || \
  git commit -qm "[$PK_TOOL] $1 ${2}" 2>/dev/null
HOOKEOF
            cat > "${PK_HOOKS}/40-alerta.sh.example" <<'HOOKEOF'
#!/usr/bin/env bash
# So reage a evento ruim. Troque o echo por curl/webhook/mail.
case "$1" in
  *fail*|ABORT*|*.stale) : ;;
  *) exit 0 ;;
esac
logger -t pkops "ALERTA [$PK_TOOL] $1 $2"
HOOKEOF
            chmod 0644 "${PK_HOOKS}"/*.example
            _h "Exemplos criados em ${PK_HOOKS}"
            _p "  ative com:  mv X.sh.example X.sh && chmod +x X.sh"
            ls -1 "${PK_HOOKS}"/*.example | sed 's|^|  |'
            ;;
        *) _p "uso: pkops hooks [list|test|example]"; return 2 ;;
    esac
}

# Agrega JSON do validate.sh da frota inteira.
#   ssh host "validate.sh --json" > /tmp/f/host.json ; pkops fleet /tmp/f/*.json
cmd_fleet() {
    _h "Frota"
    command -v jq >/dev/null || { _p "  ${C_Y}jq necessario${C_0} (apt install jq)"; return 2; }
    local f n=0
    printf '  %-22s %5s %5s %5s  %s\n' HOST OK WARN FAIL "PIORES"
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        n=$((n+1))
        jq -r '"  \(.host|.[0:22]|. + (" "*(22-length))) \(.summary.ok|tostring|(" "*(5-length))+.) \(.summary.warn|tostring|(" "*(5-length))+.) \(.summary.fail|tostring|(" "*(5-length))+.)  \([.checks[]|select(.severity=="FAIL")|.name]|join(", ")|.[0:50])"' "$f" 2>/dev/null
    done
    [[ $n -eq 0 ]] && _p "  nenhum arquivo JSON informado"
}

cmd_doctor() {
    pk_init
    _h "Diagnostico da camada pkops"
    printf '  %-24s %s\n' "versao"  "$PKOPS_VERSION (schema $PKOPS_SCHEMA)"
    printf '  %-24s %s\n' "raiz"    "$PK_ROOT"
    printf '  %-24s %s\n' "hooks"   "$PK_HOOKS"
    [[ -w "$PK_ROOT" ]] && printf '  %sOK%s   raiz gravavel\n' "$C_G" "$C_0" \
                        || printf '  %sFAIL%s raiz NAO gravavel (rode como root)\n' "$C_R" "$C_0"
    printf '  %-24s %s\n' "eventos" "$( [[ -f $PK_EVENTS ]] && wc -l < "$PK_EVENTS" || echo 0 ) registros"
    printf '  %-24s %s\n' "componentes" "$(pk_state_list | tr '\n' ' ')"

    # rotacao: events.log e append-only e cresce para sempre
    if [[ -f "$PK_EVENTS" ]]; then
        local sz; sz=$(stat -c %s "$PK_EVENTS")
        [[ $sz -gt 5242880 ]] && printf '  %sWARN%s events.log com %s MB — considere logrotate\n' \
            "$C_Y" "$C_0" "$((sz/1024/1024))"
    fi

    _h "Integracao dos scripts"
    local s
    for s in pve-upgrade.sh proxmox_tune.sh tune-profile.sh setup-unbound.sh validate.sh; do
        local p; p=$(command -v "$s" 2>/dev/null || ls /usr/local/sbin/"$s" /root/"$s" 2>/dev/null | head -1)
        if [[ -n "$p" ]]; then
            grep -q 'pkops.sh' "$p" 2>/dev/null \
                && printf '  %sOK%s   %-22s integrado\n' "$C_G" "$C_0" "$s" \
                || printf '  %sWARN%s %-22s presente mas NAO integrado\n' "$C_Y" "$C_0" "$s"
        fi
    done
    _p ""
    _p "  Para integrar, no topo do script (depois de TOOL/VERSION):"
    _p "    [[ -f /usr/local/lib/pkops.sh ]] && . /usr/local/lib/pkops.sh && pk_init"
}

cmd_help() { sed -n '2,40p' "${BASH_SOURCE[0]}"; }

_pkops_main() {
    case "${1:-help}" in
        manifest) shift; cmd_manifest "$@" ;;
        drift)    shift; cmd_drift "$@" ;;
        timeline) shift; cmd_timeline "$@" ;;
        hooks)    shift; cmd_hooks "$@" ;;
        fleet)    shift; cmd_fleet "$@" ;;
        doctor)   shift; cmd_doctor "$@" ;;
        facts)    pk_init; pk_facts; cat "$PK_FACTS" ;;
        emit)     shift; pk_init; pk_emit "$@" ;;
        state)    shift; pk_init
                  case "${1:-}" in
                    set) shift; pk_state_set "$@" ;;
                    get) shift; pk_state_get "$@" ;;
                    list) pk_state_list ;;
                    *) _p "uso: pkops state set|get|list" ; return 2 ;;
                  esac ;;
        help|-h|--help) cmd_help ;;
        *) _p "comando desconhecido: $1"; cmd_help; return 2 ;;
    esac
}

# Sourced -> biblioteca (nada executa). Executado -> CLI.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _pkops_main "$@"
fi
