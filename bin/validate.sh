#!/usr/bin/env bash
# =============================================================================
# validate.sh — v1.0
# Suite unificada de validacao de ESTADO DE RUNTIME.
#
# ESCOPO — o que entra e o que NAO entra:
#   ENTRA : o servico esta de pe? a config carregou? ele responde certo?
#           o tuning aplicado ainda vale para o kernel atual?
#   NAO ENTRA: teste unitario de funcao com mock. Isso e outra categoria,
#           roda antes do deploy, sem host real. Ver notas no final.
#
# MODULOS (auto-detectados, ou escolhidos com --only)
#   core          SO, kernel, disco, memoria, reboot pendente, colisao sysctl
#   tuning        perfil do tune-profile.sh aplicado e coerente
#   bind          named/bind9
#   unbound       unbound (inclui o teste de trust anchor)
#   zabbix-proxy  proxy + backend
#   docker        daemon, disco, rotacao de log, inotify
#   pve           host Proxmox
#
# SAIDA
#   humano (padrao) | --json (para item do Zabbix)
# CODIGO DE SAIDA
#   0 = tudo ok | 1 = ha WARN | 2 = ha FAIL
#
# Uso:
#   ./validate.sh
#   ./validate.sh --only unbound,tuning
#   ./validate.sh --json | jq .
#   ./validate.sh --list
# =============================================================================
set -uo pipefail

VERSION="1.0"
JSON=0; ONLY=""; QUIET=0
STATE_ROOT="/var/lib/pve-maint"
TUNE_STATE="/var/lib/tune-profile"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)  JSON=1 ;;
    --only)  shift; ONLY="${1:-}" ;;
    --quiet) QUIET=1 ;;
    --list)  echo "core tuning bind unbound zabbix-proxy docker pve"; exit 0 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "flag desconhecida: $1"; exit 2 ;;
  esac
  shift
done

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
[[ -t 1 && $JSON -eq 0 ]] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; }

N_OK=0; N_WARN=0; N_FAIL=0; N_SKIP=0
RESULTS=()      # modulo|severidade|nome|detalhe
CUR_MOD=""

# --- registro de resultado. Nunca depende de $? implicito: a severidade
# --- e sempre explicita. Esse era o ponto fragil dos scripts originais.
_rec() { # <sev> <nome> <detalhe>
  local sev="$1" name="$2" det="${3:-}"
  RESULTS+=("${CUR_MOD}|${sev}|${name}|${det}")
  case "$sev" in
    OK)   N_OK=$((N_OK+1));   [[ $JSON -eq 0 && $QUIET -eq 0 ]] && printf '  %sOK%s   %-46s %s\n' "$C_G" "$C_0" "$name" "$det" ;;
    WARN) N_WARN=$((N_WARN+1)); [[ $JSON -eq 0 ]] && printf '  %sWARN%s %-46s %s\n' "$C_Y" "$C_0" "$name" "$det" ;;
    FAIL) N_FAIL=$((N_FAIL+1)); [[ $JSON -eq 0 ]] && printf '  %sFAIL%s %-46s %s\n' "$C_R" "$C_0" "$name" "$det" ;;
    SKIP) N_SKIP=$((N_SKIP+1)); [[ $JSON -eq 0 && $QUIET -eq 0 ]] && printf '  %s--%s   %-46s %s\n' "$C_B" "$C_0" "$name" "$det" ;;
  esac
  return 0
}
ok_()   { _rec OK   "$1" "${2:-}"; }
warn_() { _rec WARN "$1" "${2:-}"; }
fail_() { _rec FAIL "$1" "${2:-}"; }
skip_() { _rec SKIP "$1" "${2:-}"; }

# Helper: severidade a partir de um comando. Explicito, sem $? solto.
chk() { # <nome> <detalhe-ok> <detalhe-fail> <cmd...>
  local name="$1" dok="$2" dfail="$3"; shift 3
  if "$@" >/dev/null 2>&1; then ok_ "$name" "$dok"; return 0
  else fail_ "$name" "$dfail"; return 1; fi
}

hdr() { CUR_MOD="$1"; [[ $JSON -eq 0 ]] && { echo; echo "${C_B}== $1 ==${C_0}"; }; return 0; }
want() { [[ -z "$ONLY" ]] && return 0; [[ ",$ONLY," == *",$1,"* ]]; }

svc_active()  { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_exists()  { systemctl list-unit-files "$1.service" &>/dev/null; }
nofile_of()   { systemctl show "$1" -p LimitNOFILE --value 2>/dev/null; }

# Resolucao de verdade: dig retorna 0 mesmo com resposta VAZIA ou NXDOMAIN.
# Checar so o exit code (bug do script original) da falso positivo.
dig_has_answer() { # <servidor> <nome> <tipo>
  local out; out=$(dig "@$1" "$2" "${3:-A}" +short +time=3 +tries=1 2>/dev/null)
  [[ -n "$out" ]]
}
dig_status() { # <servidor> <nome> -> imprime NOERROR/SERVFAIL/...
  dig "@$1" "$2" +time=5 +tries=1 2>/dev/null | grep -oP 'status: \K[A-Z]+' | head -1
}

# =============================================================================
mod_core() {
  hdr core
  local codename kernel
  codename=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-?}")
  kernel=$(uname -r)
  ok_ "sistema" "Debian ${codename} / kernel ${kernel}"

  # disco
  local freemb pct
  freemb=$(df -Pm / | awk 'NR==2{print $4}')
  pct=$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
  if   [[ ${pct:-0} -ge 90 ]]; then fail_ "disco /" "${pct}% usado, ${freemb}MB livres"
  elif [[ ${pct:-0} -ge 80 ]]; then warn_ "disco /" "${pct}% usado, ${freemb}MB livres"
  else ok_ "disco /" "${pct}% usado, ${freemb}MB livres"; fi

  # memoria via MemAvailable (nao 'free', que engana com cache)
  local memtot memav pctav
  memtot=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  memav=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  pctav=$(( memav * 100 / memtot ))
  if   [[ $pctav -lt 10 ]]; then fail_ "memoria" "${pctav}% disponivel"
  elif [[ $pctav -lt 20 ]]; then warn_ "memoria" "${pctav}% disponivel"
  else ok_ "memoria" "${pctav}% disponivel de $((memtot/1024))MB"; fi

  # PSI: saturacao real, melhor sinal que media de uso
  if [[ -r /proc/pressure/io ]]; then
    local psi_io psi_mem
    psi_io=$(awk '/^some/{gsub(/avg60=/,"",$3); print $3}' /proc/pressure/io)
    psi_mem=$(awk '/^some/{gsub(/avg60=/,"",$3); print $3}' /proc/pressure/memory)
    awk -v v="$psi_io" 'BEGIN{exit !(v+0 > 20)}' && warn_ "PSI io" "avg60=${psi_io}% esperando I/O" \
      || ok_ "PSI io" "avg60=${psi_io}%"
    awk -v v="$psi_mem" 'BEGIN{exit !(v+0 > 10)}' && warn_ "PSI memoria" "avg60=${psi_mem}%" \
      || ok_ "PSI memoria" "avg60=${psi_mem}%"
  else skip_ "PSI" "kernel sem /proc/pressure"; fi

  # reboot pendente
  local newest
  newest=$(dpkg-query -W -f='${Package}\n' 'linux-image-*' 'proxmox-kernel-*-pve' 'pve-kernel-*-pve' 2>/dev/null \
           | grep -oP '\d+\.\d+\.\d+' | sort -V | tail -1)
  if [[ -n "$newest" && "$kernel" != *"$newest"* ]]; then
    warn_ "reboot" "kernel ${newest} instalado, rodando ${kernel}"
  else ok_ "reboot" "kernel em uso e o mais novo"; fi

  # colisao de sysctl entre arquivos (vence o nome lexicograficamente maior)
  local dup
  dup=$(grep -hoP '^\s*\K[a-z0-9_.]+(?=\s*=)' /etc/sysctl.d/*.conf /etc/sysctl.conf 2>/dev/null | sort | uniq -d)
  if [[ -n "$dup" ]]; then
    warn_ "sysctl colisao" "$(echo "$dup" | tr '\n' ' ')"
  else ok_ "sysctl colisao" "nenhuma chave duplicada"; fi

  # /etc/sysctl.conf ativo: no Debian 13 nao e mais lido
  if [[ "$codename" == "trixie" ]] && grep -qE '^[^#]' /etc/sysctl.conf 2>/dev/null; then
    fail_ "sysctl.conf" "tem conteudo ativo mas NAO e lido no Debian 13"
  fi
}

mod_tuning() {
  hdr tuning
  local prof=""
  [[ -f "${TUNE_STATE}/profile" ]] && prof=$(cat "${TUNE_STATE}/profile")
  if [[ -z "$prof" ]]; then
    warn_ "perfil" "nenhum perfil do tune-profile.sh aplicado"
    return 0
  fi
  ok_ "perfil" "$prof"

  # o arquivo do perfil ainda existe?
  local pf="/etc/sysctl.d/96-tune-profile-${prof}.conf"
  [[ -f "$pf" ]] && ok_ "arquivo do perfil" "$(basename "$pf")" \
                 || fail_ "arquivo do perfil" "$pf ausente (perfil removido a mao?)"

  # deriva efetiva: o que esta no arquivo bate com o kernel agora?
  local drift=0 line key val cur
  if [[ -f "$pf" ]]; then
    while IFS= read -r line; do
      [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
      key="${line%%=*}"; key="${key// }"; val="${line#*=}"; val="${val# }"
      [[ -e "/proc/sys/${key//.//}" ]] || continue
      cur=$(sysctl -n "$key" 2>/dev/null)
      # normaliza espacos (tcp_rmem e lista)
      [[ "$(tr -s ' ' <<<"$cur")" == "$(tr -s ' ' <<<"$val")" ]] || {
        drift=$((drift+1))
        [[ $drift -le 3 ]] && warn_ "deriva: ${key}" "arquivo=${val} efetivo=${cur}"
      }
    done < "$pf"
    [[ $drift -eq 0 ]] && ok_ "deriva de config" "kernel bate com o arquivo" \
                       || warn_ "deriva de config" "${drift} chave(s) divergentes"
  fi

  # tuning do host PVE (estado compartilhado do proxmox_tune.sh)
  if [[ -d "${STATE_ROOT}/tune" ]]; then
    # declaracao separada: `local f=$(...)` mascara o status do subshell (SC2155)
    local f
    f="${STATE_ROOT}/tune/state-$(uname -r).env"
    [[ -f "$f" ]] && ok_ "proxmox_tune" "aplicado neste kernel" \
                  || warn_ "proxmox_tune" "sem estado para o kernel atual — re-rode"
  fi
}

mod_bind() {
  hdr bind
  local svc=named
  svc_exists named || svc=bind9
  svc_exists "$svc" || { skip_ "bind" "nao instalado"; return 0; }

  svc_active "$svc" && ok_ "servico" "$svc ativo" || fail_ "servico" "$svc inativo"
  ss -lntu 2>/dev/null | grep -q ':53 ' && ok_ "porta 53" "escutando" || fail_ "porta 53" "nao escuta"
  chk "named-checkconf" "sintaxe valida" "sintaxe INVALIDA" named-checkconf

  dig_has_answer 127.0.0.1 google.com A && ok_ "resolucao" "google.com respondeu" \
                                        || fail_ "resolucao" "sem resposta"

  # DNSSEC: dominio quebrado de proposito. Resposta CERTA e SERVFAIL.
  local st; st=$(dig_status 127.0.0.1 dnssec-failed.org)
  [[ "$st" == "SERVFAIL" ]] && ok_ "DNSSEC" "dnssec-failed.org -> SERVFAIL" \
                            || fail_ "DNSSEC" "esperado SERVFAIL, veio ${st:-sem resposta}"

  # resolvedor aberto: so avisa se responder para origem nao autorizada
  grep -q 'allow-recursion' /etc/bind/named.conf.options 2>/dev/null \
    && ok_ "allow-recursion" "restricao presente" \
    || warn_ "allow-recursion" "sem restricao explicita — risco de resolvedor aberto"

  local nf; nf=$(nofile_of "$svc")
  [[ "${nf:-0}" =~ ^[0-9]+$ && ${nf:-0} -ge 16384 ]] && ok_ "LimitNOFILE" "$nf" \
    || warn_ "LimitNOFILE" "${nf:-nao definido} (recomendado >= 16384)"
}

mod_unbound() {
  hdr unbound
  svc_exists unbound || { skip_ "unbound" "nao instalado"; return 0; }

  svc_active unbound && ok_ "servico" "ativo" || fail_ "servico" "inativo"
  ss -lntu 2>/dev/null | grep -q ':53 ' && ok_ "porta 53" "escutando" || fail_ "porta 53" "nao escuta"
  chk "unbound-checkconf" "sintaxe valida" "sintaxe INVALIDA" unbound-checkconf

  # --- O CHECK QUE FALTAVA: trust anchor ---
  # Sobrescrever /etc/unbound/unbound.conf remove o include do conf.d/ e
  # com ele a auto-trust-anchor-file. O validator sobe SEM validar nada,
  # sem erro visivel — e toda comparacao de performance fica injusta.
  local ta; ta=$(unbound-checkconf -o auto-trust-anchor-file 2>/dev/null)
  if [[ -n "$ta" ]]; then
    if [[ -s "$ta" ]]; then ok_ "trust anchor" "$ta"
    else fail_ "trust anchor" "configurada mas o arquivo esta VAZIO: $ta"; fi
  else
    fail_ "trust anchor" "AUSENTE — validator sobe sem validar"
  fi

  dig_has_answer 127.0.0.1 google.com A && ok_ "resolucao" "google.com respondeu" \
                                        || fail_ "resolucao" "sem resposta"

  local st; st=$(dig_status 127.0.0.1 dnssec-failed.org)
  [[ "$st" == "SERVFAIL" ]] && ok_ "DNSSEC negativo" "dnssec-failed.org -> SERVFAIL" \
                            || fail_ "DNSSEC negativo" "esperado SERVFAIL, veio ${st:-sem resposta}"

  # positivo: dominio assinado valido tem que vir com flag AD
  if dig @127.0.0.1 iana.org A +dnssec +time=5 +tries=1 2>/dev/null | grep -q 'flags:.* ad'; then
    ok_ "DNSSEC positivo" "iana.org com flag AD"
  else
    warn_ "DNSSEC positivo" "sem flag AD em iana.org"
  fi

  # FD: outgoing-range x num-threads
  local orange nthreads need nf
  orange=$(unbound-checkconf -o outgoing-range 2>/dev/null || echo 4096)
  nthreads=$(unbound-checkconf -o num-threads 2>/dev/null || echo 1)
  need=$(( orange * nthreads ))
  nf=$(nofile_of unbound)
  if [[ "${nf:-0}" =~ ^[0-9]+$ ]] && [[ ${nf} -ge ${need} ]]; then
    ok_ "LimitNOFILE" "${nf} >= necessario ${need}"
  else
    fail_ "LimitNOFILE" "${nf:-nao definido} < necessario ${need} (${orange}x${nthreads})"
  fi

  # limits.conf nao vale para systemd — pegadinha comum
  grep -q '^unbound.*nofile' /etc/security/limits.conf 2>/dev/null && \
    warn_ "limits.conf" "entrada para unbound existe mas systemd NAO le"

  # resolvedor aberto
  unbound-checkconf -o access-control 2>/dev/null | grep -q '0.0.0.0/0 *allow' && \
    fail_ "access-control" "0.0.0.0/0 allow = RESOLVEDOR ABERTO" || \
    ok_ "access-control" "sem allow global"
}

mod_zabbix_proxy() {
  hdr zabbix-proxy
  svc_exists zabbix-proxy || { skip_ "zabbix-proxy" "nao instalado"; return 0; }
  svc_active zabbix-proxy && ok_ "servico" "ativo" || fail_ "servico" "inativo"

  local conf=/etc/zabbix/zabbix_proxy.conf
  if [[ -f "$conf" ]]; then
    local perm; perm=$(stat -c %a "$conf")
    [[ "$perm" == "640" || "$perm" == "600" ]] && ok_ "permissao do conf" "$perm" \
      || fail_ "permissao do conf" "$perm — contem DBPassword em texto claro"

    # ConfigFrequency foi depreciada no 6.4; no 7.0 e ProxyConfigFrequency
    grep -qE '^ConfigFrequency=' "$conf" && \
      warn_ "ConfigFrequency" "depreciada — use ProxyConfigFrequency no 7.0"
    grep -qE '^Server=127\.0\.0\.1' "$conf" && \
      warn_ "Server" "ainda aponta para 127.0.0.1"
  fi

  local nf; nf=$(nofile_of zabbix-proxy)
  [[ "${nf:-0}" =~ ^[0-9]+$ && ${nf:-0} -ge 16384 ]] && ok_ "LimitNOFILE" "$nf" \
    || warn_ "LimitNOFILE" "${nf:-nao definido} — 'Too many open files' vem daqui"

  # THP: PostgreSQL e MongoDB exigem never
  local thp; thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oP '\[\K[a-z]+')
  if svc_exists postgresql || svc_active postgresql; then
    [[ "$thp" == "never" ]] && ok_ "THP" "never (correto com PostgreSQL)" \
      || fail_ "THP" "${thp} — PostgreSQL exige never"
  fi

  # FDs em uso vs limite
  local pid; pid=$(systemctl show zabbix-proxy -p MainPID --value 2>/dev/null)
  if [[ "${pid:-0}" -gt 0 && -d "/proc/$pid/fd" ]]; then
    local used; used=$(ls "/proc/$pid/fd" 2>/dev/null | wc -l)
    ok_ "FDs em uso" "$used"
  fi
}

mod_docker() {
  hdr docker
  svc_exists docker || { skip_ "docker" "nao instalado"; return 0; }
  svc_active docker && ok_ "servico" "ativo" || fail_ "servico" "inativo"

  # rotacao de log: json-file sem limite enche o disco
  local dj=/etc/docker/daemon.json
  if [[ -f "$dj" ]] && grep -q 'max-size' "$dj"; then
    ok_ "rotacao de log" "max-size configurado"
  else
    fail_ "rotacao de log" "json-file SEM limite — enche o disco"
  fi

  # inotify: causa numero 1 de container que nao sobe
  local ii; ii=$(sysctl -n fs.inotify.max_user_instances 2>/dev/null)
  [[ ${ii:-0} -ge 1024 ]] && ok_ "inotify instances" "$ii" \
    || fail_ "inotify instances" "${ii} — containers falham com ENOSPC"

  # ip_forward: sem isso a bridge nao roteia
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] && ok_ "ip_forward" "1" \
    || fail_ "ip_forward" "0 — bridge do Docker nao roteia"

  # bridge-nf: iptables do Docker precisa ver trafego bridgeado
  if [[ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]]; then
    [[ "$(sysctl -n net.bridge.bridge-nf-call-iptables)" == "1" ]] && ok_ "bridge-nf" "1" \
      || warn_ "bridge-nf" "0 — regras do Docker podem nao aplicar"
  else warn_ "bridge-nf" "br_netfilter nao carregado"; fi

  if command -v docker >/dev/null 2>&1; then
    local imgs; imgs=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1)
    [[ -n "$imgs" ]] && ok_ "uso de imagens" "$imgs"
  fi
}

mod_pve() {
  hdr pve
  command -v pveversion >/dev/null 2>&1 || { skip_ "pve" "nao e host Proxmox"; return 0; }
  ok_ "versao" "$(pveversion | head -1 | grep -oP 'pve-manager/\K[^ /]+')"

  local s
  for s in pve-cluster pvedaemon pveproxy pvestatd; do
    svc_active "$s" && ok_ "servico ${s}" "ativo" || fail_ "servico ${s}" "inativo"
  done

  [[ -d /etc/pve/nodes ]] && ok_ "pmxcfs" "/etc/pve montado" || fail_ "pmxcfs" "/etc/pve vazio"

  local bad
  bad=$(pvesm status 2>/dev/null | awk 'NR>1 && $3!="active" && $3!="available" {print $1}' | tr '\n' ' ')
  [[ -z "${bad// /}" ]] && ok_ "storages" "todos ativos" || fail_ "storages" "inativos: $bad"

  if [[ -f /etc/pve/corosync.conf ]]; then
    pvecm status 2>/dev/null | grep -q 'Quorate:.*Yes' && ok_ "quorum" "OK" || fail_ "quorum" "SEM QUORUM"
  fi
}

# =============================================================================
emit_json() {
  printf '{"host":"%s","version":"%s","ts":"%s",' "$(hostname)" "$VERSION" "$(date -Is)"
  printf '"summary":{"ok":%d,"warn":%d,"fail":%d,"skip":%d},"checks":[' \
    "$N_OK" "$N_WARN" "$N_FAIL" "$N_SKIP"
  local first=1 r mod sev name det
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r mod sev name det <<<"$r"
    [[ $first -eq 0 ]] && printf ','
    first=0
    det=${det//\"/\\\"}
    printf '{"module":"%s","severity":"%s","name":"%s","detail":"%s"}' "$mod" "$sev" "$name" "$det"
  done
  printf ']}\n'
}

main() {
  if [[ $JSON -eq 0 ]]; then
    echo "${C_B}=========================================${C_0}"
    echo "  validate.sh v${VERSION} — $(hostname)"
    echo "${C_B}=========================================${C_0}"
  fi

  want core         && mod_core
  want tuning       && mod_tuning
  want bind         && mod_bind
  want unbound      && mod_unbound
  want zabbix-proxy && mod_zabbix_proxy
  want docker       && mod_docker
  want pve          && mod_pve

  if [[ $JSON -eq 1 ]]; then emit_json
  else
    echo
    echo "${C_B}=========================================${C_0}"
    printf '  %sOK %d%s  %sWARN %d%s  %sFAIL %d%s  (--%d)\n' \
      "$C_G" "$N_OK" "$C_0" "$C_Y" "$N_WARN" "$C_0" "$C_R" "$N_FAIL" "$C_0" "$N_SKIP"
    echo "${C_B}=========================================${C_0}"
  fi

  [[ $N_FAIL -gt 0 ]] && exit 2
  [[ $N_WARN -gt 0 ]] && exit 1
  exit 0
}

main "$@"
