#!/usr/bin/env bash
# =============================================================================
# validate.sh — v2.0
# Suite consolidada de validacao e TESTE de estado de runtime.
#
# Duas camadas, uma ferramenta:
#
#   PASSIVA (padrao)  le estado. Nao toca em servico, nao gera trafego.
#                     Segura para cron de 5 em 5 minutos e item de Zabbix.
#   ATIVA   (--deep)  EXERCITA o servico: consulta o resolvedor de verdade,
#                     forca TCP, forca EDNS, tenta AXFR nao autorizado, mede
#                     latencia. E o que separa "o processo esta de pe" de
#                     "o servico responde certo".
#
# Todo caso tem um ID ESTAVEL (bind.q.tcp, core.disco, ...). O id e o contrato:
# ele entra no JSON, no relatorio e nos testes. Renomear um id quebra painel de
# terceiro — trate como quebra de API.
#
# BALIZA: RED / GREEN
#   GREEN   o caso passou
#   RED     o caso falhou e alguem precisa agir            -> exit 2
#   YELLOW  divergiu, mas nao derruba o servico agora      -> exit 1
#   SKIP    nao se aplica a este host
#
# MODULOS (auto-detectados, ou escolhidos com --only)
#   core          SO, kernel, disco, memoria, PSI, reboot pendente, sysctl
#   tuning        perfil do tune-profile.sh aplicado e coerente
#   bind          named/bind9 — a suite mais profunda; ver secao mod_bind
#   unbound       unbound, incluindo trust anchor e orcamento de descritores
#   zabbix-proxy  proxy + backend
#   docker        daemon, rotacao de log, inotify, roteamento
#   pve           host Proxmox
#
# SAIDA
#   humano (padrao)   RED/GREEN colorido
#   --json            schema 2, para Zabbix/agregacao/relatorio proprio
#   --report          relatorio markdown com veredito OK / NAO OK
#
# CODIGO DE SAIDA
#   0 = tudo GREEN | 1 = ha YELLOW | 2 = ha RED
#
# Uso:
#   ./validate.sh
#   ./validate.sh --deep --only bind
#   ./validate.sh --json | jq '.checks[] | select(.status=="RED")'
#   ./validate.sh --deep --report > /var/log/validate-$(date +%F).md
#   ./validate.sh --skip pve,docker --strict
#   ./validate.sh --list
#
# TESTABILIDADE
#   PK_SYSROOT=/caminho  prefixa toda leitura de /proc, /sys, /etc e /var.
#   Os comandos externos (systemctl, dig, ss, sysctl...) sao resolvidos pelo
#   PATH, entao a suite de testes roda contra um host sintetico sem root e sem
#   Linux. Isso existe para que CADA caso tenha teste RED e teste GREEN — ver
#   tests/conftest.py.
# =============================================================================
set -uo pipefail

TOOL="validate"; VERSION="2.0"; SCHEMA=2

JSON=0; REPORT=0; ONLY=""; SKIP_MODS=""; QUIET=0; DEEP=0; STRICT=0
DNS_TIMEOUT="${DNS_TIMEOUT:-3}"
LAT_BUDGET_MS="${LAT_BUDGET_MS:-50}"     # orcamento para resposta de cache
MODULOS="core tuning bind unbound zabbix-proxy docker pve"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)    JSON=1 ;;
    --report)  REPORT=1 ;;
    --deep)    DEEP=1 ;;
    --strict)  STRICT=1 ;;
    --quiet)   QUIET=1 ;;
    --only)    shift; ONLY="${1:-}" ;;
    --skip)    shift; SKIP_MODS="${1:-}" ;;
    --timeout) shift; DNS_TIMEOUT="${1:-3}" ;;
    --list)    echo "$MODULOS" | tr ' ' '\n'; exit 0 ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "flag desconhecida: $1" >&2; exit 2 ;;
  esac
  shift
done

# stdout so comporta um formato de maquina. Falhar aqui e melhor do que
# entregar markdown com um objeto JSON grudado no meio.
if [[ $JSON -eq 1 && $REPORT -eq 1 ]]; then
  echo "--json e --report escrevem os dois no stdout: escolha um" >&2; exit 2
fi

# --only e --skip precisam citar modulo que existe, senao o operador acha que
# filtrou e na verdade rodou tudo (ou nada).
_valida_lista() { # <valor> <flag>
  local lista m
  IFS=',' read -ra lista <<<"$1"
  for m in "${lista[@]}"; do
    [[ -z "$m" ]] && continue
    [[ " $MODULOS " == *" $m "* ]] || { echo "modulo desconhecido em $2: $m" >&2; exit 2; }
  done
}
[[ -n "$ONLY" ]]      && _valida_lista "$ONLY" --only
[[ -n "$SKIP_MODS" ]] && _valida_lista "$SKIP_MODS" --skip

HUMANO=1
[[ $JSON -eq 1 || $REPORT -eq 1 ]] && HUMANO=0

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_D=$'\e[2m'; C_0=$'\e[0m'
[[ -t 1 && $HUMANO -eq 1 ]] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""; }

# =============================================================================
# SYSROOT — leitura de arquivo de sistema sempre passa por aqui
# =============================================================================
PK_SYSROOT="${PK_SYSROOT:-}"
sysp()   { printf '%s%s' "$PK_SYSROOT" "$1"; }
sysler() { [[ -r "${PK_SYSROOT}$1" ]] && cat "${PK_SYSROOT}$1" 2>/dev/null; return 0; }
system() { [[ -e "${PK_SYSROOT}$1" ]]; }
sysdir() { [[ -d "${PK_SYSROOT}$1" ]]; }

# =============================================================================
# MODELO DE CASO
# =============================================================================
# Registro: id US suite US status US titulo US esperado US obtido US correcao US ms
# US = 0x1f. Nao usamos '|' porque detalhe de sysctl e saida de dig contem '|'
# a valer, e o separador partia o registro na hora de gerar o JSON.
US=$'\x1f'
CASOS=()
N_GREEN=0; N_RED=0; N_YELLOW=0; N_SKIP=0
SUITE=""
_MS_ANT=0

_ms_agora() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local e="${EPOCHREALTIME/,/.}"; e="${e%.*}${e#*.}"; e="${e:0:${#e}-3}"
    printf '%s' "$e"
  else
    printf '%s' "$(( $(date +%s) * 1000 ))"
  fi
}

_caso() { # <id> <status> <titulo> <esperado> <obtido> <correcao>
  local id="$1" st="$2" tit="$3" esp="$4" obt="$5" fix="${6:-}"
  local agora ms
  agora=$(_ms_agora); ms=$(( agora - _MS_ANT )); _MS_ANT=$agora
  [[ $ms -lt 0 || $ms -gt 600000 ]] && ms=0
  CASOS+=("${id}${US}${SUITE}${US}${st}${US}${tit}${US}${esp}${US}${obt}${US}${fix}${US}${ms}")
  case "$st" in
    GREEN)  N_GREEN=$((N_GREEN+1)) ;;
    RED)    N_RED=$((N_RED+1)) ;;
    YELLOW) N_YELLOW=$((N_YELLOW+1)) ;;
    SKIP)   N_SKIP=$((N_SKIP+1)) ;;
  esac
  if [[ $HUMANO -eq 1 ]]; then
    case "$st" in
      GREEN)  [[ $QUIET -eq 0 ]] && printf '  %sGREEN%s  %-42s %s\n' "$C_G" "$C_0" "$tit" "$obt" ;;
      RED)    printf '  %sRED%s    %-42s esperado: %s | obtido: %s\n' "$C_R" "$C_0" "$tit" "$esp" "$obt"
              [[ -n "$fix" ]] && printf '         %s-> %s%s\n' "$C_D" "$fix" "$C_0" ;;
      YELLOW) printf '  %sYELLOW%s %-42s esperado: %s | obtido: %s\n' "$C_Y" "$C_0" "$tit" "$esp" "$obt"
              [[ -n "$fix" ]] && printf '         %s-> %s%s\n' "$C_D" "$fix" "$C_0" ;;
      SKIP)   [[ $QUIET -eq 0 ]] && printf '  %s--%s     %-42s %s\n' "$C_B" "$C_0" "$tit" "$obt" ;;
    esac
  fi
  return 0
}

verde()    { _caso "$1" GREEN  "$2" "$3" "$3" ""; }
vermelho() { _caso "$1" RED    "$2" "$3" "$4" "${5:-}"; }
amarelo()  { _caso "$1" YELLOW "$2" "$3" "$4" "${5:-}"; }
pulado()   { _caso "$1" SKIP   "$2" "-" "$3" ""; }

# O motor da suite. Compara ESPERADO com OBTIDO e escolhe a cor.
# Toda comparacao passa por aqui: e o unico lugar onde uma severidade e
# decidida, entao o teste de cada caso vira o teste de um par de strings.
afere() { # <id> <titulo> <esperado> <obtido> [correcao] [sev=RED]
  local id="$1" tit="$2" esp="$3" obt="$4" fix="${5:-}" sev="${6:-RED}"
  if [[ "$obt" == "$esp" ]]; then _caso "$id" GREEN "$tit" "$esp" "$obt" ""
  elif [[ "$sev" == "WARN" ]];  then _caso "$id" YELLOW "$tit" "$esp" "$obt" "$fix"
  else _caso "$id" RED "$tit" "$esp" "$obt" "$fix"; fi
}

# Limiar numerico. Valor nao numerico e RED, nunca GREEN por omissao — era
# assim que "LimitNOFILE vazio" passava como se estivesse configurado.
afere_min() { # <id> <titulo> <minimo> <valor> [correcao] [sev=RED]
  local id="$1" tit="$2" min="$3" val="$4" fix="${5:-}" sev="${6:-RED}"
  if [[ "$val" =~ ^[0-9]+$ ]] && [[ $val -ge $min ]]; then
    _caso "$id" GREEN "$tit" ">= ${min}" "$val" ""
  elif [[ "$sev" == "WARN" ]]; then
    _caso "$id" YELLOW "$tit" ">= ${min}" "${val:-<vazio>}" "$fix"
  else
    _caso "$id" RED "$tit" ">= ${min}" "${val:-<vazio>}" "$fix"
  fi
}

afere_max() { # <id> <titulo> <maximo> <valor> [correcao] [sev=RED]
  local id="$1" tit="$2" max="$3" val="$4" fix="${5:-}" sev="${6:-RED}"
  if [[ "$val" =~ ^[0-9]+$ ]] && [[ $val -le $max ]]; then
    _caso "$id" GREEN "$tit" "<= ${max}" "$val" ""
  elif [[ "$sev" == "WARN" ]]; then
    _caso "$id" YELLOW "$tit" "<= ${max}" "${val:-<vazio>}" "$fix"
  else
    _caso "$id" RED "$tit" "<= ${max}" "${val:-<vazio>}" "$fix"
  fi
}

hdr() {
  SUITE="$1"
  [[ $HUMANO -eq 1 ]] && { echo; echo "${C_B}== $1 ==${C_0}"; }
  return 0
}
want() {
  [[ ",${SKIP_MODS}," == *",$1,"* ]] && return 1
  [[ -z "$ONLY" ]] && return 0
  [[ ",$ONLY," == *",$1,"* ]]
}

# =============================================================================
# HELPERS DE SISTEMA
# =============================================================================
# `systemctl list-unit-files X.service` retorna 0 mesmo quando a unidade nao
# existe em varias versoes do systemd — so muda o "0 unit files listed". Checar
# o codigo de saida fazia toda suite rodar em host que nao tem o servico, e
# entao TUDO virava RED. Confere-se a saida.
svc_exists() { systemctl list-unit-files "$1.service" 2>/dev/null | grep -q "^${1}\.service"; }
svc_estado() { systemctl is-active "$1" 2>/dev/null | head -1; }

# Porta escutando -> caso pronto. Existe para nao repetir `A && verde || vermelho`
# quatro vezes: nessa forma o ramo do `||` roda tambem quando o `verde` falha,
# e o resultado seria o MESMO id emitido duas vezes com cores opostas.
caso_porta() { # <id> <titulo> <proto tcp|udp> <porta> <correcao>
  local fn="porta_${3}"
  if "$fn" "$4"; then
    verde "$1" "$2" "escutando"
  else
    vermelho "$1" "$2" "escutando" "sem socket" "$5"
  fi
}
nofile_of()  { systemctl show "$1" -p LimitNOFILE --value 2>/dev/null | head -1; }
# SC2329: chamadas indiretamente por caso_porta ("$fn"), que o shellcheck nao
# enxerga. Uma diretiva por funcao: `disable` vale so para o comando seguinte.
# shellcheck disable=SC2329
porta_tcp()  { ss -lnt 2>/dev/null | grep -qE "[:.]${1}[[:space:]]"; }
# shellcheck disable=SC2329
porta_udp()  { ss -lnu 2>/dev/null | grep -qE "[:.]${1}[[:space:]]"; }
sysctl_n()   { sysctl -n "$1" 2>/dev/null | head -1; }

_norm() { tr -s '[:space:]' ' ' <<<"${1:-}" | sed 's/^ *//; s/ *$//'; }

# =============================================================================
# HELPERS DE DNS
# =============================================================================
# dig devolve 0 com resposta VAZIA, com NXDOMAIN e com SERVFAIL. Checar so o
# codigo de saida — o bug do script original — chama de "resolvendo" um
# resolvedor que nao resolve nada. Aqui olhamos SEMPRE o corpo da resposta.
_dig() { # <servidor> <nome> <tipo> [extras...]
  local srv="$1" nome="$2" tipo="${3:-A}"; shift 3
  dig "@${srv}" "$nome" "$tipo" +time="$DNS_TIMEOUT" +tries=1 "$@" 2>/dev/null
}
_dig_status()  { grep -oP 'status:\s*\K[A-Z]+' <<<"${1:-}" | head -1; }
_dig_flags()   { grep -oP '^;; flags:\s*\K[a-z ]+' <<<"${1:-}" | head -1; }
_dig_tem_flag(){ [[ " $(_dig_flags "$1") " == *" $2 "* ]]; }
# Secao ANSWER, sem comentario e sem linha em branco.
_dig_answer() {
  awk '/^;; ANSWER SECTION:/{f=1;next} /^;;/{f=0} f&&NF&&$0!~/^;/' <<<"${1:-}"
}
_dig_ttl()     { _dig_answer "$1" | awk 'NR==1{print $2}'; }
_dig_ancount() { grep -oP 'ANSWER:\s*\K[0-9]+' <<<"${1:-}" | head -1; }

# =============================================================================
# core
# =============================================================================
mod_core() {
  hdr core
  local codename kernel
  codename=$(. <(sysler /etc/os-release) 2>/dev/null; echo "${VERSION_CODENAME:-desconhecido}")
  kernel=$(uname -r)
  verde "core.sistema" "sistema" "Debian ${codename} / kernel ${kernel}"

  # disco: dois limiares, um caso so. Ficar em 85% nao e igual a ficar em 95%.
  local pct freemb
  pct=$(df -P "$(sysp /)" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
  freemb=$(df -Pm "$(sysp /)" 2>/dev/null | awk 'NR==2{print $4}')
  if   [[ ${pct:-0} -ge 90 ]]; then
    vermelho "core.disco" "disco /" "< 80% usado" "${pct}% usado, ${freemb}MB livres" \
      "libere espaco antes de qualquer upgrade: apt clean; journalctl --vacuum-size=200M"
  elif [[ ${pct:-0} -ge 80 ]]; then
    amarelo "core.disco" "disco /" "< 80% usado" "${pct}% usado, ${freemb}MB livres" \
      "planeje limpeza; upgrade de release precisa de folga"
  else
    verde "core.disco" "disco /" "${pct}% usado, ${freemb}MB livres"
  fi

  # memoria por MemAvailable, nao por 'free': cache conta como disponivel.
  local memtot memav pctav
  memtot=$(sysler /proc/meminfo | awk '/MemTotal/{print $2}')
  memav=$(sysler /proc/meminfo | awk '/MemAvailable/{print $2}')
  if [[ "${memtot:-0}" =~ ^[0-9]+$ && ${memtot:-0} -gt 0 && "${memav:-}" =~ ^[0-9]+$ ]]; then
    pctav=$(( memav * 100 / memtot ))
    if   [[ $pctav -lt 10 ]]; then
      vermelho "core.memoria" "memoria" ">= 20% disponivel" "${pctav}% disponivel" \
        "OOM killer iminente; identifique o consumidor com 'ps -eo rss,comm --sort=-rss | head'"
    elif [[ $pctav -lt 20 ]]; then
      amarelo "core.memoria" "memoria" ">= 20% disponivel" "${pctav}% disponivel" \
        "sem folga para pico; reveja limites dos servicos"
    else
      verde "core.memoria" "memoria" "${pctav}% disponivel de $((memtot/1024))MB"
    fi
  else
    pulado "core.memoria" "memoria" "/proc/meminfo ilegivel"
  fi

  # PSI mede espera real. Media de uso alta com PSI baixo e maquina saudavel
  # e ocupada; PSI alto com uso baixo e maquina travada esperando disco.
  if [[ -r "${PK_SYSROOT}/proc/pressure/io" ]]; then
    local psi_io psi_mem
    psi_io=$(sysler /proc/pressure/io | awk '/^some/{gsub(/avg60=/,"",$3); print $3}')
    psi_mem=$(sysler /proc/pressure/memory | awk '/^some/{gsub(/avg60=/,"",$3); print $3}')
    if awk -v v="${psi_io:-0}" 'BEGIN{exit !(v+0 > 20)}'; then
      amarelo "core.psi.io" "PSI io" "avg60 <= 20%" "avg60=${psi_io}%" \
        "processos parados esperando I/O; veja iostat -x 1"
    else verde "core.psi.io" "PSI io" "avg60=${psi_io}%"; fi
    if awk -v v="${psi_mem:-0}" 'BEGIN{exit !(v+0 > 10)}'; then
      amarelo "core.psi.mem" "PSI memoria" "avg60 <= 10%" "avg60=${psi_mem}%" \
        "pressao de memoria sustentada; reveja cache dos servicos"
    else verde "core.psi.mem" "PSI memoria" "avg60=${psi_mem}%"; fi
  else
    pulado "core.psi.io" "PSI" "kernel sem /proc/pressure"
  fi

  # reboot pendente: kernel instalado mais novo que o que esta rodando
  local novo
  novo=$(dpkg-query -W -f='${Package}\n' 'linux-image-*' 'proxmox-kernel-*-pve' 'pve-kernel-*-pve' 2>/dev/null \
         | grep -oP '\d+\.\d+\.\d+' | sort -V | tail -1)
  if [[ -n "$novo" && "$kernel" != *"$novo"* ]]; then
    amarelo "core.reboot" "reboot pendente" "rodando o kernel mais novo" \
      "instalado ${novo}, rodando ${kernel}" "agende reboot; ate la o kernel novo nao vale"
  else
    verde "core.reboot" "reboot pendente" "kernel em uso e o mais novo"
  fi

  # colisao de sysctl: com a mesma chave em dois arquivos vence o nome
  # lexicograficamente maior, e nao o que voce editou por ultimo.
  local dup
  dup=$(grep -hoP '^\s*\K[a-z0-9_.]+(?=\s*=)' "${PK_SYSROOT}"/etc/sysctl.d/*.conf \
        "${PK_SYSROOT}/etc/sysctl.conf" 2>/dev/null | sort | uniq -d | tr '\n' ' ')
  if [[ -n "${dup// }" ]]; then
    amarelo "core.sysctl.colisao" "colisao de sysctl" "nenhuma chave duplicada" "${dup% }" \
      "a chave declarada duas vezes so vale no arquivo de nome maior"
  else
    verde "core.sysctl.colisao" "colisao de sysctl" "nenhuma chave duplicada"
  fi

  # No Debian 13 o /etc/sysctl.conf deixou de ser lido. Continua no disco,
  # continua parecendo aplicado, e nao vale nada.
  if [[ "$codename" == "trixie" ]] && sysler /etc/sysctl.conf | grep -qE '^[^#]'; then
    vermelho "core.sysctl.conf" "/etc/sysctl.conf" "vazio ou so comentario no Debian 13" \
      "tem diretiva ativa" "mova para /etc/sysctl.d/99-local.conf — no Debian 13 este arquivo nao e lido"
  else
    verde "core.sysctl.conf" "/etc/sysctl.conf" "sem diretiva orfa"
  fi

  # Relogio fora de sincronia estraga DNSSEC, TLS e cluster. Barato de checar.
  local ntp
  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null | head -1)
  if [[ -z "$ntp" ]]; then
    pulado "core.relogio" "sincronia de relogio" "timedatectl indisponivel"
  else
    afere "core.relogio" "sincronia de relogio" "yes" "$ntp" \
      "sem NTP o DNSSEC e o TLS falham por janela de validade; habilite systemd-timesyncd ou chrony" WARN
  fi
}

# =============================================================================
# tuning
# =============================================================================
mod_tuning() {
  hdr tuning
  local prof=""
  # v2 le o estado do pkops; o diretorio antigo continua valendo para host
  # que ainda nao migrou.
  if system /var/lib/pkops/state/tuning.env; then
    prof=$(sysler /var/lib/pkops/state/tuning.env | grep -oP '^profile=\K.*' | head -1)
  fi
  [[ -z "$prof" ]] && system /var/lib/tune-profile/profile && \
    prof=$(sysler /var/lib/tune-profile/profile | head -1)

  if [[ -z "$prof" ]]; then
    amarelo "tuning.perfil" "perfil aplicado" "um perfil do tune-profile.sh" "nenhum" \
      "rode: tune-profile.sh --profile <perfil> (pkassess.sh sugere qual)"
    return 0
  fi
  verde "tuning.perfil" "perfil aplicado" "$prof"

  # Vem antes da checagem do arquivo de proposito: coerencia com o kernel
  # depende so do estado declarado. Encadear as duas fazia o sumico do arquivo
  # levar junto uma informacao que continuava disponivel.
  local kdecl kagora
  kdecl=$(sysler /var/lib/pkops/state/tuning.env | grep -oP '^PK_KERNEL=\K.*' | head -1)
  kagora=$(uname -r)
  if [[ -z "$kdecl" ]]; then
    pulado "tuning.kernel" "coerencia com o kernel" "estado sem PK_KERNEL"
  else
    # Tuning e funcao do kernel: chave some, chave nasce, valor default muda.
    # Perfil aplicado em outro kernel e perfil nao aplicado.
    afere "tuning.kernel" "coerencia com o kernel" "$kagora" "$kdecl" \
      "perfil aplicado em outro kernel; reaplique tune-profile.sh --profile ${prof}" WARN
  fi

  local pf="/etc/sysctl.d/96-tune-profile-${prof}.conf"
  if ! system "$pf"; then
    vermelho "tuning.arquivo" "arquivo do perfil" "$(basename "$pf") presente" "ausente" \
      "o estado diz '${prof}' mas o arquivo sumiu; reaplique tune-profile.sh --profile ${prof}"
    # SKIP explicito em vez de simplesmente nao emitir o caso: um id que some
    # do relatorio some tambem do painel, e quem le entende como "nao ha
    # problema" em vez de "nao foi possivel medir".
    pulado "tuning.deriva" "deriva do perfil" "sem arquivo de perfil para comparar"
  else
    verde "tuning.arquivo" "arquivo do perfil" "$(basename "$pf")"

    # Deriva efetiva: o que esta escrito bate com o que o kernel esta usando?
    # Normalizar os dois lados e obrigatorio — o kernel separa chave multivalor
    # com TAB e a comparacao crua acusa deriva que nao existe.
    local drift=0 total=0 line key val cur divergentes=""
    while IFS= read -r line; do
      [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
      key="${line%%=*}"; key="${key// }"; val="${line#*=}"; val="${val# }"
      system "/proc/sys/${key//.//}" || continue
      total=$((total+1))
      cur=$(sysctl_n "$key")
      if [[ "$(_norm "$cur")" != "$(_norm "$val")" ]]; then
        drift=$((drift+1))
        [[ $drift -le 5 ]] && divergentes+="${key}(arquivo=$(_norm "$val") efetivo=$(_norm "$cur")) "
      fi
    done < <(sysler "$pf")

    if [[ $drift -eq 0 ]]; then
      verde "tuning.deriva" "deriva do perfil" "${total} chave(s) conferem"
    else
      amarelo "tuning.deriva" "deriva do perfil" "0 chave divergente" \
        "${drift} de ${total}: ${divergentes% }" \
        "reaplique com 'sysctl --system' ou tune-profile.sh --profile ${prof}"
    fi
  fi

  # tuning do host PVE e um estado separado, por kernel
  if sysdir /var/lib/pkops/tune || sysdir /var/lib/pve-maint/tune; then
    if system "/var/lib/pkops/tune/state-${kagora}.env" || \
       system "/var/lib/pve-maint/tune/state-${kagora}.env"; then
      verde "tuning.pve" "proxmox_tune" "aplicado neste kernel"
    else
      amarelo "tuning.pve" "proxmox_tune" "estado para ${kagora}" "ausente" \
        "rode proxmox_tune.sh depois de trocar de kernel"
    fi
  fi
}

# =============================================================================
# bind — a suite profunda
# =============================================================================
# Passiva: a config esta correta e o processo esta de pe.
# Ativa (--deep): o resolvedor RESPONDE certo. Sao coisas diferentes; named
# sobe feliz servindo zona velha, sem TCP, sem validar DNSSEC e com AXFR
# liberado para o mundo, e nenhum check de "is-active" pega nada disso.
BIND_SVC=""
BIND_CONF=""
BIND_DUMP=""

_bind_descobre() {
  BIND_SVC=""
  svc_exists named && BIND_SVC=named
  [[ -z "$BIND_SVC" ]] && svc_exists bind9 && BIND_SVC=bind9
  BIND_CONF=/etc/bind/named.conf
  system "$BIND_CONF" || BIND_CONF=/etc/named.conf
}

# named-checkconf -p imprime a config JA RESOLVIDA: includes expandidos, ACLs
# no lugar, defaults explicitados. Grepar named.conf a mao erra em qualquer
# host que separe options em outro arquivo — que e o layout padrao do Debian.
_bind_dump() {
  [[ -n "$BIND_DUMP" ]] && { printf '%s' "$BIND_DUMP"; return 0; }
  BIND_DUMP=$(named-checkconf -p "$(sysp "$BIND_CONF")" 2>/dev/null)
  printf '%s' "$BIND_DUMP"
}

# Extrai uma diretiva de options do dump. Devolve vazio se nao existir.
_bind_opt() { # <nome>
  _bind_dump | grep -oP "^\s*${1}\s+\K[^;]+" | head -1 | sed 's/^ *//; s/ *$//; s/^"//; s/"$//'
}

# Conteudo do bloco { ... } de uma diretiva, achatado em uma linha:
#   allow-transfer { none; };                  -> none
#   allow-recursion { 10.0.0.0/8; localhost; } -> 10.0.0.0/8 localhost
#
# O dump quebra cada elemento da ACL em uma linha propria, entao o stream vira
# uma linha so antes do match. A lookbehind evita casar o sufixo de outra
# diretiva (procurar 'recursion' nao pode achar 'allow-recursion').
_bind_bloco() { # <nome>
  _bind_dump | tr '\n' ' ' \
    | grep -oP "(?<![-a-zA-Z0-9])${1}\s*\{\K[^}]*" | head -1 \
    | tr -s ' \t' ' ' | sed 's/[";]//g; s/^ *//; s/ *$//'
}

# Zonas master locais: nome<TAB>arquivo
_bind_zonas_master() {
  _bind_dump | awk '
    /^zone[ \t]+"/ { nome=$2; gsub(/"/,"",nome); tipo=""; arq=""; dentro=1; next }
    dentro && /type[ \t]+(master|primary)/ { tipo="master" }
    dentro && /file[ \t]+"/ { arq=$0; sub(/^.*file[ \t]+"/,"",arq); sub(/".*$/,"",arq) }
    dentro && /^};/ { if (tipo=="master" && nome!="." && arq!="") printf "%s\t%s\n", nome, arq; dentro=0 }
  '
}

mod_bind() {
  hdr bind
  _bind_descobre
  if [[ -z "$BIND_SVC" ]]; then
    pulado "bind.unidade" "bind instalado" "unidade named/bind9 ausente"
    return 0
  fi
  verde "bind.unidade" "bind instalado" "unidade ${BIND_SVC}.service"

  afere "bind.servico" "servico ${BIND_SVC}" "active" "$(svc_estado "$BIND_SVC")" \
    "systemctl status ${BIND_SVC}; journalctl -u ${BIND_SVC} -n 50"

  caso_porta "bind.porta.udp" "porta 53/udp" udp 53 \
    "verifique listen-on/listen-on-v6 nas options"

  # TCP nao e opcional (RFC 7766). Sem ele morre AXFR, morre resposta grande e
  # morre DNSSEC com chave grande — e o sintoma chega como "as vezes falha".
  caso_porta "bind.porta.tcp" "porta 53/tcp" tcp 53 \
    "TCP e obrigatorio (RFC 7766): resposta grande e AXFR dependem dele"

  # -z carrega TODAS as zonas, nao so a sintaxe. E a diferenca entre "o arquivo
  # esta bem escrito" e "o named consegue subir com ele".
  if named-checkconf -z "$(sysp "$BIND_CONF")" >/dev/null 2>&1; then
    verde "bind.checkconf" "named-checkconf -z" "config e zonas carregam"
  else
    local erro; erro=$(named-checkconf -z "$(sysp "$BIND_CONF")" 2>&1 | head -1)
    vermelho "bind.checkconf" "named-checkconf -z" "config e zonas carregam" \
      "${erro:-falhou}" "corrija antes de recarregar; um reload agora derruba a zona"
  fi

  # named-checkconf -p precisa ler named.conf E os includes. No Debian o
  # rndc.key e 0640 root:bind, entao rodando sem root o dump volta VAZIO.
  # Sem esta guarda, toda a leitura de postura abaixo concluiria "nao
  # declarado" e o operador receberia um relatorio de falhas que sao apenas
  # falta de permissao — o tipo de alarme falso que faz a suite perder
  # credibilidade e passar a ser ignorada.
  local dump_ok=1
  [[ -z "$(_bind_dump)" ]] && dump_ok=0
  if [[ $dump_ok -eq 0 ]]; then
    local motivo="named-checkconf -p nao devolveu config (rode como root)"
    pulado "bind.zonas"            "zonas master"      "$motivo"
    pulado "bind.recursao"         "allow-recursion"   "$motivo"
    pulado "bind.transferencia"    "allow-transfer"    "$motivo"
    pulado "bind.dnssec.validacao" "dnssec-validation" "$motivo"
    pulado "bind.version"          "version nas options" "$motivo"
    pulado "bind.querylog"         "querylog"          "$motivo"
    pulado "bind.cache.limite"     "max-cache-size"    "$motivo"
    pulado "bind.roothints"        "root hints"        "$motivo"
    afere_min "bind.limitnofile" "LimitNOFILE" 16384 "$(nofile_of "$BIND_SVC")" \
      "systemctl edit ${BIND_SVC} -> [Service] LimitNOFILE=32768" WARN
    pulado "bind.deep" "testes ativos" "sem config legivel nao ha zona para exercitar"
    return 0
  fi

  # Cada zona master conferida individualmente. Zona quebrada nao impede o
  # named de subir: ele serve as outras e essa some do ar em silencio.
  local zonas nz=0 zruins=""
  zonas=$(_bind_zonas_master)
  if [[ -n "$zonas" ]]; then
    local nome arq
    while IFS=$'\t' read -r nome arq; do
      [[ -z "$nome" ]] && continue
      nz=$((nz+1))
      named-checkzone "$nome" "$(sysp "$arq")" >/dev/null 2>&1 || zruins+="${nome} "
    done <<<"$zonas"
    if [[ -z "$zruins" ]]; then
      verde "bind.zonas" "zonas master" "${nz} zona(s) validas"
    else
      vermelho "bind.zonas" "zonas master" "${nz} zona(s) validas" "invalidas: ${zruins% }" \
        "named-checkzone <zona> <arquivo> mostra a linha exata"
    fi
  else
    pulado "bind.zonas" "zonas master" "nenhuma zona master declarada"
  fi

  # rndc e o canal de controle. Sem ele nao ha reload nem flush, e a operacao
  # vira 'systemctl restart' — que derruba o cache inteiro.
  if rndc status >/dev/null 2>&1; then
    verde "bind.rndc" "canal rndc" "respondendo"
  else
    amarelo "bind.rndc" "canal rndc" "respondendo" "sem resposta" \
      "rndc-confgen -a e confira /etc/bind/rndc.key; sem rndc so resta restart"
  fi

  # --- postura de seguranca ---------------------------------------------------
  local rec transf
  rec=$(_bind_bloco allow-recursion)
  if [[ -z "$rec" ]]; then
    vermelho "bind.recursao" "allow-recursion" "restrito a redes conhecidas" "nao declarado" \
      "sem allow-recursion o default depende da versao; declare explicitamente"
  elif [[ "$rec" == *any* ]]; then
    vermelho "bind.recursao" "allow-recursion" "restrito a redes conhecidas" "any" \
      "RESOLVEDOR ABERTO: vira amplificador de DDoS. Restrinja a sua rede"
  else
    verde "bind.recursao" "allow-recursion" "$rec"
  fi

  # allow-transfer sem declaracao permite AXFR de qualquer origem em varias
  # versoes: a zona inteira, com todo o inventario interno, para quem pedir.
  transf=$(_bind_bloco allow-transfer)
  if [[ -z "$transf" ]]; then
    vermelho "bind.transferencia" "allow-transfer" "none ou lista de secundarios" "nao declarado" \
      "declare 'allow-transfer { none; };' nas options e libere so nos secundarios"
  elif [[ "$transf" == *any* ]]; then
    vermelho "bind.transferencia" "allow-transfer" "none ou lista de secundarios" "any" \
      "qualquer um baixa a zona inteira com dig AXFR"
  else
    verde "bind.transferencia" "allow-transfer" "$transf"
  fi

  local dv; dv=$(_bind_opt dnssec-validation)
  case "$dv" in
    auto|yes) verde "bind.dnssec.validacao" "dnssec-validation" "$dv" ;;
    "")       amarelo "bind.dnssec.validacao" "dnssec-validation" "auto" "nao declarado" \
                "declare 'dnssec-validation auto;' — o default varia entre versoes" ;;
    *)        vermelho "bind.dnssec.validacao" "dnssec-validation" "auto ou yes" "$dv" \
                "com validacao desligada o resolvedor aceita resposta forjada" ;;
  esac

  local ver; ver=$(_bind_opt version)
  if [[ -n "$ver" ]]; then
    verde "bind.version" "version nas options" "mascarada (${ver})"
  else
    amarelo "bind.version" "version nas options" "mascarada" "expondo a versao real" \
      "declare 'version \"none\";' — versao exposta e o primeiro passo de quem procura CVE"
  fi

  # querylog em producao gera I/O por consulta. Em resolvedor com carga real e
  # o suficiente para virar gargalo de disco.
  local ql; ql=$(_bind_opt querylog)
  if [[ "$ql" == "yes" ]]; then
    amarelo "bind.querylog" "querylog" "no" "yes" \
      "uma linha de log por consulta; desligue fora de investigacao (rndc querylog off)"
  else
    verde "bind.querylog" "querylog" "desligado"
  fi

  # Sem max-cache-size o named cresce ate o limite da maquina e o OOM killer
  # escolhe a vitima — normalmente ele mesmo, no pior momento.
  local mcs; mcs=$(_bind_opt max-cache-size)
  if [[ -n "$mcs" ]]; then
    verde "bind.cache.limite" "max-cache-size" "$mcs"
  else
    amarelo "bind.cache.limite" "max-cache-size" "definido" "sem limite" \
      "defina max-cache-size (ex.: 30%) — sem teto o cache cresce ate o OOM"
  fi

  local hint; hint=$(_bind_dump | awk '/^zone[ \t]+"\."/{d=1} d&&/file[ \t]+"/{sub(/^.*file[ \t]+"/,"");sub(/".*$/,"");print;exit}')
  if [[ -z "$hint" ]]; then
    pulado "bind.roothints" "root hints" "sem zona hint declarada (usa a embutida)"
  elif system "$hint"; then
    verde "bind.roothints" "root hints" "$hint"
  else
    vermelho "bind.roothints" "root hints" "arquivo presente" "ausente: ${hint}" \
      "instale o pacote dns-root-data ou corrija o caminho da zona hint"
  fi

  afere_min "bind.limitnofile" "LimitNOFILE" 16384 "$(nofile_of "$BIND_SVC")" \
    "systemctl edit ${BIND_SVC} -> [Service] LimitNOFILE=32768" WARN

  [[ $DEEP -eq 1 ]] || {
    pulado "bind.deep" "testes ativos" "use --deep para exercitar o resolvedor"
    return 0
  }

  # --- camada ativa -----------------------------------------------------------
  local r st

  # Recursao: NOERROR com ANSWER > 0. NOERROR com ANSWER 0 e "nao existe esse
  # tipo", nao e resolucao.
  local an
  r=$(_dig 127.0.0.1 google.com A)
  st=$(_dig_status "$r"); an=$(_dig_ancount "$r")
  if [[ "$st" == "NOERROR" && "${an:-0}" != "0" && -n "$(_dig_answer "$r")" ]]; then
    verde "bind.q.recursiva" "consulta recursiva" "NOERROR com resposta"
  else
    vermelho "bind.q.recursiva" "consulta recursiva" "NOERROR com resposta" \
      "${st:-sem resposta} / ${an:-0} registro(s)" \
      "o resolvedor nao esta resolvendo: cheque forwarders, saida 53/udp e root hints"
  fi

  # NXDOMAIN de verdade. Resolvedor com wildcard de provedor devolve NOERROR
  # com um IP de portal — e ai TODO nome inexistente 'existe'.
  r=$(_dig 127.0.0.1 "nao-existe-$$-$(date +%s).invalid" A)
  st=$(_dig_status "$r")
  afere "bind.q.nxdomain" "nome inexistente" "NXDOMAIN" "${st:-sem resposta}" \
    "NOERROR aqui indica sequestro de NXDOMAIN por forwarder do provedor"

  # TCP: mesma pergunta, transporte obrigatorio. Firewall que so libera udp/53
  # passa em todo teste rapido e quebra resposta grande.
  r=$(_dig 127.0.0.1 google.com A +tcp)
  st=$(_dig_status "$r")
  afere "bind.q.tcp" "consulta via TCP" "NOERROR" "${st:-sem resposta}" \
    "libere 53/tcp; sem ele DNSSEC e AXFR falham de forma intermitente"

  # EDNS com bufsize 1232: o valor que a comunidade adotou por causa de MTU.
  # Truncar aqui obriga fallback para TCP em toda resposta assinada.
  #
  # `+edns=0`, nao `+noedns=0`: `+noedns` LIMPA a versao de EDNS, e o bufsize
  # so e anunciado dentro do OPT do EDNS0. Com a forma antiga a consulta saia
  # sem EDNS nenhum, o +bufsize=1232 era inerte e o caso media outra coisa —
  # justamente o middlebox que remove EDNS, o alvo declarado aqui, passava
  # despercebido.
  r=$(_dig 127.0.0.1 google.com A +edns=0 +bufsize=1232)
  if _dig_tem_flag "$r" tc; then
    amarelo "bind.q.edns" "EDNS bufsize 1232" "sem truncamento" "resposta truncada (flag tc)" \
      "cada consulta paga um round-trip extra em TCP; reveja edns-udp-size"
  elif [[ "$(_dig_status "$r")" == "NOERROR" ]]; then
    verde "bind.q.edns" "EDNS bufsize 1232" "sem truncamento"
  else
    vermelho "bind.q.edns" "EDNS bufsize 1232" "NOERROR sem truncamento" \
      "$(_dig_status "$r")" "middlebox descartando EDNS e a causa mais comum"
  fi

  # DNSSEC positivo: dominio assinado tem de voltar com AD.
  r=$(_dig 127.0.0.1 iana.org A +dnssec)
  if _dig_tem_flag "$r" ad; then
    verde "bind.q.dnssec.positivo" "DNSSEC valida assinado" "iana.org com flag AD"
  else
    vermelho "bind.q.dnssec.positivo" "DNSSEC valida assinado" "flag AD" \
      "sem AD (flags: $(_dig_flags "$r"))" \
      "o validator nao esta validando; confira dnssec-validation e o relogio do host"
  fi

  # DNSSEC negativo: dominio quebrado de proposito. A resposta CERTA e
  # SERVFAIL. Receber NOERROR aqui significa que a validacao esta desligada —
  # e esse e o caso que passa despercebido, porque 'funciona'.
  r=$(_dig 127.0.0.1 dnssec-failed.org A)
  st=$(_dig_status "$r")
  afere "bind.q.dnssec.negativo" "DNSSEC rejeita quebrado" "SERVFAIL" "${st:-sem resposta}" \
    "NOERROR significa validacao desligada: o resolvedor aceita resposta forjada"

  # Cache ativo: a segunda consulta ao mesmo nome tem de voltar com TTL menor.
  # TTL igual duas vezes seguidas e sinal de cache desabilitado ou forwarder
  # reescrevendo TTL.
  local ttl1 ttl2
  ttl1=$(_dig_ttl "$(_dig 127.0.0.1 example.com A)")
  ttl2=$(_dig_ttl "$(_dig 127.0.0.1 example.com A)")
  if [[ "${ttl1:-}" =~ ^[0-9]+$ && "${ttl2:-}" =~ ^[0-9]+$ ]]; then
    if [[ $ttl2 -le $ttl1 ]]; then
      verde "bind.q.cache" "cache em uso" "TTL decrescente (${ttl1} -> ${ttl2})"
    else
      amarelo "bind.q.cache" "cache em uso" "TTL decrescente" "${ttl1} -> ${ttl2}" \
        "TTL que sobe indica resposta vindo de fora do cache a cada consulta"
    fi
  else
    pulado "bind.q.cache" "cache em uso" "sem TTL legivel na resposta"
  fi

  # Latencia de resposta CACHEADA. Nao mede a internet: mede o proprio named.
  # Acima do orcamento com a resposta em cache, o gargalo e local.
  local t0 t1 lat
  t0=$(_ms_agora); _dig 127.0.0.1 example.com A >/dev/null; t1=$(_ms_agora)
  lat=$(( t1 - t0 ))
  afere_max "bind.q.latencia" "latencia de cache" "$LAT_BUDGET_MS" "$lat" \
    "resposta em cache acima de ${LAT_BUDGET_MS}ms indica CPU saturada ou querylog ligado" WARN

  # AXFR a partir do proprio host, que normalmente NAO esta na lista de
  # secundarios. Esperado: REFUSED. Se a zona vier inteira, ela vem inteira
  # para qualquer um.
  if [[ -n "$zonas" ]]; then
    local zona1; zona1=$(head -1 <<<"$zonas" | cut -f1)
    local axfr; axfr=$(dig "@127.0.0.1" "$zona1" AXFR +time="$DNS_TIMEOUT" +tries=1 2>/dev/null)
    if grep -qE 'Transfer failed|REFUSED|communications error' <<<"$axfr"; then
      verde "bind.q.axfr" "AXFR nao autorizado" "recusado para ${zona1}"
    elif grep -qE "^${zona1}\.?[[:space:]]" <<<"$axfr"; then
      vermelho "bind.q.axfr" "AXFR nao autorizado" "recusado" "zona ${zona1} transferida" \
        "qualquer host baixa sua zona inteira; feche allow-transfer"
    else
      pulado "bind.q.axfr" "AXFR nao autorizado" "resposta inconclusiva"
    fi

    # Serial servido x serial do arquivo. Editar a zona e esquecer o reload e
    # o erro operacional mais comum de DNS — e nenhum check de servico pega.
    local arq1 ser_arq ser_srv
    arq1=$(head -1 <<<"$zonas" | cut -f2)
    ser_arq=$(named-checkzone "$zona1" "$(sysp "$arq1")" 2>/dev/null | grep -oP 'loaded serial\s*\K[0-9]+' | head -1)
    ser_srv=$(_dig_answer "$(_dig 127.0.0.1 "$zona1" SOA)" | awk 'NR==1{print $7}')
    if [[ -z "$ser_arq" || -z "$ser_srv" ]]; then
      pulado "bind.q.serial" "serial servido x arquivo" "serial nao legivel"
    else
      afere "bind.q.serial" "serial servido x arquivo" "$ser_arq" "$ser_srv" \
        "a zona no disco esta a frente do que o named serve: rndc reload ${zona1}"
    fi

    # Autoridade: para a propria zona o named tem de responder com AA.
    r=$(_dig 127.0.0.1 "$zona1" SOA)
    if _dig_tem_flag "$r" aa; then
      verde "bind.q.autoritativa" "resposta autoritativa" "flag AA em ${zona1}"
    else
      vermelho "bind.q.autoritativa" "resposta autoritativa" "flag AA em ${zona1}" \
        "flags: $(_dig_flags "$r")" "o named nao se considera autoritativo pela zona que declara servir"
    fi
  else
    pulado "bind.q.axfr" "AXFR nao autorizado" "sem zona master para testar"
  fi

  # version.bind em CHAOS ignora a diretiva 'version' em configuracao antiga.
  # Este teste pergunta pelo canal que o atacante usa de verdade.
  local vb
  vb=$(dig "@127.0.0.1" version.bind CH TXT +time="$DNS_TIMEOUT" +tries=1 +short 2>/dev/null | tr -d '"')
  if [[ -z "$vb" || "$vb" == "none" ]]; then
    verde "bind.q.version.chaos" "version.bind CHAOS" "nao revela versao"
  elif [[ "$vb" =~ ^9\.[0-9]+ ]]; then
    amarelo "bind.q.version.chaos" "version.bind CHAOS" "mascarada" "$vb" \
      "a versao exata esta publica; declare version \"none\" e recarregue"
  else
    verde "bind.q.version.chaos" "version.bind CHAOS" "mascarada (${vb})"
  fi
}

# =============================================================================
# unbound
# =============================================================================
mod_unbound() {
  hdr unbound
  if ! svc_exists unbound; then
    pulado "unbound.unidade" "unbound instalado" "unidade ausente"
    return 0
  fi
  verde "unbound.unidade" "unbound instalado" "unidade unbound.service"

  afere "unbound.servico" "servico" "active" "$(svc_estado unbound)" \
    "systemctl status unbound; journalctl -u unbound -n 50"

  caso_porta "unbound.porta.udp" "porta 53/udp" udp 53 "confira 'interface:' na config"
  caso_porta "unbound.porta.tcp" "porta 53/tcp" tcp 53 \
    "TCP e obrigatorio; resposta grande depende dele"

  if unbound-checkconf >/dev/null 2>&1; then
    verde "unbound.checkconf" "unbound-checkconf" "sintaxe valida"
  else
    vermelho "unbound.checkconf" "unbound-checkconf" "sintaxe valida" \
      "$(unbound-checkconf 2>&1 | head -1)" "corrija antes do proximo restart"
  fi

  # O check que faltava no v1 e continua sendo o mais importante: sobrescrever
  # /etc/unbound/unbound.conf remove o include de conf.d/ e leva junto a
  # auto-trust-anchor-file. O validator sobe SEM validar nada, sem erro no log,
  # e toda comparacao de performance depois disso fica injusta.
  local ta; ta=$(unbound-checkconf -o auto-trust-anchor-file 2>/dev/null | head -1)
  if [[ -z "$ta" ]]; then
    vermelho "unbound.trustanchor" "trust anchor" "configurada" "AUSENTE" \
      "sem trust anchor o validator sobe e nao valida nada; restaure o include de conf.d/"
  elif [[ -s "${PK_SYSROOT}${ta}" ]]; then
    verde "unbound.trustanchor" "trust anchor" "$ta"
  else
    vermelho "unbound.trustanchor" "trust anchor" "arquivo com conteudo" "vazio: ${ta}" \
      "rode unbound-anchor -a ${ta} e reinicie"
  fi

  # Orcamento de descritores: cada thread abre outgoing-range sockets. Estourar
  # aqui aparece como resolucao intermitente sob carga, nunca como erro claro.
  local orange nthreads need nf
  orange=$(unbound-checkconf -o outgoing-range 2>/dev/null | head -1); [[ "$orange" =~ ^[0-9]+$ ]] || orange=4096
  nthreads=$(unbound-checkconf -o num-threads 2>/dev/null | head -1);  [[ "$nthreads" =~ ^[0-9]+$ ]] || nthreads=1
  need=$(( orange * nthreads ))
  nf=$(nofile_of unbound)
  afere_min "unbound.limitnofile" "LimitNOFILE >= ${orange}x${nthreads}" "$need" "$nf" \
    "systemctl edit unbound -> LimitNOFILE=$((need + 1024))"

  # limits.conf nao vale para unidade systemd. A entrada existe, o operador
  # acha que resolveu, e o limite continua o antigo.
  if sysler /etc/security/limits.conf | grep -q '^unbound.*nofile'; then
    amarelo "unbound.limits.conf" "limits.conf" "sem entrada para unbound" "entrada presente" \
      "systemd ignora limits.conf; o limite real vem de LimitNOFILE na unidade"
  else
    verde "unbound.limits.conf" "limits.conf" "sem entrada enganosa"
  fi

  local ac; ac=$(unbound-checkconf -o access-control 2>/dev/null)
  if grep -qE '0\.0\.0\.0/0[[:space:]]+allow' <<<"$ac"; then
    vermelho "unbound.accesscontrol" "access-control" "sem allow global" "0.0.0.0/0 allow" \
      "RESOLVEDOR ABERTO: restrinja a sua rede antes que vire amplificador"
  else
    verde "unbound.accesscontrol" "access-control" "sem allow global"
  fi

  # qname-minimisation reduz o que cada servidor autoritativo enxerga da sua
  # rede. Custa nada e e default nas versoes novas.
  local qm; qm=$(unbound-checkconf -o qname-minimisation 2>/dev/null | head -1)
  if [[ "$qm" == "no" ]]; then
    amarelo "unbound.qnamemin" "qname-minimisation" "yes" "no" \
      "cada autoritativo ve o nome completo que voce consulta; ligue qname-minimisation"
  else
    verde "unbound.qnamemin" "qname-minimisation" "${qm:-default (yes)}"
  fi

  [[ $DEEP -eq 1 ]] || {
    pulado "unbound.deep" "testes ativos" "use --deep para exercitar o resolvedor"
    return 0
  }

  local r st
  r=$(_dig 127.0.0.1 google.com A)
  st=$(_dig_status "$r")
  if [[ "$st" == "NOERROR" && -n "$(_dig_answer "$r")" ]]; then
    verde "unbound.q.recursiva" "consulta recursiva" "NOERROR com resposta"
  else
    vermelho "unbound.q.recursiva" "consulta recursiva" "NOERROR com resposta" \
      "${st:-sem resposta}" "cheque saida 53 e o estado do cache"
  fi

  r=$(_dig 127.0.0.1 google.com A +tcp)
  afere "unbound.q.tcp" "consulta via TCP" "NOERROR" "$(_dig_status "$r")" \
    "libere 53/tcp; resposta grande depende dele"

  r=$(_dig 127.0.0.1 iana.org A +dnssec)
  if _dig_tem_flag "$r" ad; then
    verde "unbound.q.dnssec.positivo" "DNSSEC valida assinado" "iana.org com flag AD"
  else
    vermelho "unbound.q.dnssec.positivo" "DNSSEC valida assinado" "flag AD" \
      "sem AD (flags: $(_dig_flags "$r"))" "trust anchor ausente ou relogio fora de sincronia"
  fi

  r=$(_dig 127.0.0.1 dnssec-failed.org A)
  afere "unbound.q.dnssec.negativo" "DNSSEC rejeita quebrado" "SERVFAIL" "$(_dig_status "$r")" \
    "NOERROR significa validacao desligada"

  local t0 t1
  t0=$(_ms_agora); _dig 127.0.0.1 example.com A >/dev/null; t1=$(_ms_agora)
  afere_max "unbound.q.latencia" "latencia de cache" "$LAT_BUDGET_MS" "$(( t1 - t0 ))" \
    "resposta de cache lenta indica CPU saturada" WARN
}

# =============================================================================
# zabbix-proxy
# =============================================================================
mod_zabbix_proxy() {
  hdr zabbix-proxy
  if ! svc_exists zabbix-proxy; then
    pulado "zabbix.unidade" "zabbix-proxy instalado" "unidade ausente"
    return 0
  fi
  verde "zabbix.unidade" "zabbix-proxy instalado" "unidade zabbix-proxy.service"
  afere "zabbix.servico" "servico" "active" "$(svc_estado zabbix-proxy)" \
    "journalctl -u zabbix-proxy -n 50"

  local conf=/etc/zabbix/zabbix_proxy.conf
  if system "$conf"; then
    # O arquivo guarda DBPassword em texto claro. 644 significa que qualquer
    # usuario local le a senha do banco.
    local perm; perm=$(stat -c %a "$(sysp "$conf")" 2>/dev/null)
    if [[ "$perm" == "640" || "$perm" == "600" ]]; then
      verde "zabbix.conf.permissao" "permissao do conf" "$perm"
    else
      vermelho "zabbix.conf.permissao" "permissao do conf" "640 ou 600" "${perm:-desconhecida}" \
        "chmod 640 ${conf}; ele contem DBPassword em texto claro"
    fi

    if sysler "$conf" | grep -qE '^ConfigFrequency='; then
      amarelo "zabbix.conf.frequencia" "ConfigFrequency" "ProxyConfigFrequency" "ConfigFrequency (depreciada)" \
        "renomeie para ProxyConfigFrequency; no 7.0 a antiga e ignorada em silencio"
    else
      verde "zabbix.conf.frequencia" "ConfigFrequency" "sem diretiva depreciada"
    fi

    if sysler "$conf" | grep -qE '^Server=127\.0\.0\.1'; then
      amarelo "zabbix.conf.server" "Server" "endereco do servidor central" "127.0.0.1" \
        "o proxy esta apontando para si mesmo; corrija Server="
    else
      verde "zabbix.conf.server" "Server" "aponta para fora do loopback"
    fi
  else
    pulado "zabbix.conf.permissao" "permissao do conf" "${conf} ausente"
  fi

  afere_min "zabbix.limitnofile" "LimitNOFILE" 16384 "$(nofile_of zabbix-proxy)" \
    "'Too many open files' no log do proxy vem daqui" WARN

  # THP transforma alocacao do PostgreSQL em latencia imprevisivel. O proprio
  # projeto recomenda never.
  if svc_exists postgresql; then
    local thp; thp=$(sysler /sys/kernel/mm/transparent_hugepage/enabled | grep -oP '\[\K[a-z]+')
    afere "zabbix.thp" "transparent hugepage" "never" "${thp:-desconhecido}" \
      "echo never > /sys/kernel/mm/transparent_hugepage/enabled e persista no GRUB"
  fi
}

# =============================================================================
# docker
# =============================================================================
mod_docker() {
  hdr docker
  if ! svc_exists docker; then
    pulado "docker.unidade" "docker instalado" "unidade ausente"
    return 0
  fi
  verde "docker.unidade" "docker instalado" "unidade docker.service"
  afere "docker.servico" "servico" "active" "$(svc_estado docker)" "journalctl -u docker -n 50"

  # json-file sem limite cresce ate o disco acabar. E a causa numero um de
  # host cheio com "nao instalei nada".
  if sysler /etc/docker/daemon.json | grep -q 'max-size'; then
    verde "docker.logrotate" "rotacao de log" "max-size configurado"
  else
    vermelho "docker.logrotate" "rotacao de log" "max-size em daemon.json" "sem limite" \
      'defina {"log-driver":"json-file","log-opts":{"max-size":"50m","max-file":"3"}}'
  fi

  afere_min "docker.inotify.instances" "inotify max_user_instances" 1024 \
    "$(sysctl_n fs.inotify.max_user_instances)" \
    "container falha com ENOSPC sem ter disco cheio; suba fs.inotify.max_user_instances"

  afere_min "docker.inotify.watches" "inotify max_user_watches" 524288 \
    "$(sysctl_n fs.inotify.max_user_watches)" \
    "aplicacao com watcher de arquivo trava sem aviso" WARN

  afere "docker.ip_forward" "net.ipv4.ip_forward" "1" "$(sysctl_n net.ipv4.ip_forward)" \
    "sem forwarding a bridge do Docker nao roteia nada para fora"

  if system /proc/sys/net/bridge/bridge-nf-call-iptables; then
    afere "docker.bridge_nf" "bridge-nf-call-iptables" "1" \
      "$(sysctl_n net.bridge.bridge-nf-call-iptables)" \
      "sem isso as regras de publicacao de porta do Docker nao aplicam" WARN
  else
    pulado "docker.bridge_nf" "bridge-nf-call-iptables" "br_netfilter nao carregado"
  fi
}

# =============================================================================
# pve
# =============================================================================
mod_pve() {
  hdr pve
  if ! command -v pveversion >/dev/null 2>&1; then
    pulado "pve.host" "host Proxmox" "pveversion ausente"
    return 0
  fi
  verde "pve.host" "host Proxmox" "$(pveversion 2>/dev/null | head -1 | grep -oP 'pve-manager/\K[^ /]+')"

  local s
  for s in pve-cluster pvedaemon pveproxy pvestatd; do
    afere "pve.servico.${s}" "servico ${s}" "active" "$(svc_estado "$s")" \
      "journalctl -u ${s} -n 50"
  done

  if sysdir /etc/pve/nodes; then
    verde "pve.pmxcfs" "pmxcfs" "/etc/pve montado"
  else
    vermelho "pve.pmxcfs" "pmxcfs" "/etc/pve montado" "vazio" \
      "pmxcfs caido: sem ele nao ha config de VM; systemctl status pve-cluster"
  fi

  local ruins
  ruins=$(pvesm status 2>/dev/null | awk 'NR>1 && $3!="active" && $3!="available" {print $1}' | tr '\n' ' ')
  if [[ -z "${ruins// }" ]]; then
    verde "pve.storages" "storages" "todos ativos"
  else
    vermelho "pve.storages" "storages" "todos ativos" "inativos: ${ruins% }" \
      "backup e migracao falham em storage inativo; pvesm status mostra o motivo"
  fi

  if system /etc/pve/corosync.conf; then
    if pvecm status 2>/dev/null | grep -q 'Quorate:.*Yes'; then
      verde "pve.quorum" "quorum" "presente"
    else
      vermelho "pve.quorum" "quorum" "presente" "SEM QUORUM" \
        "o cluster nao aceita alteracao sem quorum; verifique a rede de corosync"
    fi
  else
    pulado "pve.quorum" "quorum" "host fora de cluster"
  fi
}

# =============================================================================
# SAIDA
# =============================================================================
# Quebra o registro nos campos C_*. Feito em bash puro de proposito: com um
# awk por campo, um host com 60 casos gerava ~500 processos so para imprimir o
# JSON — no Windows do laboratorio isso custava segundos.
C_ID=""; C_SUITE=""; C_ST=""; C_TIT=""; C_ESP=""; C_OBT=""; C_FIX=""; C_MS=0
_split() { # <registro>
  IFS="$US" read -r C_ID C_SUITE C_ST C_TIT C_ESP C_OBT C_FIX C_MS <<<"$1"
}

_veredito() {
  [[ $N_RED -gt 0 ]] && { printf 'FALHA'; return; }
  [[ $N_YELLOW -gt 0 ]] && { printf 'ATENCAO'; return; }
  printf 'OK'
}

_exit_code() {
  [[ $N_RED -gt 0 ]] && { printf 2; return; }
  if [[ $N_YELLOW -gt 0 ]]; then
    [[ $STRICT -eq 1 ]] && printf 2 || printf 1
    return
  fi
  printf 0
}

# Escapador local: validate.sh roda solto no host, sem depender de pkops.sh
# estar instalado. Mesma logica de pk_json_esc — as duas tem teste.
_json_esc() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  s="${s//$'\f'/\\f}"; s="${s//$'\b'/\\b}"
  if [[ "$s" == *[[:cntrl:]]* ]]; then
    local out="" i c
    for (( i=0; i<${#s}; i++ )); do
      c="${s:i:1}"
      [[ "$c" == [[:cntrl:]] ]] && printf -v c '\\u%04x' "'$c"
      out+="$c"
    done
    s="$out"
  fi
  printf '%s' "$s"
}

# Resumo por suite: "suite green red yellow skip ordem" por linha, na ordem em
# que os modulos rodaram (nao alfabetica — o operador le na sequencia da tela).
_resumo_suites() {
  local reg
  for reg in "${CASOS[@]:-}"; do
    [[ -z "$reg" ]] && continue
    _split "$reg"
    printf '%s %s\n' "$C_SUITE" "$C_ST"
  done | awk '
    { g[$1]+=($2=="GREEN"); r[$1]+=($2=="RED"); y[$1]+=($2=="YELLOW"); s[$1]+=($2=="SKIP")
      if (!($1 in ordem)) ordem[$1]=NR }
    END { for (k in g) printf "%s %d %d %d %d %d\n", k, g[k], r[k], y[k], s[k], ordem[k] }
  ' | sort -k6 -n
}

emit_json() {
  local reg first=1
  printf '{"schema":%d,"tool":"%s","version":"%s","host":"%s","ts":"%s","deep":%s,"strict":%s,' \
    "$SCHEMA" "$TOOL" "$VERSION" "$(_json_esc "$(hostname)")" "$(date -Is)" \
    "$([[ $DEEP -eq 1 ]] && echo true || echo false)" \
    "$([[ $STRICT -eq 1 ]] && echo true || echo false)"
  printf '"verdict":"%s","exit":%d,' "$(_veredito)" "$(_exit_code)"
  # summary mantem ok/warn/fail/skip do schema 1: 'pkops fleet' e os itens de
  # Zabbix ja instalados leem essas chaves. Quebrar aqui e quebrar painel de
  # terceiro sem aviso.
  printf '"summary":{"ok":%d,"warn":%d,"fail":%d,"skip":%d,"total":%d,' \
    "$N_GREEN" "$N_YELLOW" "$N_RED" "$N_SKIP" "$(( N_GREEN + N_YELLOW + N_RED + N_SKIP ))"
  printf '"green":%d,"yellow":%d,"red":%d},' "$N_GREEN" "$N_YELLOW" "$N_RED"

  printf '"suites":{'
  local sn sg sr sy ss _o
  while read -r sn sg sr sy ss _o; do
    [[ -z "$sn" ]] && continue
    [[ $first -eq 0 ]] && printf ','; first=0
    local sst=GREEN
    [[ $sy -gt 0 ]] && sst=YELLOW
    [[ $sr -gt 0 ]] && sst=RED
    [[ $((sg+sr+sy)) -eq 0 ]] && sst=SKIP
    printf '"%s":{"status":"%s","green":%d,"red":%d,"yellow":%d,"skip":%d}' \
      "$(_json_esc "$sn")" "$sst" "$sg" "$sr" "$sy" "$ss"
  done < <(_resumo_suites)
  printf '},"checks":['

  first=1
  local sev det
  for reg in "${CASOS[@]:-}"; do
    [[ -z "$reg" ]] && continue
    _split "$reg"
    case "$C_ST" in GREEN) sev=OK ;; RED) sev=FAIL ;; YELLOW) sev=WARN ;; *) sev=SKIP ;; esac
    det="$C_OBT"
    [[ "$C_ST" == "RED" || "$C_ST" == "YELLOW" ]] && det="esperado ${C_ESP}, obtido ${C_OBT}"
    [[ $first -eq 0 ]] && printf ','
    first=0
    printf '{"id":"%s","module":"%s","suite":"%s","status":"%s","severity":"%s","name":"%s",' \
      "$(_json_esc "$C_ID")" "$(_json_esc "$C_SUITE")" "$(_json_esc "$C_SUITE")" \
      "$C_ST" "$sev" "$(_json_esc "$C_TIT")"
    printf '"expected":"%s","actual":"%s","detail":"%s","fix":"%s","ms":%d}' \
      "$(_json_esc "$C_ESP")" "$(_json_esc "$C_OBT")" "$(_json_esc "$det")" \
      "$(_json_esc "$C_FIX")" "${C_MS:-0}"
  done
  printf ']}\n'
}

emit_report() {
  local reg ver; ver=$(_veredito)
  printf '# Validacao de runtime — %s\n\n' "$(hostname)"
  printf '| | |\n|---|---|\n'
  printf '| Gerado em | %s |\n' "$(date -Is)"
  printf '| Ferramenta | %s v%s (schema %d) |\n' "$TOOL" "$VERSION" "$SCHEMA"
  printf '| Camada ativa (--deep) | %s |\n' "$([[ $DEEP -eq 1 ]] && echo sim || echo nao)"
  printf '| Modulos | %s |\n' "${ONLY:-todos}"
  printf '| **Veredito** | **%s** |\n\n' \
    "$(case "$ver" in OK) echo 'OK — nada a fazer' ;; ATENCAO) echo 'NAO OK — com ressalvas' ;; *) echo 'NAO OK — ha falha' ;; esac)"

  printf '## Placar\n\n'
  printf '| GREEN | YELLOW | RED | SKIP |\n|---|---|---|---|\n'
  printf '| %d | %d | %d | %d |\n\n' "$N_GREEN" "$N_YELLOW" "$N_RED" "$N_SKIP"

  printf '## Por modulo\n\n'
  printf '| modulo | situacao | green | yellow | red | skip |\n|---|---|---|---|---|---|\n'
  local sn sg sr sy ss _o sst
  while read -r sn sg sr sy ss _o; do
    [[ -z "$sn" ]] && continue
    sst='GREEN'; [[ $sy -gt 0 ]] && sst='YELLOW'; [[ $sr -gt 0 ]] && sst='RED'
    [[ $((sg+sr+sy)) -eq 0 ]] && sst='nao se aplica'
    printf '| %s | %s | %d | %d | %d | %d |\n' "$sn" "$sst" "$sg" "$sy" "$sr" "$ss"
  done < <(_resumo_suites)
  printf '\n'

  local nivel titulo
  for nivel in RED YELLOW; do
    [[ "$nivel" == RED ]] && titulo='Falhas (RED) — exigem acao' || titulo='Ressalvas (YELLOW)'
    local achou=0
    for reg in "${CASOS[@]:-}"; do
      [[ -z "$reg" ]] && continue
      _split "$reg"
      [[ "$C_ST" == "$nivel" ]] || continue
      if [[ $achou -eq 0 ]]; then
        printf '## %s\n\n' "$titulo"
        printf '| id | verificacao | esperado | obtido | o que fazer |\n|---|---|---|---|---|\n'
        achou=1
      fi
      printf '| `%s` | %s | %s | %s | %s |\n' \
        "$C_ID" "$C_TIT" "${C_ESP//|/\\|}" "${C_OBT//|/\\|}" "${C_FIX//|/\\|}"
    done
    [[ $achou -eq 1 ]] && printf '\n'
  done

  printf '## Todos os casos\n\n'
  printf '| id | modulo | situacao | verificacao | obtido |\n|---|---|---|---|---|\n'
  for reg in "${CASOS[@]:-}"; do
    [[ -z "$reg" ]] && continue
    _split "$reg"
    printf '| `%s` | %s | %s | %s | %s |\n' "$C_ID" "$C_SUITE" "$C_ST" "$C_TIT" "${C_OBT//|/\\|}"
  done
  printf '\n_Gerado por %s v%s. Reproduza com: `validate.sh%s --report`_\n' \
    "$TOOL" "$VERSION" "$([[ $DEEP -eq 1 ]] && echo ' --deep')"
}

main() {
  _MS_ANT=$(_ms_agora)
  if [[ $HUMANO -eq 1 ]]; then
    echo "${C_B}=========================================${C_0}"
    echo "  validate.sh v${VERSION} — $(hostname)"
    echo "  camada: $([[ $DEEP -eq 1 ]] && echo 'passiva + ATIVA (--deep)' || echo 'passiva')"
    echo "${C_B}=========================================${C_0}"
  fi

  want core         && mod_core
  want tuning       && mod_tuning
  want bind         && mod_bind
  want unbound      && mod_unbound
  want zabbix-proxy && mod_zabbix_proxy
  want docker       && mod_docker
  want pve          && mod_pve

  if   [[ $JSON   -eq 1 ]]; then emit_json
  elif [[ $REPORT -eq 1 ]]; then emit_report
  else
    echo
    echo "${C_B}=========================================${C_0}"
    printf '  %sGREEN %d%s  %sYELLOW %d%s  %sRED %d%s  (skip %d)\n' \
      "$C_G" "$N_GREEN" "$C_0" "$C_Y" "$N_YELLOW" "$C_0" "$C_R" "$N_RED" "$C_0" "$N_SKIP"
    printf '  veredito: %s\n' "$(_veredito)"
    [[ $DEEP -eq 0 ]] && printf '  %s(camada ativa nao rodou — use --deep para testar os servicos)%s\n' "$C_D" "$C_0"
    echo "${C_B}=========================================${C_0}"
  fi

  exit "$(_exit_code)"
}

main "$@"
