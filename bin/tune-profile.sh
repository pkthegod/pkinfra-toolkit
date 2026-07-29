#!/usr/bin/env bash
# =============================================================================
# tune-profile.sh — v1.0
# Tuning de host Debian 12/13 POR PERFIL DE CARGA.
#
# A premissa: nao existe "tuning bom". Existe tuning certo para uma carga.
# Um resolvedor DNS (UDP, pacote minusculo, PPS altissimo) e um medidor de
# velocidade (TCP, fluxo gigante, poucas conexoes) querem coisas OPOSTAS.
# Aplicar o mesmo sysctl nos dois piora os dois.
#
# PERFIS
#   dns       BIND/Unbound recursivo — UDP, PPS alto, pacote pequeno
#   proxy     Zabbix Proxy + PostgreSQL — banco, fsync, milhares de conexoes curtas
#   medidor   OoklaServer/iperf — TCP, throughput maximo, poucos fluxos enormes
#   acs       GenieACS/TR-069 + MongoDB — HTTP curto em massa, Node.js
#   generico  VPS de servico simples — conservador, sem aposta
#
# EXCLUSIVIDADE: aplicar um perfil REMOVE os outros. Perfis nao empilham —
# empilhar e como se contradizem em silencio.
#
# Uso:
#   ./tune-profile.sh --list
#   ./tune-profile.sh --detect                     sugere o perfil
#   ./tune-profile.sh --profile dns --dry-run
#   ./tune-profile.sh --profile proxy
#   ./tune-profile.sh --status
# =============================================================================
set -uo pipefail

VERSION="1.0"
SYSCTL_DIR="/etc/sysctl.d"
PREFIX="96-tune-profile"
STATE_DIR="/var/lib/tune-profile"
LOG_FILE="/var/log/tune-profile.log"
THP_UNIT="/etc/systemd/system/tune-profile-thp.service"

PROFILE=""; DRY_RUN=0; MODE="apply"; FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) shift; PROFILE="${1:-}" ;;
    --dry-run) DRY_RUN=1 ;;
    --list)    MODE="list" ;;
    --detect)  MODE="detect" ;;
    --status)  MODE="status" ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "flag desconhecida: $1"; exit 2 ;;
  esac
  shift
done

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
[[ -t 1 ]] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; }
log()  { printf '%s\n' "$*" | tee -a "$LOG_FILE" 2>/dev/null || printf '%s\n' "$*"; }
info() { log "${C_B}::${C_0} $*"; }
ok()   { log "${C_G}OK${C_0} $*"; }
warn() { log "${C_Y}!!${C_0} $*"; }
err()  { log "${C_R}XX${C_0} $*"; }
head1(){ log ""; log "${C_B}==== $* ====${C_0}"; }
run()  { [[ $DRY_RUN -eq 1 ]] && { log "   ${C_Y}[dry]${C_0} $*"; return 0; }; "$@"; }

RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
VCPU=$(nproc)
PAGE=$(getconf PAGE_SIZE)
VIRT=$(systemd-detect-virt 2>/dev/null || echo none)

# udp_mem/tcp_mem sao em PAGINAS. Calcular em bytes e converter evita o
# erro classico de escrever bytes numa chave que espera paginas.
pages_from_mb() { echo $(( $1 * 1024 * 1024 / PAGE )); }

# =============================================================================
# PERFIS — cada funcao emite o corpo do sysctl no stdout
# =============================================================================

profile_desc() {
  case "$1" in
    dns)      echo "BIND/Unbound recursivo — UDP, PPS alto, pacote pequeno" ;;
    proxy)    echo "Zabbix Proxy + PostgreSQL — banco, fsync, conexoes curtas" ;;
    medidor)  echo "OoklaServer/iperf — TCP, throughput maximo" ;;
    acs)      echo "GenieACS/TR-069 + MongoDB — HTTP curto em massa" ;;
    dns-unbound) echo "Unbound recursivo — threaded, so-reuseport, UDP alto" ;;
    docker)     echo "Docker em VM Debian 13 — bridge, inotify, muitos containers" ;;
    lxc-docker) echo "Docker dentro de LXC — so chaves namespaced (resto vai no host)" ;;
    generico)   echo "VPS de servico simples — conservador" ;;
    *)        echo "?" ;;
  esac
}

# ---------------------------------------------------------------- DNS
sysctl_dns() {
  # UDP domina. O gargalo nao e banda, e PACOTES POR SEGUNDO e fila de
  # softirq. Buffers grandes de TCP nao ajudam nada aqui.
  local udp_min udp_pressure udp_max
  udp_min=$(pages_from_mb 64); udp_pressure=$(pages_from_mb 128); udp_max=$(pages_from_mb 256)
cat <<EOF
# -- Recepcao UDP: buffer por socket. BIND abre muitos sockets de query.
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
net.ipv4.udp_mem = ${udp_min} ${udp_pressure} ${udp_max}

# -- Fila de softirq: o que realmente derruba resolvedor sob carga.
# backlog cheio = pacote descartado ANTES de chegar no BIND.
net.core.netdev_max_backlog = 65536
net.core.netdev_budget = 1200
net.core.netdev_budget_usecs = 12000

# -- Portas de origem: BIND randomiza a porta de cada query (anti-spoof).
# Faixa estreita reduz a entropia e limita queries simultaneas.
net.ipv4.ip_local_port_range = 1024 65535

# -- TCP e minoria (AXFR, respostas grandes), mas precisa existir.
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 15

# -- Conntrack: DNS UDP ENCHE a tabela. Se usar firewall stateful na 53,
# suba o teto. O ideal e 'notrack' para a porta 53 (ver notas do script).
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_udp_timeout = 15
net.netfilter.nf_conntrack_udp_timeout_stream = 60

# -- Memoria: resolvedor tem cache grande em RAM; nao deixar ir pra swap.
vm.swappiness = 10
vm.dirty_bytes = 134217728
vm.dirty_background_bytes = 33554432

# -- Descritores: 'recursive-clients 10000' precisa de FD para cada um.
fs.file-max = 2097152
fs.nr_open = 2097152
EOF
}

# ---------------------------------------------------------------- PROXY
sysctl_proxy() {
  # Zabbix Proxy + PostgreSQL: carga de BANCO. fsync manda.
cat <<EOF
# -- Writeback pequeno e continuo. Percentual escala errado: 20% de 16GB
# sao 3,2GB sujos, e o fsync do postgres espera esse flush inteiro.
vm.dirty_bytes = 268435456
vm.dirty_background_bytes = 67108864
# expira paginas sujas mais cedo (centesimos de segundo)
vm.dirty_expire_centisecs = 500
vm.dirty_writeback_centisecs = 100

# -- 1 e agressivo demais com balloon do PVE ativo: o host recolhe RAM e
# o OOM killer escolhe o postgres ou o proxy.
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# -- PostgreSQL >= 9.3 usa mmap; overcommit heuristico e o certo.
vm.overcommit_memory = 0

# -- Milhares de conexoes CURTAS vindas dos agentes.
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535

# -- Buffers MODERADOS: conexao de agente e curta e pequena. 64MB por
# socket nao acelera e so aumenta o pico de memoria.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# -- VM de servico nao e roteador.
net.ipv4.ip_forward = 0

fs.file-max = 2097152
fs.nr_open = 2097152
fs.aio-max-nr = 1048576
EOF
}

# ---------------------------------------------------------------- MEDIDOR
sysctl_medidor() {
  # Oposto do DNS: poucos fluxos, cada um querendo saturar o link.
  # Buffer PEQUENO aqui e o gargalo — o BDP de 1Gbps x 100ms ja e 12MB.
  local tcp_min tcp_pressure tcp_max
  tcp_min=$(pages_from_mb 128); tcp_pressure=$(pages_from_mb 256); tcp_max=$(pages_from_mb 512)
cat <<EOF
# -- Buffers GRANDES: sem isso a janela TCP limita a medicao e o cliente
# ve menos banda do que o link entrega. BDP 1Gbps x 100ms = ~12MB.
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.tcp_rmem = 4096 262144 268435456
net.ipv4.tcp_wmem = 4096 262144 268435456
net.ipv4.tcp_mem = ${tcp_min} ${tcp_pressure} ${tcp_max}

# -- Autotuning e pacing: fq e obrigatorio para BBR funcionar direito.
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1

# -- Nao reduzir a janela em fluxo ocioso: mede errado o inicio do teste.
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072

# -- maxConnPerIp=50 x muitos clientes = muitas conexoes simultaneas.
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535
net.core.netdev_max_backlog = 32768

# -- MTU probing ajuda em cliente atras de PPPoE/tunel.
net.ipv4.tcp_mtu_probing = 1

vm.swappiness = 10
fs.file-max = 2097152
fs.nr_open = 2097152
EOF
}

# ---------------------------------------------------------------- ACS
sysctl_acs() {
  # GenieACS: milhares de CPEs abrindo sessao CWMP (HTTP) periodicamente.
  # Padrao: conexao curta, muita, com pico no boot de OLT.
cat <<EOF
# -- Esgotamento de porta efemera e o modo classico de morrer aqui.
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_tw_buckets = 2000000

# -- Pico de inform simultaneo (queda de energia em bairro inteiro).
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0
net.core.netdev_max_backlog = 32768

# -- Buffers moderados: payload CWMP e XML pequeno/medio.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# -- MongoDB: writeback continuo e swap quase zero (mas nao zero).
vm.dirty_bytes = 268435456
vm.dirty_background_bytes = 67108864
vm.swappiness = 5
vm.vfs_cache_pressure = 50
vm.max_map_count = 262144

# -- Conntrack: muitas sessoes curtas de CPE.
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

fs.file-max = 2097152
fs.nr_open = 2097152
EOF
}

# ---------------------------------------------------------------- DNS-UNBOUND
sysctl_dns_unbound() {
  # Difere do perfil 'dns' (BIND) em dois pontos concretos:
  #  1. Unbound e THREADED com so-reuseport: o kernel distribui os pacotes
  #     entre as threads. Isso exige backlog e budget de softirq maiores.
  #  2. outgoing-range x num-threads sockets UDP simultaneos: a faixa de
  #     porta efemera precisa ser ampla ou ele nao abre os sockets.
  local udpmin udpmax
  udpmin=$(pages_from_mb 64); udpmax=$(pages_from_mb 256)
cat <<EOF
# -- UDP: buffer por socket. Unbound abre milhares deles simultaneamente.
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.optmem_max = 131072
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
net.ipv4.udp_mem = ${udpmin} $(( udpmin * 2 )) ${udpmax}

# -- so-reuseport distribui no kernel entre as threads: a fila de softirq
# vira o gargalo antes da CPU. Mais alto que no perfil 'dns' de proposito.
net.core.netdev_max_backlog = 65536
net.core.netdev_budget = 1500
net.core.netdev_budget_usecs = 15000

# -- Faixa AMPLA: cada query recursiva sai de uma porta aleatoria
# (anti-spoofing). outgoing-range x threads pode passar de 30 mil sockets.
net.ipv4.ip_local_port_range = 1024 65535

# -- TCP e minoria no DNS (TC=1, AXFR), mas nao pode faltar.
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# -- Conntrack: DNS UDP enche a tabela. O ideal e notrack na porta 53.
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_udp_timeout = 15
net.netfilter.nf_conntrack_udp_timeout_stream = 60

# -- Cache do Unbound e memoria anonima: nao pode ir para swap.
vm.swappiness = 10
vm.dirty_bytes = 134217728
vm.dirty_background_bytes = 33554432

fs.file-max = 2097152
fs.nr_open = 2097152
EOF
}

# ---------------------------------------------------------------- DOCKER
sysctl_docker() {
  # Alvo: VM Debian 13, ~4 vCPU, 4-8GB RAM, 32GB disco.
  # ATENCAO: ip_forward=1 aqui e OBRIGATORIO (bridge do Docker roteia).
  # E o oposto do perfil 'proxy', onde ele e desligado de proposito.
  local pidmax=131072
  [[ $RAM_MB -lt 6144 ]] && pidmax=65536
cat <<EOF
# -- Rede do Docker: sem isso a bridge nao roteia e container nao sai.
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1

# -- Regras iptables do Docker precisam ver trafego bridgeado.
# Exige br_netfilter carregado (o script carrega).
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-arptables = 0

# -- inotify: A causa numero 1 de "container nao sobe" no Debian.
# Default max_user_instances=128 acaba com ~10 containers que observam
# arquivos. O erro aparece como ENOSPC, que ninguem associa a inotify.
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576

# -- max_map_count: Elasticsearch/OpenSearch/Solr recusam iniciar abaixo
# de 262144. Vale a pena ja deixar pronto.
vm.max_map_count = 262144

# -- PIDs: cada container soma processos. Default 32768 e apertado.
kernel.pid_max = ${pidmax}
kernel.threads-max = ${pidmax}

# -- Conntrack: bridge + NAT do Docker cria entrada por conexao.
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# -- Muitas conexoes de curta duracao entre containers e para fora.
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535
net.core.netdev_max_backlog = 16384

# -- Buffers moderados: trafego de container e maioria interno/curto.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# -- Memoria em VM de 4-8GB: nao pode ficar sem valvula.
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 0
vm.dirty_bytes = 134217728
vm.dirty_background_bytes = 33554432

# -- Descritores: overlay2 + muitos containers consomem FD rapido.
fs.file-max = 2097152
fs.nr_open = 2097152
fs.aio-max-nr = 1048576

# -- Keyrings: containers usam; default estoura com dezenas deles.
kernel.keys.maxkeys = 20000
kernel.keys.maxbytes = 2000000
EOF
}

# ---------------------------------------------------------------- LXC+DOCKER
sysctl_lxc_docker() {
  # Dentro de LXC so as chaves de NETWORK NAMESPACE valem. As de vm.*,
  # fs.inotify.* e kernel.* sao GLOBAIS: pertencem ao host PVE.
  # Este perfil emite so o que funciona aqui; o resto vira instrucao
  # para rodar no host (ver profile_notes).
cat <<EOF
# -- Namespaced (funcionam dentro do container) --------------------
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1

net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
}

# ---------------------------------------------------------------- GENERICO
sysctl_generico() {
  # Sem aposta. Corrige apenas o que o default do Debian deixa apertado
  # demais para qualquer servico, sem otimizar para carga nenhuma.
  local rmem=$(( RAM_MB * 4 * 1024 ))
  [[ $rmem -lt 8388608 ]]  && rmem=8388608
  [[ $rmem -gt 33554432 ]] && rmem=33554432
cat <<EOF
# -- Conservador: dobra o que e notoriamente baixo, nao aposta em carga.
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 16384
net.core.rmem_max = ${rmem}
net.core.wmem_max = ${rmem}

net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 10240 65535

vm.swappiness = 10
vm.dirty_bytes = 268435456
vm.dirty_background_bytes = 67108864
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 0

net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0

fs.file-max = 1048576
fs.nr_open = 1048576
EOF
}

# =============================================================================
# THP e LIMITES por perfil
# =============================================================================

thp_for() {
  case "$1" in
    proxy|acs) echo never ;;      # PostgreSQL e MongoDB exigem
    docker|lxc-docker) echo madvise ;;  # depende do que roda dentro
    dns)       echo madvise ;;    # cache do BIND se beneficia sob demanda
    medidor)   echo madvise ;;
    *)         echo madvise ;;
  esac
}

# servico:LimitNOFILE por perfil
limits_for() {
  case "$1" in
    dns)         echo "named:65536 bind9:65536" ;;
    dns-unbound) echo "unbound:65536" ;;
    proxy)   echo "zabbix-proxy:65536 postgresql:65536 zabbix-agent:16384" ;;
    medidor) echo "ooklaserver:131072 speedtest:131072" ;;
    docker)  echo "docker:1048576 containerd:1048576" ;;
    lxc-docker) echo "docker:1048576 containerd:1048576" ;;
    acs)     echo "genieacs-cwmp:131072 genieacs-nbi:32768 genieacs-fs:16384 genieacs-ui:16384 mongod:65536" ;;
    *)       echo "" ;;
  esac
}

# Rodando dentro de LXC? (afeta quais chaves valem)
in_lxc() {
  [[ "$(systemd-detect-virt --container 2>/dev/null)" == "lxc" ]] && return 0
  grep -qa 'container=lxc' /proc/1/environ 2>/dev/null && return 0
  return 1
}

# Modulos exigidos por perfil, carregados ANTES do sysctl que depende deles
load_modules_for() {
  local p="$1" mods="" m
  case "$p" in
    docker)          mods="br_netfilter nf_conntrack overlay" ;;
    dns|dns-unbound|acs|proxy) mods="nf_conntrack" ;;
  esac
  [[ -z "$mods" ]] && return 0
  for m in $mods; do
    lsmod 2>/dev/null | grep -q "^${m} " && continue
    if run modprobe "$m" 2>/dev/null; then
      ok "modulo carregado: ${m}"
      [[ $DRY_RUN -eq 0 ]] && grep -qxF "$m" /etc/modules-load.d/96-tune-profile.conf 2>/dev/null \
        || { [[ $DRY_RUN -eq 0 ]] && echo "$m" >> /etc/modules-load.d/96-tune-profile.conf; }
    else
      warn "modulo indisponivel: ${m} — chaves dependentes serao puladas"
    fi
  done
}

# Disco pequeno + Docker = disco cheio. Log sem rotacao e a causa numero 1.
docker_daemon_json() {
  local dj=/etc/docker/daemon.json
  head1 "Docker daemon.json (rotacao de log e storage)"
  local freegb; freegb=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
  info "espaco livre em /: ${freegb:-?} GB"
  [[ ${freegb:-99} -lt 15 ]] && warn "disco apertado — rotacao de log deixa de ser opcional"

  if [[ -f "$dj" ]] && [[ -s "$dj" ]]; then
    if grep -q 'max-size' "$dj" 2>/dev/null; then
      ok "daemon.json ja tem rotacao de log configurada"
    else
      err "daemon.json EXISTE mas SEM 'max-size' — log json-file cresce sem limite"
      warn "adicione manualmente (nao sobrescrevo config sua):"
      warn '  "log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}'
    fi
    return 0
  fi

  local drv="overlay2"
  in_lxc && drv="fuse-overlayfs"
  if [[ $DRY_RUN -eq 1 ]]; then
    log "   ${C_Y}[dry]${C_0} criaria ${dj} (storage-driver=${drv})"; return 0
  fi
  mkdir -p /etc/docker
  cat > "$dj" <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "storage-driver": "${drv}",
  "live-restore": true,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 65536 }
  }
}
EOF
  ok "criado ${dj} (rotacao 10m x3, storage=${drv})"
  warn "aplica no proximo 'systemctl restart docker'"
  [[ "$drv" == "overlay2" ]] && \
    info "com 32GB de disco: rode 'docker system prune -af --volumes' periodicamente"
}

# =============================================================================
# MOTOR
# =============================================================================

active_profile() {
  local f
  f=$(ls "${SYSCTL_DIR}/${PREFIX}-"*.conf 2>/dev/null | head -1)
  [[ -z "$f" ]] && { echo ""; return; }
  basename "$f" | sed -E "s/^${PREFIX}-(.*)\.conf$/\1/"
}

remove_other_profiles() {
  local keep="$1" f name
  for f in "${SYSCTL_DIR}/${PREFIX}-"*.conf; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" | sed -E "s/^${PREFIX}-(.*)\.conf$/\1/")
    [[ "$name" == "$keep" ]] && continue
    warn "removendo perfil anterior: ${name} (perfis nao empilham)"
    run rm -f "$f"
  done
}

apply_sysctl_tolerant() {
  local file="$1" applied=0 skipped=0 line key val
  while IFS= read -r line; do
    [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"; key="${key// }"; val="${line#*=}"; val="${val# }"
    if [[ ! -e "/proc/sys/${key//.//}" ]]; then
      warn "inexistente neste kernel: ${key}"; skipped=$((skipped+1)); continue
    fi
    if [[ $DRY_RUN -eq 1 ]]; then applied=$((applied+1)); continue; fi
    if sysctl -w "${key}=${val}" >/dev/null 2>&1; then
      applied=$((applied+1))
    else
      warn "rejeitada pelo kernel: ${key} = ${val}"; skipped=$((skipped+1))
    fi
  done < "$file"
  ok "sysctl: ${applied} aplicadas, ${skipped} puladas"
}

apply_thp() {
  local mode="$1"
  [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]] || return 0
  info "THP = ${mode}"
  if [[ $DRY_RUN -eq 0 ]]; then
    echo "$mode" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    [[ "$mode" == "never" ]] && \
      echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
  fi
  local tmp; tmp=$(mktemp)
  cat > "$tmp" <<EOF
[Unit]
Description=tune-profile: THP ${mode}
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo ${mode} > /sys/kernel/mm/transparent_hugepage/enabled || true'
[Install]
WantedBy=multi-user.target
EOF
  if [[ $DRY_RUN -eq 1 ]]; then rm -f "$tmp"; return 0; fi
  if [[ -f "$THP_UNIT" ]] && cmp -s "$THP_UNIT" "$tmp"; then rm -f "$tmp"; return 0; fi
  install -m 0644 "$tmp" "$THP_UNIT"; rm -f "$tmp"
  systemctl daemon-reload
  systemctl enable --now tune-profile-thp.service >/dev/null 2>&1 || true
  ok "THP persistido via ${THP_UNIT}"
}

apply_limits() {
  local spec="$1" entry svc lim d
  [[ -z "$spec" ]] && return 0
  head1 "LimitNOFILE por servico"
  info "fs.file-max e limite do SISTEMA; o que derruba o processo vem daqui"
  for entry in $spec; do
    svc="${entry%%:*}"; lim="${entry##*:}"
    if ! systemctl list-unit-files "${svc}.service" &>/dev/null; then
      log "   - ${svc}: nao instalado, pulando"
      continue
    fi
    d="/etc/systemd/system/${svc}.service.d"
    run mkdir -p "$d"
    if [[ $DRY_RUN -eq 1 ]]; then
      log "   ${C_Y}[dry]${C_0} ${d}/96-limits.conf  LimitNOFILE=${lim}"
      continue
    fi
    cat > "${d}/96-limits.conf" <<EOF
# tune-profile.sh v${VERSION} — perfil ${PROFILE}
[Service]
LimitNOFILE=${lim}
LimitNPROC=8192
EOF
    ok "${svc}: LimitNOFILE=${lim}  (vale no proximo restart)"
  done
  [[ $DRY_RUN -eq 0 ]] && systemctl daemon-reload
}

profile_notes() {
  head1 "Notas do perfil '${1}'"
  case "$1" in
    dns)
      warn "Firewall stateful na porta 53 enche o conntrack. No nftables, prefira:"
      warn "  table inet raw { chain pre { type filter hook prerouting priority -300;"
      warn "    udp dport 53 notrack; udp sport 53 notrack; } }"
      warn "Ative RPS se a NIC tiver fila unica (VM virtio costuma ter):"
      warn "  echo <mascara_cpus> > /sys/class/net/<if>/queues/rx-0/rps_cpus"
      info "Monitore: dnstop, rndc stats, e drops em /proc/net/softnet_stat"
      ;;
    proxy)
      warn "PostgreSQL: ajuste tambem o postgresql.conf —"
      warn "  shared_buffers = $(( RAM_MB / 4 ))MB    (25% da RAM)"
      warn "  effective_cache_size = $(( RAM_MB * 3 / 4 ))MB"
      warn "  work_mem = 16MB   maintenance_work_mem = $(( RAM_MB / 16 ))MB"
      warn "  checkpoint_completion_target = 0.9   wal_compression = on"
      warn "Zabbix 7.0: ConfigFrequency foi DEPRECIADO. Use ProxyConfigFrequency."
      warn "Proteja a senha:  chmod 640 /etc/zabbix/zabbix_proxy.conf"
      warn "                  chown root:zabbix /etc/zabbix/zabbix_proxy.conf"
      info "Sizing: StartPollers=$(( VCPU * 4 ))  StartTrappers=$(( VCPU * 2 ))  CacheSize=$(( RAM_MB / 16 ))M"
      ;;
    medidor)
      warn "NAO aplique TC/QoS nesta maquina: shaping limita a propria medicao."
      warn "OoklaServer.workerThreadPool.capacity=30000 exige LimitNOFILE alto (feito)."
      info "BBR entrega numero maior; cubic representa melhor o cliente tipico."
      info "Escolha consciente — o resultado do teste muda conforme o CC."
      ;;
    acs)
      warn "MongoDB exige THP=never (aplicado) e readahead baixo no volume de dados:"
      warn "  blockdev --setra 32 /dev/<dev-do-mongo>"
      warn "Node.js: exporte UV_THREADPOOL_SIZE=$(( VCPU * 4 )) no drop-in do genieacs-cwmp."
      info "Pico real e queda de energia: todos os CPEs mandam inform juntos."
      info "Dimensione o backlog para o pico, nao para a media."
      ;;
    dns-unbound)
      warn "Firewall stateful na 53 enche o conntrack. No nftables:"
      warn "  table inet raw { chain pre { type filter hook prerouting priority -300;"
      warn "    udp dport 53 notrack; udp sport 53 notrack; } }"
      log  ""
      warn "LimitNOFILE precisa cobrir outgoing-range x num-threads."
      warn "  /etc/security/limits.conf NAO vale para servico systemd."
      log  ""
      err  "VERIFIQUE A TRUST ANCHOR antes de comparar com o BIND:"
      err  "  unbound-checkconf -o auto-trust-anchor-file"
      err  "  dig @127.0.0.1 dnssec-failed.org A | grep SERVFAIL"
      err  "Sem ancora, o validator sobe sem validar nada e o Unbound"
      err  "aparece mais rapido so porque esta fazendo menos trabalho."
      log  ""
      info "Comparacao honesta: unbound-control stats_noreset  vs  rndc stats"
      info "Olhe cache hit ratio, nao latencia media."
      ;;
    docker)
      warn "ip_forward=1 aqui e OBRIGATORIO (bridge do Docker). E o oposto do"
      warn "perfil 'proxy' — por isso perfis nao empilham."
      warn "Disco de 32GB: overlay2 enche rapido. Alem da rotacao de log,"
      warn "  agende:  docker system prune -af --volumes  (semanal)"
      warn "  monitore: docker system df"
      info "4 vCPU: limite os containers para nao competirem —"
      info "  deploy: resources: limits: cpus: '1.0' / memory: 512M"
      info "Verifique inotify em uso: lsof | grep inotify | wc -l"
      ;;
    lxc-docker)
      err  "LEIA ANTES: a Proxmox recomenda VM para Docker, nao LXC."
      err  "Docker em LXC exige nesting, tem conflito de AppArmor e overlayfs"
      err  "aninhado. Funciona, mas e caminho menos testado."
      log  ""
      warn "1) No /etc/pve/lxc/<VMID>.conf do HOST:"
      warn "     features: nesting=1,keyctl=1,fuse=1"
      warn "     (keyctl e obrigatorio; sem ele containers com seccomp falham)"
      log  ""
      warn "2) No HOST PVE — estas chaves sao GLOBAIS e NAO funcionam aqui:"
      warn "     cat > /etc/sysctl.d/96-lxc-docker-host.conf <<'HOSTEOF'"
      warn "     fs.inotify.max_user_instances = 8192"
      warn "     fs.inotify.max_user_watches  = 1048576"
      warn "     vm.max_map_count             = 262144"
      warn "     kernel.pid_max               = 131072"
      warn "     kernel.keys.maxkeys          = 20000"
      warn "     HOSTEOF"
      warn "     sysctl --system"
      log  ""
      warn "3) Storage: overlay2 sobre ZFS nao funciona. Use fuse-overlayfs"
      warn "   (o daemon.json gerado ja detecta isso) ou aceite 'vfs', que"
      warn "   e correto porem lento e gasta muito mais disco."
      log  ""
      info "Se a carga for seria, migre para VM: o custo de overhead da VM"
      info "e menor que o custo de depurar Docker aninhado em producao."
      ;;
    generico)
      info "Perfil sem aposta. Ao descobrir a carga real, troque para o perfil certo."
      ;;
  esac
}

detect_profile() {
  head1 "Deteccao de perfil"
  local guess="generico" why="nenhum servico conhecido encontrado"
  if systemctl list-unit-files 2>/dev/null | grep -q '^unbound\.service'; then
    guess="dns-unbound"; why="unbound instalado"
  elif systemctl list-unit-files 2>/dev/null | grep -qE '^(named|bind9)\.service'; then
    guess="dns"; why="named/bind9 instalado"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^zabbix-proxy\.service'; then
    guess="proxy"; why="zabbix-proxy instalado"
  elif systemctl list-unit-files 2>/dev/null | grep -qE '^(ooklaserver|speedtest)\.service'; then
    guess="medidor"; why="ooklaserver instalado"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^genieacs-'; then
    guess="acs"; why="genieacs instalado"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
    if in_lxc; then guess="lxc-docker"; why="docker instalado DENTRO de LXC"
    else guess="docker"; why="docker instalado"; fi
  fi
  log "  detectado : ${guess}   (${why})"
  log "  descricao : $(profile_desc "$guess")"
  log ""
  log "  ./tune-profile.sh --profile ${guess} --dry-run"
}

show_list() {
  head1 "Perfis disponiveis"
  local p
  for p in dns dns-unbound proxy medidor acs docker lxc-docker generico; do
    printf '  %-10s %s\n' "$p" "$(profile_desc "$p")" | tee -a "$LOG_FILE"
  done
  log ""
  log "  Perfis sao EXCLUSIVOS: aplicar um remove o outro."
}

show_status() {
  head1 "Estado — tune-profile v${VERSION}"
  local act; act=$(active_profile)
  log "  host      : $(hostname)   virt: ${VIRT}"
  log "  vCPU/RAM  : ${VCPU} / ${RAM_MB} MB   kernel: $(uname -r)"
  log "  perfil    : ${act:-nenhum aplicado}"
  [[ -n "$act" ]] && log "  descricao : $(profile_desc "$act")"
  log "  THP       : $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo '-')"
  head1 "Chaves efetivas"
  local k
  for k in vm.swappiness vm.dirty_bytes net.core.rmem_max net.core.somaxconn \
           net.ipv4.tcp_congestion_control net.core.default_qdisc \
           net.ipv4.ip_local_port_range fs.file-max; do
    printf '  %-34s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null || echo '-')" | tee -a "$LOG_FILE"
  done
  head1 "Colisao entre arquivos sysctl"
  local dup
  dup=$(grep -hoP '^\s*\K[a-z0-9_.]+(?=\s*=)' "${SYSCTL_DIR}"/*.conf /etc/sysctl.conf 2>/dev/null | sort | uniq -d)
  if [[ -z "$dup" ]]; then ok "nenhuma chave duplicada"
  else
    warn "vence o arquivo de nome lexicograficamente MAIOR:"
    while read -r k; do
      [[ -z "$k" ]] && continue
      printf '     %-30s %s\n' "$k" "$(grep -lE "^\s*${k//./\\.}\s*=" "${SYSCTL_DIR}"/*.conf /etc/sysctl.conf 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
    done <<<"$dup"
  fi
}

# =============================================================================
main() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  case "$MODE" in
    list)   show_list; exit 0 ;;
    detect) detect_profile; exit 0 ;;
    status) show_status; exit 0 ;;
  esac

  [[ $EUID -eq 0 ]] || { err "execute como root"; exit 1; }
  if [[ -z "$PROFILE" ]]; then
    err "informe --profile <dns|proxy|medidor|acs|generico>"
    show_list; exit 2
  fi
  case "$PROFILE" in
    dns|dns-unbound|proxy|medidor|acs|docker|lxc-docker|generico) ;;
    *) err "perfil invalido: ${PROFILE}"; show_list; exit 2 ;;
  esac

  head1 "tune-profile v${VERSION} — perfil ${PROFILE} $([[ $DRY_RUN -eq 1 ]] && echo '(DRY-RUN)')"
  log "  $(profile_desc "$PROFILE")"
  log "  host: $(hostname)  ${VCPU} vCPU / ${RAM_MB} MB  virt=${VIRT}"
  if in_lxc && [[ "$PROFILE" != "lxc-docker" ]]; then
    warn "voce esta DENTRO de um LXC. Chaves vm.*, fs.inotify.* e kernel.*"
    warn "sao GLOBAIS e vao ser puladas. Considere --profile lxc-docker."
  fi

  local prev; prev=$(active_profile)
  if [[ -n "$prev" && "$prev" != "$PROFILE" ]]; then
    warn "perfil ativo hoje: ${prev} -> sera substituido por ${PROFILE}"
    [[ $FORCE -eq 0 && $DRY_RUN -eq 0 ]] && {
      read -rp "   >> confirmar troca de perfil? [digite SIM]: " r </dev/tty
      [[ "$r" == "SIM" ]] || { err "abortado"; exit 1; }
    }
  fi

  local file="${SYSCTL_DIR}/${PREFIX}-${PROFILE}.conf"
  local tmp; tmp=$(mktemp)
  {
    echo "# ${file}"
    echo "# tune-profile.sh v${VERSION} — perfil: ${PROFILE}"
    echo "# $(profile_desc "$PROFILE")"
    echo "# gerado em $(date -Is) | ${VCPU} vCPU / ${RAM_MB} MB / kernel $(uname -r)"
    echo "# Prefixo 96-: sobrepoe drop-ins 9x menores, perde para 99- explicito."
    echo ""
    "sysctl_${PROFILE}"
  } > "$tmp"

  load_modules_for "$PROFILE"

  head1 "Sysctl do perfil"
  if [[ $DRY_RUN -eq 1 ]]; then
    sed 's/^/   /' "$tmp" | tee -a "$LOG_FILE"
    apply_sysctl_tolerant "$tmp"
  else
    remove_other_profiles "$PROFILE"
    if [[ -f "$file" ]] && cmp -s <(grep -v '^# gerado em' "$file") <(grep -v '^# gerado em' "$tmp"); then
      ok "sem mudancas em ${file} (idempotente)"
    else
      install -m 0644 "$tmp" "$file"; ok "escrito ${file}"
    fi
    apply_sysctl_tolerant "$file"
    echo "$PROFILE" > "${STATE_DIR}/profile"
    date -Is > "${STATE_DIR}/applied-at"
  fi
  rm -f "$tmp"

  case "$PROFILE" in docker|lxc-docker) docker_daemon_json ;; esac
  apply_thp "$(thp_for "$PROFILE")"
  apply_limits "$(limits_for "$PROFILE")"
  profile_notes "$PROFILE"

  head1 "Concluido"
  ok "perfil ${PROFILE} aplicado | log: ${LOG_FILE}"
  [[ $DRY_RUN -eq 1 ]] && warn "foi DRY-RUN — nada mudou"
  warn "reinicie os servicos afetados para os limites valerem"
  info "conferir depois:  ./tune-profile.sh --status"
}

main "$@"
