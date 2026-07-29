#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — instalacao remota do pkinfra-toolkit
#
# Este e o arquivo que a frota executa. Ele baixa o release, confere
# integridade e delega para o install.sh de dentro do pacote.
#
#   curl -fsSL https://raw.githubusercontent.com/pkthegod/pkinfra-toolkit/main/bootstrap.sh | sudo bash
#   curl -fsSL ...bootstrap.sh | sudo bash -s -- --dry-run
#   curl -fsSL ...bootstrap.sh | sudo bash -s -- --version 2026.07.29 --all
#
# Flags proprias (as demais passam direto para o install.sh):
#   --version <v>   instala versao especifica (default: ultimo release)
#   --sha256 <h>    exige este digest no tarball — use em producao
#   --keep          nao apaga o diretorio temporario
#
# SOBRE CONFIANCA
#   O .sha256 publicado ao lado do tarball so protege contra download
#   corrompido: quem controlasse o release controlaria os dois. Para
#   integridade de verdade, fixe o digest com --sha256 (o valor sai do
#   `build.sh` local, ou do log do CI que montou o release).
# =============================================================================
set -euo pipefail

REPO="${PKINFRA_REPO:-pkthegod/pkinfra-toolkit}"
VERSAO=""
SHA_ESPERADO=""
KEEP=0
PASSTHRU=()

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
[[ -t 1 ]] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; }
ok()   { printf '  %sOK%s   %s\n' "$C_G" "$C_0" "$*"; }
info() { printf '  %s::%s   %s\n' "$C_B" "$C_0" "$*"; }
warn() { printf '  %s!!%s   %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '  %sXX%s   %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSAO="${2:?--version exige valor}"; shift 2 ;;
    --sha256)  SHA_ESPERADO="${2:?--sha256 exige valor}"; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) sed -n '2,26p' "$0" 2>/dev/null || echo "veja ${REPO}"; exit 0 ;;
    *) PASSTHRU+=("$1"); shift ;;
  esac
done

[[ $EUID -eq 0 ]] || die "execute como root (use sudo)"

for dep in tar sha256sum; do
  command -v "$dep" >/dev/null 2>&1 || die "dependencia ausente: ${dep}"
done

if command -v curl >/dev/null 2>&1; then
  baixar() { curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"; }
  ler()    { curl -fsSL --retry 3 --retry-delay 2 "$1"; }
elif command -v wget >/dev/null 2>&1; then
  baixar() { wget -q -t 3 -O "$2" "$1"; }
  ler()    { wget -q -t 3 -O - "$1"; }
else
  die "nem curl nem wget disponiveis"
fi

printf '\n%s== pkinfra-toolkit ==%s\n' "$C_B" "$C_0"

# --- descobre a versao -------------------------------------------------------
if [[ -z "$VERSAO" ]]; then
  info "consultando ultimo release de ${REPO}"
  TAG=$(ler "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/') || true
  [[ -n "${TAG:-}" ]] || die "nenhum release publicado em ${REPO} (ou API inacessivel) — use --version"
  VERSAO="${TAG#v}"
else
  TAG="v${VERSAO#v}"
  VERSAO="${TAG#v}"
fi
ok "versao alvo: ${VERSAO}"

PACOTE="pkinfra-toolkit-${VERSAO}.tar.gz"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

TMP="$(mktemp -d)"
if [[ $KEEP -eq 0 ]]; then
  trap 'rm -rf "$TMP"' EXIT
else
  trap 'printf "  temporario preservado em %s\n" "$TMP"' EXIT
fi

# --- baixa -------------------------------------------------------------------
info "baixando ${PACOTE}"
baixar "${BASE}/${PACOTE}" "${TMP}/${PACOTE}" \
  || die "download falhou: ${BASE}/${PACOTE}"

DIGEST=$(sha256sum "${TMP}/${PACOTE}" | cut -d' ' -f1)

if [[ -n "$SHA_ESPERADO" ]]; then
  [[ "$DIGEST" == "$SHA_ESPERADO" ]] \
    || die "digest NAO confere — esperado ${SHA_ESPERADO}, obtido ${DIGEST}"
  ok "digest confere com o valor fixado"
elif baixar "${BASE}/${PACOTE}.sha256" "${TMP}/publicado.sha256" 2>/dev/null; then
  PUB=$(cut -d' ' -f1 < "${TMP}/publicado.sha256")
  [[ "$DIGEST" == "$PUB" ]] || die "digest divergente do publicado — download corrompido"
  ok "digest bate com o publicado (${DIGEST:0:16}...)"
else
  warn "sem .sha256 publicado — seguindo sem verificar o envelope"
fi

# --- extrai e confere o conteudo ---------------------------------------------
tar xzf "${TMP}/${PACOTE}" -C "$TMP" || die "tarball corrompido"
SRC="${TMP}/pkinfra-toolkit-${VERSAO}"
[[ -d "$SRC" ]] || die "estrutura inesperada dentro do tarball"

if [[ -f "${SRC}/CHECKSUMS.sha256" ]]; then
  ( cd "$SRC" && sha256sum -c --quiet CHECKSUMS.sha256 ) \
    || die "conteudo do pacote nao confere com CHECKSUMS.sha256"
  ok "conteudo integro"
else
  warn "pacote sem CHECKSUMS.sha256"
fi

[[ -x "${SRC}/install.sh" ]] || chmod +x "${SRC}/install.sh" 2>/dev/null || true
[[ -f "${SRC}/install.sh" ]] || die "install.sh ausente no pacote"

# --- delega ------------------------------------------------------------------
info "executando install.sh ${PASSTHRU[*]:-}"
cd "$SRC"
# ${arr[@]+"${arr[@]}"} — sob `set -u`, um array vazio nao pode virar
# argumento "" ; o install.sh rejeitaria como flag desconhecida.
exec ./install.sh ${PASSTHRU[@]+"${PASSTHRU[@]}"}
