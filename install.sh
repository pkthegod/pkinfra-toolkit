#!/usr/bin/env bash
# =============================================================================
# install.sh — instalador do pkinfra-toolkit
# Idempotente: rodar duas vezes = rodar uma vez.
#
#   ./install.sh --dry-run     mostra o que faria
#   ./install.sh               instala conforme o papel detectado
#   ./install.sh --all         instala tudo, independente do papel
#   ./install.sh --uninstall   remove binarios (PRESERVA /var/lib/pkops)
# =============================================================================
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDIR=/usr/local/sbin
LIBDIR=/usr/local/lib
HOOKDIR=/etc/pkops/hooks.d
DOCDIR=/usr/local/share/pkinfra

DRY=0; ALL=0; UNINSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY=1 ;;
    --all)       ALL=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "flag desconhecida: $1"; exit 2 ;;
  esac
  shift
done

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
[[ -t 1 ]] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; }
ok()   { printf '  %sOK%s   %s\n'   "$C_G" "$C_0" "$*"; }
info() { printf '  %s::%s   %s\n'   "$C_B" "$C_0" "$*"; }
warn() { printf '  %s!!%s   %s\n'   "$C_Y" "$C_0" "$*"; }
err()  { printf '  %sXX%s   %s\n'   "$C_R" "$C_0" "$*"; }
head1(){ printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

run() { [[ $DRY -eq 1 ]] && { printf '  %s[dry]%s %s\n' "$C_Y" "$C_0" "$*"; return 0; }; "$@"; }

[[ $EUID -eq 0 ]] || { err "execute como root"; exit 1; }

# --- desinstalacao -----------------------------------------------------------
if [[ $UNINSTALL -eq 1 ]]; then
  head1 "Desinstalando"
  for f in pkassess.sh pve-upgrade.sh proxmox_tune.sh tune-profile.sh setup-unbound.sh validate.sh pkops; do
    [[ -e "${BINDIR}/${f}" ]] && { run rm -f "${BINDIR}/${f}"; ok "removido ${BINDIR}/${f}"; }
  done
  [[ -e "${LIBDIR}/pkops.sh" ]] && { run rm -f "${LIBDIR}/pkops.sh"; ok "removido ${LIBDIR}/pkops.sh"; }
  warn "PRESERVADOS: /var/lib/pkops (estado, eventos, manifest) e ${HOOKDIR}"
  warn "apague a mao se realmente quiser perder o historico"
  exit 0
fi

# --- deteccao do papel -------------------------------------------------------
head1 "Detectando papel do host"
IS_PVE=0; IS_LXC=0
command -v pveversion >/dev/null 2>&1 && IS_PVE=1
[[ "$(systemd-detect-virt --container 2>/dev/null)" == "lxc" ]] && IS_LXC=1
VIRT=$(systemd-detect-virt 2>/dev/null || echo none)
CODENAME=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-?}")

info "Debian ${CODENAME} | kernel $(uname -r) | virt=${VIRT}"
if [[ $IS_PVE -eq 1 ]]; then
  info "papel: HOST PROXMOX VE ($(pveversion 2>/dev/null | head -1 | grep -oP 'pve-manager/\K[^ /]+'))"
elif [[ $IS_LXC -eq 1 ]]; then
  info "papel: container LXC"
  warn "chaves vm.*, fs.inotify.* e kernel.* sao GLOBAIS — tuning vai no host"
else
  info "papel: guest / bare-metal"
fi

# --- o que instalar ----------------------------------------------------------
INSTALL_LIST=(pkassess.sh tune-profile.sh setup-unbound.sh validate.sh)
if [[ $IS_PVE -eq 1 || $ALL -eq 1 ]]; then
  INSTALL_LIST+=(pve-upgrade.sh proxmox_tune.sh)
fi

head1 "Instalando"
run install -d -m 0755 "$BINDIR" "$LIBDIR" "$HOOKDIR" "$DOCDIR"

# biblioteca primeiro: os demais dependem dela
if [[ -f "${SRC}/lib/pkops.sh" ]]; then
  run install -m 0755 "${SRC}/lib/pkops.sh" "${LIBDIR}/pkops.sh"
  run ln -sf "${LIBDIR}/pkops.sh" "${BINDIR}/pkops"
  ok "pkops.sh -> ${LIBDIR}/  (CLI: ${BINDIR}/pkops)"
fi

for f in "${INSTALL_LIST[@]}"; do
  if [[ -f "${SRC}/bin/${f}" ]]; then
    run install -m 0755 "${SRC}/bin/${f}" "${BINDIR}/${f}"
    ok "${f}"
  else
    warn "${f} nao encontrado no pacote"
  fi
done

# nao sobrescreve hook ja ativo do operador
if [[ -d "${SRC}/hooks.d" ]]; then
  for h in "${SRC}"/hooks.d/*; do
    [[ -f "$h" ]] || continue
    b=$(basename "$h")
    if [[ -e "${HOOKDIR}/${b%.example}" ]]; then
      info "hook ${b%.example} ja existe — preservado"
    else
      run install -m 0644 "$h" "${HOOKDIR}/${b}"
    fi
  done
  ok "exemplos de hook em ${HOOKDIR}"
fi

for d in TOOLKIT RUNBOOK; do
  [[ -f "${SRC}/docs/${d}.md" ]] && { run install -m 0644 "${SRC}/docs/${d}.md" "${DOCDIR}/"; ok "${d}.md -> ${DOCDIR}/"; }
done
[[ -f "${SRC}/README.md" ]]       && run install -m 0644 "${SRC}/README.md" "${DOCDIR}/"

# --- inicializa a camada de estado -------------------------------------------
if [[ $DRY -eq 0 && -f "${LIBDIR}/pkops.sh" ]]; then
  head1 "Estado"
  TOOL="install"; VERSION="1.0"
  # shellcheck source=/dev/null
  . "${LIBDIR}/pkops.sh"
  pk_init && ok "/var/lib/pkops inicializado (migra diretorios legados)"
  pk_facts && ok "fatos de hardware coletados"
  pk_emit "toolkit.installed" "papel=$([[ $IS_PVE -eq 1 ]] && echo pve || echo guest) itens=${#INSTALL_LIST[@]}"
fi

head1 "Proximos passos"
if [[ $IS_PVE -eq 1 ]]; then
  cat <<EOF
  1. pkassess.sh --full               # levantamento + benchmark + prescricao
  2. siga a PRESCRICAO que ele imprimir
  3. tmux new -s upg                  # antes de qualquer upgrade
  4. pkops manifest                  # registra o estado
EOF
else
  cat <<EOF
  1. pkassess.sh --full               # levantamento + benchmark + prescricao
  2. siga a PRESCRICAO que ele imprimir
  3. validate.sh
  4. pkops manifest
EOF
fi
cat <<EOF

  Roteiro passo a passo: ${DOCDIR}/RUNBOOK.md
  Referencia completa   : ${DOCDIR}/TOOLKIT.md
  Ativar um callback  : mv ${HOOKDIR}/30-git.sh.example ${HOOKDIR}/30-git.sh
                        chmod +x ${HOOKDIR}/30-git.sh
EOF
[[ $DRY -eq 1 ]] && warn "foi DRY-RUN — nada foi instalado"
exit 0
