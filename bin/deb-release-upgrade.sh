#!/usr/bin/env bash
# =============================================================================
# deb-release-upgrade.sh — v1.0
# Upgrade de release do Debian, UM SALTO por execucao.
#
# POR QUE ESTE SCRIPT EXISTE
# Trocar o codename com sed nao basta. Uma release arquivada vive em
# archive.debian.org; a proxima vive em deb.debian.org. Um
# 's/bullseye/bookworm/' produz "archive.debian.org/debian bookworm", que
# nao existe — e o apt update falha depois que voce ja mexeu no sources.list.
#
# Este script resolve o HOST correto por sondagem, nao por tabela.
#
# ORDEM (procedimento oficial do Debian)
#   1. atualiza completamente a release atual
#   2. reescreve sources.list com host + suite corretos
#   3. apt update  (rollback automatico se falhar)
#   4. upgrade --without-new-pkgs   (minimal)
#   5. full-upgrade                  (completo)
#   6. autoremove
#
# Uso:
#   ./deb-release-upgrade.sh --dry-run
#   ./deb-release-upgrade.sh                 # salta para a proxima release
#   ./deb-release-upgrade.sh --to bookworm   # explicito
#   ./deb-release-upgrade.sh --rollback      # restaura o sources.list
# =============================================================================
set -uo pipefail

TOOL="deb-release-upgrade"; VERSION="1.0"
[[ -f /usr/local/lib/pkops.sh ]] && . /usr/local/lib/pkops.sh && pk_init 2>/dev/null || true

DRY=0; TO=""; ROLLBACK=0; YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY=1 ;;
    --to)       shift; TO="${1:-}" ;;
    --to=*)     TO="${1#--to=}" ;;
    --rollback) ROLLBACK=1 ;;
    --yes|-y)   YES=1 ;;
    -h|--help)  sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "flag desconhecida: $1  (use --help)"; exit 2 ;;
  esac
  shift
done

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_D=$'\e[2m'; C_0=$'\e[0m'
[[ -t 1 ]] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""; }
ok()   { printf '  %sOK%s   %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!!%s   %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '  %sXX%s   %s\n' "$C_R" "$C_0" "$*"; }
info() { printf '  %s::%s   %s\n' "$C_B" "$C_0" "$*"; }
h1()   { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
die()  { err "$*"; exit 1; }
run()  { [[ $DRY -eq 1 ]] && { printf '  %s[dry]%s %s\n' "$C_Y" "$C_0" "$*"; return 0; }; "$@"; }

[[ $EUID -eq 0 ]] || die "execute como root"

# curl e o que resolve o host por sondagem. Sem ele, TODA sondagem falha em
# silencio e o script morre dizendo que a release nao existe em lugar nenhum —
# erro que manda voce investigar mirror, DNS e firewall quando o problema e
# um pacote ausente.
command -v curl >/dev/null 2>&1 || die "curl nao instalado — apt-get install -y curl"

# Host Proxmox tem caminho proprio. Este script reescreve o sources.list com
# repositorios Debian puros e nao sabe nada de ordem de upgrade do PVE, ceph
# ou cluster. Rodar aqui e o jeito rapido de quebrar o apt de um hipervisor.
if command -v pveversion >/dev/null 2>&1 && [[ ${FORCE_PVE:-0} -eq 0 ]]; then
  err "host Proxmox VE detectado ($(pveversion 2>/dev/null | head -1))"
  err "  para PVE use:  pve-upgrade.sh --assess   (trata repos, ceph e ordem)"
  err "  se souber o que esta fazendo:  FORCE_PVE=1 $(basename "$0") ..."
  exit 2
fi

SRC=/etc/apt/sources.list
BAK_DIR=/var/backups/deb-release-upgrade
SEQ=(stretch buster bullseye bookworm trixie forky)
num() { local i; for i in "${!SEQ[@]}"; do [[ "${SEQ[$i]}" == "$1" ]] && { echo $((i+9)); return; }; done; echo 0; }

CUR=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
[[ -z "$CUR" ]] && die "nao consegui detectar o codename atual"
CN=$(num "$CUR")
[[ $CN -eq 0 ]] && die "codename '$CUR' fora da sequencia conhecida"

# ---------------------------------------------------------------- rollback
if [[ $ROLLBACK -eq 1 ]]; then
  h1 "Rollback do sources.list"
  ULT=$(ls -1t "$BAK_DIR"/sources.list.* 2>/dev/null | head -1)
  [[ -z "$ULT" ]] && die "nenhum backup em $BAK_DIR"
  info "restaurando de: $ULT"
  run cp -a "$ULT" "$SRC"
  run apt-get update -qq
  ok "sources.list restaurado"
  warn "se o dist-upgrade ja rodou, o rollback do SISTEMA e o snapshot da VM"
  exit 0
fi

# ---------------------------------------------------------------- alvo
[[ -z "$TO" ]] && TO="${SEQ[$(( CN - 9 + 1 ))]:-}"
[[ -z "$TO" ]] && die "$CUR ja e a ultima release conhecida"
TN=$(num "$TO")
[[ $TN -eq 0 ]] && die "codename alvo desconhecido: $TO"
[[ $TN -le $CN ]] && die "$TO nao e mais novo que $CUR (downgrade nao suportado)"
if [[ $(( TN - CN )) -gt 1 ]]; then
  PROX="${SEQ[$(( CN - 9 + 1 ))]}"
  err "salto de $(( TN - CN )) releases — o Debian suporta apenas N -> N+1"
  err "  rode primeiro:  $(basename "$0") --to $PROX"
  exit 2
fi

h1 "Upgrade $CUR -> $TO"

# ---------------------------------------------------------------- hosts
DEB_LIVE="http://deb.debian.org/debian"
DEB_ARCH="http://archive.debian.org/debian"
SEC_LIVE="http://security.debian.org/debian-security"
SEC_ARCH="http://archive.debian.org/debian-security"

_probe() { curl -sfI --max-time 8 "${1%/}/dists/${2}/Release" >/dev/null 2>&1; }
sec_suite() { [[ $(num "$1") -ge 11 ]] && echo "${1}-security" || echo "${1}/updates"; }

# Resolve por SONDAGEM. Tabela fixa envelhece: bullseye migra para o
# archive em 31/08/2026, bookworm em 2028, e assim por diante.
resolve() {
  local cn="$1"
  _probe "$DEB_LIVE" "$cn" && { echo "${DEB_LIVE}|live"; return 0; }
  _probe "$DEB_ARCH" "$cn" && { echo "${DEB_ARCH}|archive"; return 0; }
  echo "|nenhum"; return 1
}
resolve_sec() {
  local su; su=$(sec_suite "$1")
  _probe "$SEC_LIVE" "$su" && { echo "${SEC_LIVE}|live"; return 0; }
  _probe "$SEC_ARCH" "$su" && { echo "${SEC_ARCH}|archive"; return 0; }
  echo "|nenhum"; return 1
}

info "resolvendo onde $TO esta hospedado..."
IFS='|' read -r URL ONDE     <<<"$(resolve "$TO")"
IFS='|' read -r SURL SONDE   <<<"$(resolve_sec "$TO")"
IFS='|' read -r CURL CONDE   <<<"$(resolve "$CUR")"

[[ "$ONDE" == "nenhum" ]] && die "$TO nao encontrado em deb.debian.org nem archive.debian.org"
ok "$TO -> $URL ($ONDE)"
[[ "$SONDE" == "nenhum" ]] && warn "security de $TO indisponivel" || ok "security -> $SURL ($(sec_suite "$TO"))"
info "$CUR esta em $CONDE"

if [[ "$CONDE" != "$ONDE" ]]; then
  warn "MUDANCA DE HOST: $CONDE -> $ONDE"
  warn "  um sed no codename NAO resolveria isto"
fi

COMP="main contrib non-free"
[[ $TN -ge 12 ]] && COMP="main contrib non-free non-free-firmware"
[[ $TN -ge 12 && $CN -lt 12 ]] && info "componente 'non-free-firmware' adicionado (novo no Debian 12)"

# ---------------------------------------------------------------- preflight
h1 "Preflight"
FREE=$(df -BM --output=avail / | tail -1 | tr -dc '0-9')
[[ ${FREE:-0} -lt 3000 ]] && die "apenas ${FREE}MB livres em / (minimo 3000MB)"
ok "${FREE}MB livres em /"

HOLD=$(apt-mark showhold 2>/dev/null)
[[ -n "$HOLD" ]] && { warn "pacotes em hold:"; echo "$HOLD" | sed 's/^/       /'; \
  warn "  liberar: apt-mark unhold <pacote>"; } || ok "nenhum pacote em hold"

dpkg -l 2>/dev/null | grep -q '^i[^i]' && \
  die "dpkg inconsistente — rode: dpkg --configure -a && apt -f install" || ok "dpkg consistente"

if [[ -n "${SSH_CONNECTION:-}" ]] && [[ -z "${TMUX:-}${STY:-}" ]]; then
  warn "SSH sem tmux/screen — queda de conexao aborta o dist-upgrade"
  warn "  recomendado: tmux new -s upg"
fi

# repos de terceiro que nao publicam para o alvo
h1 "Repositorios de terceiro"
BLOQ=0
for f in /etc/apt/sources.list.d/*.list; do
  [[ -f "$f" ]] || continue
  while read -r _ uri suite _; do
    [[ "$uri" =~ ^\[ ]] && continue
    [[ -z "${suite:-}" ]] && continue
    host=$(sed -E 's#^[a-z]+://##; s#/.*$##' <<<"$uri")
    [[ "$host" == *debian.org ]] && continue
    novo="${suite//$CUR/$TO}"
    if _probe "$uri" "$novo"; then
      ok "$(basename "$f"): $novo"
    else
      err "$(basename "$f"): NAO publica para $novo"
      err "   $uri"
      BLOQ=$((BLOQ+1))
    fi
  done < <(grep -hE '^[[:space:]]*deb[[:space:]]' "$f" 2>/dev/null)
done
[[ $BLOQ -gt 0 ]] && {
  err "$BLOQ repositorio(s) sem pacotes para $TO"
  err "  desabilite-os ou aguarde o mantenedor. Abortando."
  exit 2
}

# ---------------------------------------------------------------- confirma
h1 "Resumo"
printf '  %-14s %s -> %s\n' "release"     "$CUR" "$TO"
printf '  %-14s %s -> %s\n' "host"        "$CONDE" "$ONDE"
printf '  %-14s %s\n'       "componentes" "$COMP"
printf '  %-14s %s\n'       "security"    "$(sec_suite "$TO")"
[[ "$ONDE" == "archive" ]] && printf '  %-14s %s\n' "atencao" "alvo ARQUIVADO: sem -updates, Release expirado"

if [[ $DRY -eq 0 && $YES -eq 0 ]]; then
  echo
  read -rp "  >> confirme digitando o codename alvo ('${TO}'): " R </dev/tty
  [[ "$R" == "$TO" ]] || die "confirmacao invalida"
fi

# ---------------------------------------------------------------- 1. atualiza a atual
h1 "1/5 Atualizando completamente $CUR"
run apt-get update -qq || warn "apt update com avisos"
if [[ $DRY -eq 0 ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    full-upgrade || die "full-upgrade da release atual falhou"
  DEBIAN_FRONTEND=noninteractive apt-get -y --purge autoremove
fi
ok "$CUR atualizada"

# ---------------------------------------------------------------- 2. sources
h1 "2/5 Reescrevendo sources.list"
run mkdir -p "$BAK_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
[[ $DRY -eq 0 ]] && cp -a "$SRC" "${BAK_DIR}/sources.list.${STAMP}"
info "backup: ${BAK_DIR}/sources.list.${STAMP}"

NOVO=$(mktemp)
{
  printf '# gerado por %s v%s em %s\n' "$TOOL" "$VERSION" "$(date -Is)"
  printf '# %s -> %s   (host: %s)\n\n' "$CUR" "$TO" "$ONDE"
  printf 'deb %s %s %s\n' "$URL" "$TO" "$COMP"
  [[ "$SONDE" != "nenhum" ]] && printf 'deb %s %s %s\n' "$SURL" "$(sec_suite "$TO")" "$COMP"
  if [[ "$ONDE" == "live" ]]; then
    printf 'deb %s %s-updates %s\n' "$URL" "$TO" "$COMP"
  else
    printf '\n# %s-updates nao existe no archive\n' "$TO"
  fi
} > "$NOVO"

printf '%s\n' "$(sed 's/^/     /' "$NOVO")"

if [[ $DRY -eq 0 ]]; then
  install -m 0644 "$NOVO" "$SRC"
  # Release do archive vem expirado; sem isto o apt recusa
  if [[ "$ONDE" == "archive" ]]; then
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
    ok "Check-Valid-Until desabilitado (necessario no archive)"
  fi
  # terceiros: so o codename muda (o host deles e proprio)
  for f in /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    grep -q "$CUR" "$f" 2>/dev/null || continue
    cp -a "$f" "${BAK_DIR}/$(basename "$f").${STAMP}"
    sed -i "s/\b${CUR}\b/${TO}/g" "$f"
    ok "$(basename "$f") migrado"
  done
  # deb822 tambem — o system_config.sh esquece deste
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    grep -q "$CUR" "$f" 2>/dev/null || continue
    cp -a "$f" "${BAK_DIR}/$(basename "$f").${STAMP}"
    sed -i "s/\b${CUR}\b/${TO}/g" "$f"
    ok "$(basename "$f") migrado (deb822)"
  done
  # backports nao sobrevivem a upgrade de release
  for f in "$SRC" /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    grep -qE '^[^#].*backports' "$f" 2>/dev/null || continue
    sed -i -E 's|^([^#].*backports.*)$|# [upgrade] \1|' "$f"
    warn "backports comentado em $(basename "$f")"
  done
fi
rm -f "$NOVO"

# ---------------------------------------------------------------- 3. apt update
h1 "3/5 apt update (rollback automatico se falhar)"
if [[ $DRY -eq 0 ]]; then
  if ! OUT=$(apt-get update 2>&1); then
    err "apt update FALHOU — restaurando sources.list"
    echo "$OUT" | grep -iE '^(E|W):' | head -8 | sed 's/^/     /'
    cp -a "${BAK_DIR}/sources.list.${STAMP}" "$SRC"
    apt-get update -qq 2>/dev/null || true
    die "nada foi instalado; sources.list restaurado"
  fi
fi
ok "apt update validado"

# ---------------------------------------------------------------- 4-5. upgrade
DPKG=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

h1 "4/5 upgrade minimal (--without-new-pkgs)"
if [[ $DRY -eq 0 ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get -y "${DPKG[@]}" upgrade --without-new-pkgs \
    || { err "upgrade minimal falhou"; err "  tente: apt -f install  e reexecute"; exit 1; }
fi
ok "minimal concluido"

h1 "5/5 full-upgrade"
if [[ $DRY -eq 0 ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get -y "${DPKG[@]}" full-upgrade \
    || { err "full-upgrade falhou"; err "  tente: apt -f install  e reexecute"; exit 1; }
  DEBIAN_FRONTEND=noninteractive apt-get -y --purge autoremove
fi
ok "full-upgrade concluido"

# ---------------------------------------------------------------- pos
h1 "Verificacao"
NOVO_CN=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-?}")
[[ "$NOVO_CN" == "$TO" ]] && ok "sistema agora em $NOVO_CN" \
                          || warn "codename pos-upgrade: $NOVO_CN (esperado $TO)"

PEND=$(find /etc \( -name '*.dpkg-dist' -o -name '*.dpkg-new' \) 2>/dev/null | head -10)
[[ -n "$PEND" ]] && { warn "conffiles novos (sua versao foi mantida):"; echo "$PEND" | sed 's/^/       /'; }

if [[ $TN -ge 13 ]]; then
  [[ -s /etc/sysctl.conf ]] && grep -qE '^[^#]' /etc/sysctl.conf && \
    warn "/etc/sysctl.conf tem conteudo ativo e NAO e lido no Debian 13 — mova para /etc/sysctl.d/"
  RAM=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
  [[ $RAM -lt 4096 ]] && warn "/tmp virou tmpfs (ate $((RAM/2))MB) — systemctl edit tmp.mount -> Options=size=1G"
fi

if declare -f pk_state_set >/dev/null 2>&1 && [[ $DRY -eq 0 ]]; then
  pk_state_set release "codename=${NOVO_CN}" "de=${CUR}" "host=${ONDE}" >/dev/null 2>&1
  pk_emit "release.upgraded" "${CUR} -> ${NOVO_CN}" >/dev/null 2>&1
fi

h1 "Proximo passo"
PROX="${SEQ[$(( TN - 9 + 1 ))]:-}"
cat <<EOF
  1. reboot
  2. validate.sh
  3. tune-profile.sh --profile <perfil>     # kernel novo = chaves diferentes
EOF
[[ -n "$PROX" ]] && printf '  4. para seguir ao %s:  %s --to %s\n' "$PROX" "$(basename "$0")" "$PROX"
printf '\n  rollback do sources.list:  %s --rollback\n' "$(basename "$0")"
printf '  rollback do sistema:       snapshot da VM no host Proxmox\n'
[[ $DRY -eq 1 ]] && warn "foi DRY-RUN — nada mudou"
