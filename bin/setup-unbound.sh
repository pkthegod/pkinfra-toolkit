#!/usr/bin/env bash
# =============================================================================
# setup-unbound.sh — v2.0
# Unbound recursivo validante em Debian 12/13. Idempotente.
#
# CORRECOES SOBRE A v1 (as duas primeiras sao criticas):
#
#  [1] DNSSEC NAO VALIDAVA. A v1 fazia `cat > /etc/unbound/unbound.conf`,
#      apagando o `include-toplevel` que o pacote Debian usa para carregar
#      /etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf.
#      O modulo `validator` subia SEM ancora de confianca — sem erro visivel.
#      Agora escrevemos em conf.d/ e NAO tocamos no unbound.conf do pacote,
#      e o script TESTA a validacao no fim (dnssec-failed.org deve dar SERVFAIL).
#
#  [2] LIMITE DE FD ERRADO. `/etc/security/limits.conf` e do PAM; servico
#      systemd NAO le. E 4096 nem bastaria: outgoing-range x num-threads.
#      Agora vai em drop-in systemd, calculado do numero real de threads.
#
#  [3] sysctl com `>>` em /etc/sysctl.conf: nao idempotente (duplica a cada
#      execucao) e /etc/sysctl.conf deixou de ser lido no Debian 13/PVE 9.
#      Agora: arquivo proprio em /etc/sysctl.d/, reescrito, nunca somado.
#
#  [4] rmem_max=2GB contra tcp_mem=781MB: teto de UM socket maior que o teto
#      global de TCP. Valores coerentes agora, dimensionados pela RAM.
#
#  [5] num-threads fixo em 4 e slabs fixos: agora derivados de nproc, com
#      slabs = potencia de 2 mais proxima (exigencia do Unbound).
#
#  [6] resolv.conf: a v1 escrevia direto. Se for symlink do systemd-resolved,
#      isso corrompe. Agora detecta e avisa (igual ao seu script de BIND).
#
#  [7] RPZ com arquivo VAZIO: zona sem SOA faz o Unbound recusar carregar.
#      Agora o zonefile nasce com SOA valido.
#
#  [8] Faltavam qname-minimisation, harden-* e aggressive-nsec — privacidade
#      e resistencia a ataque, sem custo relevante.
#
#  [9] unbound-control nao estava habilitado: sem ele nao ha `unbound-control
#      stats`, que e como voce compara com o BIND de forma honesta.
#
# Uso:
#   ./setup-unbound.sh --dry-run
#   ./setup-unbound.sh --acl "138.36.117.0/24 45.236.20.0/22"
#   ./setup-unbound.sh --acl6 "2804:82ac::/32"
#   ./setup-unbound.sh --check          # so valida o que ja esta instalado
# =============================================================================
set -uo pipefail

VERSION="2.0"
CONF_D="/etc/unbound/unbound.conf.d"
CONF_MAIN="${CONF_D}/10-server.conf"
CONF_ACL="${CONF_D}/20-access.conf"
CONF_RPZ="${CONF_D}/30-rpz.conf"
CONF_ROOT="${CONF_D}/40-auth-zones.conf"
CONF_CTL="${CONF_D}/50-remote-control.conf"
RPZ_ZONE="/etc/unbound/rpz.block.hosts.zone"
SYSCTL_FILE="/etc/sysctl.d/96-unbound.conf"
DROPIN_DIR="/etc/systemd/system/unbound.service.d"
DROPIN="${DROPIN_DIR}/96-limits.conf"
LOGROTATE="/etc/logrotate.d/unbound-local"
LOG_DIR="/var/log/unbound"

DRY_RUN=0; CHECK_ONLY=0
ACL4=""; ACL6=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check)   CHECK_ONLY=1 ;;
    --acl)     shift; ACL4="${1:-}" ;;
    --acl6)    shift; ACL6="${1:-}" ;;
    -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
    *) echo "flag desconhecida: $1"; exit 2 ;;
  esac
  shift
done

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
[[ -t 1 ]] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; }
log()  { printf '%s\n' "$*"; }
info() { log "${C_B}::${C_0} $*"; }
ok()   { log "${C_G}OK${C_0} $*"; }
warn() { log "${C_Y}!!${C_0} $*"; }
err()  { log "${C_R}XX${C_0} $*"; }
head1(){ log ""; log "${C_B}==== $* ====${C_0}"; }
run()  { [[ $DRY_RUN -eq 1 ]] && { log "   ${C_Y}[dry]${C_0} $*"; return 0; }; "$@"; }

# Escrita idempotente: nao reescreve se o conteudo efetivo nao mudou
CHANGED=0
write_if_changed() {
  local dst="$1" tmp; tmp=$(mktemp); cat > "$tmp"
  if [[ -f "$dst" ]] && cmp -s <(grep -v '^# gerado-em' "$dst") <(grep -v '^# gerado-em' "$tmp"); then
    info "sem mudancas: $(basename "$dst")"; rm -f "$tmp"; return 0
  fi
  CHANGED=1
  if [[ $DRY_RUN -eq 1 ]]; then log "   ${C_Y}[dry]${C_0} escreveria ${dst}"; rm -f "$tmp"; return 0; fi
  [[ -f "$dst" ]] && cp -a "$dst" "${dst}.anterior"
  install -m 0644 "$tmp" "$dst"; rm -f "$tmp"
  ok "escrito: ${dst}"
}

# ---------------------------------------------------------------- fatos

RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
VCPU=$(nproc)

# Unbound exige slabs em POTENCIA DE 2. Usar o valor >= num-threads.
pow2_ge() { local n=1; while (( n < $1 )); do n=$(( n * 2 )); done; echo "$n"; }
THREADS=$VCPU
SLABS=$(pow2_ge "$THREADS")

# Cache: doc do Unbound pede rrset = 2x msg. Total ~1/3 da RAM.
CACHE_TOTAL=$(( RAM_MB / 3 ))
[[ $CACHE_TOTAL -lt 96 ]] && CACHE_TOTAL=96
MSG_CACHE=$(( CACHE_TOTAL / 3 ))
RRSET_CACHE=$(( MSG_CACHE * 2 ))

# outgoing-range por thread; o FD total sai daqui (era o bug [2])
OUT_RANGE=4096
[[ $RAM_MB -ge 8192 ]] && OUT_RANGE=8192
NOFILE=$(( OUT_RANGE * THREADS + 4096 ))
[[ $NOFILE -lt 16384 ]] && NOFILE=16384

detect_ip() {
  local ifc ip
  ifc=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
  [[ -n "$ifc" && "$ifc" != "lo" ]] && \
    ip=$(ip -4 -o addr show "$ifc" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [[ -z "$ip" ]] && ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  echo "$ip"
}
IP4=$(detect_ip)

# ---------------------------------------------------------------- checagem

do_check() {
  head1 "Diagnostico do Unbound"
  log "  versao      : $(unbound -V 2>/dev/null | head -1 || echo 'nao instalado')"
  log "  threads/RAM : ${VCPU} vCPU / ${RAM_MB} MB"
  log "  servico     : $(systemctl is-active unbound 2>/dev/null || echo '-')"
  log "  LimitNOFILE : $(systemctl show unbound -p LimitNOFILE --value 2>/dev/null || echo '-')"

  head1 "Trust anchor (o bug silencioso da v1)"
  local ta
  ta=$(unbound-checkconf -o auto-trust-anchor-file 2>/dev/null)
  if [[ -n "$ta" ]]; then
    ok "auto-trust-anchor-file = ${ta}"
    [[ -s "$ta" ]] && ok "arquivo existe e tem conteudo" || err "arquivo AUSENTE ou VAZIO"
  else
    err "SEM trust anchor configurada — o validator NAO valida nada"
    err "  DNSSEC desligado na pratica. Toda comparacao de performance"
    err "  contra BIND com dnssec-validation fica injusta."
  fi

  head1 "Teste real de validacao"
  if command -v dig >/dev/null; then
    # dominio quebrado de proposito: a resposta CERTA e SERVFAIL
    if dig @127.0.0.1 dnssec-failed.org A +time=5 +tries=1 2>/dev/null | grep -q SERVFAIL; then
      ok "dnssec-failed.org -> SERVFAIL (validacao ATIVA)"
    else
      err "dnssec-failed.org NAO deu SERVFAIL -> validacao INATIVA"
    fi
    # dominio bom: tem que responder com AD flag
    if dig @127.0.0.1 iana.org A +dnssec +time=5 +tries=1 2>/dev/null | grep -q 'flags:.* ad'; then
      ok "iana.org com flag AD (Authenticated Data)"
    else
      warn "sem flag AD em iana.org — verifique a validacao"
    fi
  fi

  head1 "Duplicatas em sysctl.conf (bug [3] da v1)"
  local dupes
  dupes=$(grep -oP '^\s*\K[a-z0-9_.]+(?=\s*=)' /etc/sysctl.conf 2>/dev/null | sort | uniq -d)
  if [[ -n "$dupes" ]]; then
    err "chaves DUPLICADAS em /etc/sysctl.conf (execucoes repetidas da v1):"
    echo "$dupes" | sed 's/^/     /'
    warn "no Debian 13 esse arquivo nem e mais lido — migre para /etc/sysctl.d/"
  else
    ok "sem duplicatas em /etc/sysctl.conf"
  fi
}

# ---------------------------------------------------------------- instalacao

install_packages() {
  head1 "Pacotes"
  local pkgs=(unbound unbound-anchor dns-root-data dnsutils dnstop
              nftables ethtool mtr-tiny tcpdump bmon)
  local faltando=()
  local p
  for p in "${pkgs[@]}"; do
    dpkg -l "$p" 2>/dev/null | grep -q '^ii' || faltando+=("$p")
  done
  if [[ ${#faltando[@]} -eq 0 ]]; then ok "todos os pacotes ja instalados"; return 0; fi
  info "instalando: ${faltando[*]}"
  run apt-get update -qq
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${faltando[@]}"
}

write_server_conf() {
  head1 "Config do servidor (${THREADS} threads, slabs ${SLABS})"
  info "cache: msg=${MSG_CACHE}m rrset=${RRSET_CACHE}m  outgoing-range=${OUT_RANGE}"

  local iface_line=""
  [[ -n "$IP4" ]] && iface_line="        interface: ${IP4}"

  write_if_changed "$CONF_MAIN" <<EOF
# ${CONF_MAIN}
# setup-unbound.sh v${VERSION}
# gerado-em: $(date -Is)  |  ${VCPU} vCPU / ${RAM_MB} MB
#
# NAO editamos /etc/unbound/unbound.conf: ele carrega este diretorio e a
# trust anchor do pacote. Sobrescrever aquele arquivo desliga o DNSSEC.
server:
        verbosity: 1
        extended-statistics: yes
        statistics-cumulative: no

        # Threads e slabs (slabs precisa ser potencia de 2)
        num-threads: ${THREADS}
        msg-cache-slabs: ${SLABS}
        rrset-cache-slabs: ${SLABS}
        infra-cache-slabs: ${SLABS}
        key-cache-slabs: ${SLABS}
        so-reuseport: yes

        interface: 127.0.0.1
        interface: ::1
${iface_line}
        interface-automatic: no

        do-ip4: yes
        do-ip6: yes
        do-udp: yes
        do-tcp: yes

        # Sockets de saida. FD total = outgoing-range x num-threads;
        # o drop-in do systemd dimensiona o LimitNOFILE a partir disso.
        outgoing-range: ${OUT_RANGE}
        num-queries-per-thread: $(( OUT_RANGE / 2 ))
        outgoing-num-tcp: 256
        incoming-num-tcp: 256
        so-rcvbuf: 8m
        so-sndbuf: 8m

        # 1232 evita fragmentacao de UDP (recomendacao DNS Flag Day 2020)
        edns-buffer-size: 1232

        # Cache. Doc do Unbound: rrset = 2x msg.
        msg-cache-size: ${MSG_CACHE}m
        rrset-cache-size: ${RRSET_CACHE}m
        key-cache-size: $(( MSG_CACHE / 4 ))m
        neg-cache-size: $(( MSG_CACHE / 4 ))m
        cache-min-ttl: 60
        cache-max-ttl: 86400
        cache-max-negative-ttl: 300
        infra-cache-numhosts: 100000

        # Responde do cache vencido enquanto revalida (equivale ao
        # stale-answer-enable do seu BIND)
        serve-expired: yes
        serve-expired-ttl: 86400
        serve-expired-client-timeout: 1800

        prefetch: yes
        prefetch-key: yes
        rrset-roundrobin: yes
        minimal-responses: yes
        aggressive-nsec: yes

        # Privacidade: manda so o rotulo necessario a cada servidor.
        # Faltava na v1 e nao custa performance relevante.
        qname-minimisation: yes
        qname-minimisation-strict: no

        # Endurecimento — tudo isso faltava na v1
        harden-glue: yes
        harden-dnssec-stripped: yes
        harden-below-nxdomain: yes
        harden-referral-path: yes
        harden-algo-downgrade: no
        use-caps-for-id: no
        deny-any: yes
        unwanted-reply-threshold: 10000000

        hide-identity: yes
        hide-version: yes
        identity: "DNS"

        # Limites por cliente (equivale a fetches-per-* do BIND)
        ratelimit: 1000
        ip-ratelimit: 500

        module-config: "respip validator iterator"
        val-clean-additional: yes
        val-log-level: 1

        username: "unbound"
        directory: "/etc/unbound"
        chroot: ""
        use-syslog: yes
        log-time-ascii: yes
        log-queries: no
        log-servfail: yes
EOF
}

write_acl_conf() {
  head1 "Listas de acesso"
  local body=""
  body+="        access-control: 0.0.0.0/0 refuse\n"
  body+="        access-control: ::0/0 refuse\n"
  body+="        access-control: 127.0.0.0/8 allow\n"
  body+="        access-control: ::1 allow\n"
  body+="        access-control: 10.0.0.0/8 allow\n"
  body+="        access-control: 172.16.0.0/12 allow\n"
  body+="        access-control: 192.168.0.0/16 allow\n"
  body+="        access-control: 100.64.0.0/10 allow\n"
  body+="        access-control: fc00::/7 allow\n"
  local p
  for p in $ACL4 $ACL6; do body+="        access-control: ${p} allow\n"; done

  if [[ -z "$ACL4$ACL6" ]]; then
    warn "nenhum prefixo proprio informado (--acl / --acl6)."
    warn "So RFC1918/CGNAT liberado. Clientes com IP publico seu serao RECUSADOS."
    warn "  ./setup-unbound.sh --acl \"138.36.117.0/24\" --acl6 \"2804:82ac::/32\""
  fi
  # a v1 tinha 2001:db8::/32 — prefixo de DOCUMENTACAO, nao serve para nada
  write_if_changed "$CONF_ACL" <<EOF
# ${CONF_ACL}
# gerado-em: $(date -Is)
# 'refuse' primeiro e liberacao explicita depois: resolvedor aberto e
# munição para amplificacao. Ordem importa: o mais especifico vence.
server:
$(printf "$body")
EOF
}

write_rpz_conf() {
  head1 "RPZ"
  # Zona VAZIA nao carrega: precisa de SOA. Era o bug [7].
  if [[ ! -s "$RPZ_ZONE" ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
      cat > "$RPZ_ZONE" <<EOF
\$TTL 60
@   IN  SOA localhost. root.localhost. ( $(date +%Y%m%d01) 3600 900 604800 60 )
    IN  NS  localhost.
; bloqueios, um por linha:
; exemplo.com          CNAME .
; *.exemplo.com        CNAME .
EOF
      chown unbound:unbound "$RPZ_ZONE" 2>/dev/null || true
      ok "zonefile RPZ criado com SOA valido"
    else
      log "   ${C_Y}[dry]${C_0} criaria ${RPZ_ZONE} com SOA"
    fi
  else
    info "zonefile RPZ ja existe — preservado"
  fi

  write_if_changed "$CONF_RPZ" <<EOF
# ${CONF_RPZ}
# gerado-em: $(date -Is)
rpz:
        name: rpz.local.
        zonefile: ${RPZ_ZONE}
        rpz-action-override: nxdomain
        rpz-log: yes
        rpz-log-name: "rpz.local"
EOF
}

write_root_zone_conf() {
  head1 "Zona raiz local (RFC 7706)"
  info "cache da raiz local: reduz latencia e vazamento de query para os root servers"
  write_if_changed "$CONF_ROOT" <<EOF
# ${CONF_ROOT}
# gerado-em: $(date -Is)
# RFC 7706: copia local da zona raiz. fallback-enabled garante que, se o
# AXFR falhar, o Unbound volta a consultar os root servers normalmente.
auth-zone:
        name: "."
        master: "b.root-servers.net"
        master: "c.root-servers.net"
        master: "d.root-servers.net"
        master: "f.root-servers.net"
        master: "g.root-servers.net"
        master: "k.root-servers.net"
        master: "lax.xfr.dns.icann.org"
        master: "iad.xfr.dns.icann.org"
        fallback-enabled: yes
        for-downstream: no
        for-upstream: yes
        zonefile: "/var/lib/unbound/root.zone"
EOF
}

write_control_conf() {
  head1 "unbound-control"
  # Sem isso nao ha 'unbound-control stats_noreset' — que e como voce
  # compara Unbound e BIND com numero, nao com sensacao.
  write_if_changed "$CONF_CTL" <<EOF
# ${CONF_CTL}
# gerado-em: $(date -Is)
remote-control:
        control-enable: yes
        control-interface: 127.0.0.1
        control-port: 8953
EOF
  if [[ $DRY_RUN -eq 0 ]] && [[ ! -f /etc/unbound/unbound_control.key ]]; then
    run unbound-control-setup >/dev/null 2>&1 && ok "chaves do unbound-control geradas"
  fi
}

write_limits() {
  head1 "LimitNOFILE (bug [2] da v1)"
  info "outgoing-range ${OUT_RANGE} x ${THREADS} threads + folga = ${NOFILE} FDs"
  warn "limits.conf e do PAM; servico systemd NAO le. Vai em drop-in."
  run mkdir -p "$DROPIN_DIR"
  write_if_changed "$DROPIN" <<EOF
# ${DROPIN}
# gerado-em: $(date -Is)
[Service]
LimitNOFILE=${NOFILE}
LimitNPROC=4096
Restart=on-failure
RestartSec=5s
EOF
  [[ $DRY_RUN -eq 0 && $CHANGED -eq 1 ]] && systemctl daemon-reload
  # remove a linha inutil que a v1 deixava para tras
  if grep -q '^unbound - nofile' /etc/security/limits.conf 2>/dev/null; then
    warn "removendo 'unbound - nofile' do limits.conf (nunca teve efeito)"
    run sed -i '/^unbound - nofile/d' /etc/security/limits.conf
  fi
}

write_sysctl() {
  head1 "Sysctl (arquivo proprio, nunca append em sysctl.conf)"
  # v1 fazia >> em /etc/sysctl.conf: duplicava a cada execucao, e no
  # Debian 13 aquele arquivo nem e mais lido.
  local rmem=33554432
  [[ $RAM_MB -ge 8192 ]] && rmem=67108864
  local udpmin=$(( 64 * 1024 * 1024 / 4096 ))
  local udpmax=$(( 256 * 1024 * 1024 / 4096 ))

  write_if_changed "$SYSCTL_FILE" <<EOF
# ${SYSCTL_FILE}
# setup-unbound.sh v${VERSION} — gerado-em: $(date -Is)
# Resolvedor recursivo: UDP domina, pacote pequeno, PPS alto.
# Buffer gigante NAO ajuda aqui (a v1 usava 2GB, incoerente com tcp_mem).

net.core.rmem_max = ${rmem}
net.core.wmem_max = ${rmem}
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.optmem_max = 131072
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
net.ipv4.udp_mem = ${udpmin} $(( udpmin * 2 )) ${udpmax}

# Fila de softirq: backlog cheio descarta o pacote ANTES do Unbound ver.
net.core.netdev_max_backlog = 65536
net.core.netdev_budget = 1200
net.core.netdev_budget_usecs = 12000

# Unbound randomiza porta de origem: faixa ampla = mais entropia.
net.ipv4.ip_local_port_range = 1024 65535

# TCP e minoria no DNS, mas precisa existir.
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

vm.swappiness = 10
vm.dirty_bytes = 134217728
vm.dirty_background_bytes = 33554432

fs.file-max = 2097152
fs.nr_open = 2097152
EOF

  [[ $DRY_RUN -eq 1 ]] && return 0
  local applied=0 skipped=0 line key val
  while IFS= read -r line; do
    [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"; key="${key// }"; val="${line#*=}"; val="${val# }"
    if [[ -e "/proc/sys/${key//.//}" ]] && sysctl -w "${key}=${val}" >/dev/null 2>&1; then
      applied=$((applied+1))
    else warn "pulada: ${key}"; skipped=$((skipped+1)); fi
  done < "$SYSCTL_FILE"
  ok "sysctl: ${applied} aplicadas, ${skipped} puladas"
}

write_logrotate() {
  [[ -d "$LOG_DIR" ]] || run install -d -o unbound -g unbound -m 0750 "$LOG_DIR"
  write_if_changed "$LOGROTATE" <<EOF
# gerado-em: $(date -Is)
${LOG_DIR}/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0640 unbound unbound
    postrotate
        /usr/sbin/unbound-control log_reopen >/dev/null 2>&1 || true
    endscript
}
EOF
}

fix_resolv() {
  head1 "resolv.conf"
  if [[ -L /etc/resolv.conf ]]; then
    warn "/etc/resolv.conf e symlink (systemd-resolved/resolvconf)."
    warn "Escrever nele corrompe o estado do gerenciador. Ajuste manual:"
    warn "  systemctl disable --now systemd-resolved"
    warn "  rm /etc/resolv.conf && printf 'nameserver 127.0.0.1\\nnameserver ::1\\n' > /etc/resolv.conf"
    return 0
  fi
  if grep -q '^nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null; then
    ok "ja aponta para 127.0.0.1"; return 0
  fi
  [[ $DRY_RUN -eq 1 ]] && { log "   ${C_Y}[dry]${C_0} apontaria resolv.conf para 127.0.0.1"; return 0; }
  cp -a /etc/resolv.conf /etc/resolv.conf.anterior 2>/dev/null || true
  printf 'nameserver 127.0.0.1\nnameserver ::1\n' > /etc/resolv.conf
  ok "resolv.conf apontando para o proprio resolvedor"
}

validate_and_restart() {
  head1 "Validacao e restart"
  if [[ $DRY_RUN -eq 1 ]]; then info "[dry] unbound-checkconf + restart"; return 0; fi
  if ! unbound-checkconf >/dev/null 2>&1; then
    err "unbound-checkconf FALHOU:"; unbound-checkconf 2>&1 | sed 's/^/     /'
    err "nada foi reiniciado — corrija antes"
    return 1
  fi
  ok "unbound-checkconf passou"
  run systemctl enable unbound >/dev/null 2>&1
  run systemctl restart unbound
  sleep 2
  systemctl is-active --quiet unbound && ok "unbound ativo" || {
    err "unbound NAO subiu — journalctl -u unbound -e"; return 1; }
}

# ---------------------------------------------------------------- main

main() {
  [[ $EUID -eq 0 ]] || { err "execute como root"; exit 1; }
  head1 "setup-unbound v${VERSION} $([[ $DRY_RUN -eq 1 ]] && echo '(DRY-RUN)')"
  log "  ${VCPU} vCPU / ${RAM_MB} MB  |  IP detectado: ${IP4:-nenhum}"

  if [[ $CHECK_ONLY -eq 1 ]]; then do_check; exit 0; fi

  install_packages
  write_server_conf
  write_acl_conf
  write_rpz_conf
  write_root_zone_conf
  write_control_conf
  write_limits
  write_sysctl
  write_logrotate
  fix_resolv
  validate_and_restart || exit 1

  do_check

  head1 "Concluido"
  info "estatisticas: unbound-control stats_noreset | grep -E 'total|cache'"
  info "comparar com BIND: rndc stats  vs  unbound-control stats"
  warn "se aparecer 'SEM trust anchor' acima, o DNSSEC nao esta validando"
}

main "$@"
