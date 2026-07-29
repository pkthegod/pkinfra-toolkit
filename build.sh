#!/usr/bin/env bash
# =============================================================================
# build.sh — monta o tarball de release do pkinfra-toolkit
#
# Reproduzivel de proposito: uid/gid/mtime fixos e gzip sem timestamp. Dois
# builds da mesma arvore geram bytes identicos, entao o sha256 do release
# pode ser conferido por qualquer um que tenha o codigo.
#
#   ./build.sh                    gera dist/pkinfra-toolkit-<versao>.tar.gz
#   ./build.sh --outdir /tmp/x    escolhe onde escrever
# =============================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${RAIZ}/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --outdir) OUTDIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "flag desconhecida: $1" >&2; exit 2 ;;
  esac
done

VERSION="$(tr -d ' \t\r\n' < "${RAIZ}/VERSION")"
[[ -n "$VERSION" ]] || { echo "VERSION vazio" >&2; exit 1; }

PREFIXO="pkinfra-toolkit-${VERSION}"
# mtime deriva da propria versao (YYYY.MM.DD) — nada de 'agora', senao o
# build deixa de ser reproduzivel.
MTIME="${VERSION//./-} 00:00:00Z"

# arquivos que compoem o pacote. bootstrap.sh e build.sh ficam DE FORA:
# vivem no repo, nao no artefato.
CONTEUDO=(
  install.sh
  README.md
  lib/pkops.sh
  bin/pkassess.sh
  bin/pve-upgrade.sh
  bin/proxmox_tune.sh
  bin/tune-profile.sh
  bin/setup-unbound.sh
  bin/validate.sh
  docs/TOOLKIT.md
  docs/RUNBOOK.md
  hooks.d/10-jsonl.sh.example
  hooks.d/20-zabbix.sh.example
  hooks.d/30-git.sh.example
  hooks.d/40-alerta.sh.example
)

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="${STAGE}/${PREFIXO}"

for f in "${CONTEUDO[@]}"; do
  [[ -f "${RAIZ}/${f}" ]] || { echo "faltando no repo: ${f}" >&2; exit 1; }
  mkdir -p "${DEST}/$(dirname "$f")"
  cp "${RAIZ}/${f}" "${DEST}/${f}"
done

# normaliza line-ending: o repo pode estar num checkout Windows. CRLF no
# shebang faz o Linux responder "no such file or directory" e ninguem
# entende porque.
while IFS= read -r -d '' f; do
  case "$f" in
    *.sh|*.example) printf '%s' "$(tr -d '\r' < "$f")" > "${f}.tmp" && printf '\n' >> "${f}.tmp" && mv "${f}.tmp" "$f" ;;
  esac
done < <(find "$DEST" -type f -print0)

# NAO ha chmod no stage de proposito. O modo dos membros vem do --mode do tar,
# mais abaixo.
#
# Motivo: num checkout Windows o chmod nao adere ao NTFS. O build gravava os
# hooks .example como 0755 aqui e 0644 no runner Linux — mesmo commit, dois
# tarballs diferentes. Enquanto o modo vier do filesystem, o artefato depende
# da maquina que empacotou, e "reproduzivel" e so uma palavra no README.

# CHECKSUMS por ultimo — cobre tudo menos a si proprio.
#
# Duas armadilhas aqui, ambas ja custaram um build quebrado:
#   1. redirecionar direto para CHECKSUMS.sha256 faz o shell criar o arquivo
#      ANTES do find rodar; ele entra na propria lista e o digest gravado e o
#      do arquivo vazio. `sha256sum -c` falha na frota inteira. Por isso vai
#      para um temporario fora do stage e so depois entra no lugar.
#   2. no Windows o sha256sum default e binario e emite "digest *./caminho".
#      --text mantem o formato "digest  ./caminho" igual em toda plataforma;
#      como o stage e LF-only, ler em texto ou binario da o mesmo digest.
SUMS="${STAGE}/CHECKSUMS.sha256"
( cd "$DEST" && find . -type f | LC_ALL=C sort | xargs sha256sum --text > "$SUMS" )
if grep -q 'CHECKSUMS\.sha256' "$SUMS"; then
  echo "CHECKSUMS se auto-referencia — build abortado" >&2
  exit 1
fi
mv "$SUMS" "${DEST}/CHECKSUMS.sha256"

mkdir -p "$OUTDIR"
ALVO="${OUTDIR}/${PREFIXO}.tar.gz"
TAR_TMP="${STAGE}/saida.tar"

# Empacota em DUAS passadas, cada uma com --mode fixo. E o que torna o modo
# independente do filesystem de origem. --no-recursion porque os caminhos sao
# todos listados a mao: nada entra sem estar declarado.
LISTA_755=("$PREFIXO")
for d in bin docs hooks.d lib; do LISTA_755+=("${PREFIXO}/${d}"); done
LISTA_644=("${PREFIXO}/CHECKSUMS.sha256")
for f in "${CONTEUDO[@]}"; do
  case "$f" in
    install.sh|lib/*.sh|bin/*.sh) LISTA_755+=("${PREFIXO}/${f}") ;;
    *)                            LISTA_644+=("${PREFIXO}/${f}") ;;
  esac
done

TAR_COMUM=(--sort=name --owner=0 --group=0 --numeric-owner
           --mtime="$MTIME" --format=gnu --no-recursion -C "$STAGE")

tar "${TAR_COMUM[@]}" --mode=0755 -cf "$TAR_TMP" "${LISTA_755[@]}"
tar "${TAR_COMUM[@]}" --mode=0644 -rf "$TAR_TMP" "${LISTA_644[@]}"

# O digest do .tar e a garantia de reprodutibilidade que atravessa
# plataformas; o do .tar.gz depende da versao do gzip que comprimiu, entao
# publicamos os dois e a verificacao entre hosts diferentes usa o do .tar.
sha256sum "$TAR_TMP" | cut -d' ' -f1 > "${OUTDIR}/${PREFIXO}.tar.sha256"

gzip -n -9 < "$TAR_TMP" > "$ALVO"
sha256sum "$ALVO" | sed "s#${OUTDIR}/##" > "${ALVO}.sha256"

echo "build ok: ${ALVO}"
echo "  versao      : ${VERSION}"
echo "  sha256 .tar : $(cat "${OUTDIR}/${PREFIXO}.tar.sha256")"
echo "  sha256 .gz  : $(cut -d' ' -f1 < "${ALVO}.sha256")"
echo "  itens       : ${#CONTEUDO[@]} + CHECKSUMS.sha256"
