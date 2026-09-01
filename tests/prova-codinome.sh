#!/usr/bin/env bash
# Baliza do detector de codinome. Monta /etc falso e confere as duas coisas
# que importam: "esta em voo?" e "o que sobrou de release anterior?".
set -uo pipefail

FONTE="${1:?uso: testa-rank.sh <pve-upgrade.sh>}"
RAIZ=$(mktemp -d); trap 'rm -rf "$RAIZ"' EXIT

# Extrai as funcoes reais e reaponta os caminhos para a raiz falsa, para o
# teste acompanhar o codigo em vez de reimplementa-lo.
extrai() {
  sed -n '/^deb_rank() {/,/^# ==== FIM DO BLOCO/p' "$FONTE" \
    | sed -e "s#/etc/apt/sources.list.d/#$RAIZ/etc/apt/sources.list.d/#g" \
          -e "s#/etc/apt/sources.list #$RAIZ/etc/apt/sources.list #g" \
          -e "s#/etc/os-release#$RAIZ/etc/os-release#g"
}

monta() {   # <codinome do sistema> <linhas de repo...>
  rm -rf "$RAIZ/etc"; mkdir -p "$RAIZ/etc/apt/sources.list.d"
  printf 'VERSION_CODENAME=%s\n' "$1" > "$RAIZ/etc/os-release"
  shift
  : > "$RAIZ/etc/apt/sources.list"
  local i=0
  for l in "$@"; do
    i=$((i+1))
    printf '%s\n' "$l" > "$RAIZ/etc/apt/sources.list.d/r$i.list"
  done
}

caso() {   # <nome> <esperado voo: sim|nao> <esperado stale> <sistema> <repos...>
  local nome="$1" esp_voo="$2" esp_stale="$3" sys="$4"; shift 4
  monta "$sys" "$@"
  local voo stale
  # shellcheck disable=SC1090
  eval "$(extrai)"
  if state_upgrade_inflight; then voo=sim; else voo=nao; fi
  stale=$(repo_codenames_stale)
  local st=OK
  [[ "$voo" == "$esp_voo" ]] || st=FALHOU
  [[ "$stale" == "$esp_stale" ]] || st=FALHOU
  printf '%-6s %-42s sistema=%-9s voo=%-4s residuo=[%s]\n' \
         "$st" "$nome" "$sys" "$voo" "$stale"
  [[ "$st" == OK ]]
}

falhas=0
caso "SEU CASO: bullseye sobrando no bookworm" nao "bullseye" bookworm \
     "deb http://download.proxmox.com/debian/pve bullseye pve-no-subscription" \
     "deb http://ftp.debian.org/debian bookworm main" || falhas=$((falhas+1))

caso "em voo de verdade: 7->8" sim "" bullseye \
     "deb http://ftp.debian.org/debian bookworm main" || falhas=$((falhas+1))

caso "limpo: so bookworm" nao "" bookworm \
     "deb http://ftp.debian.org/debian bookworm main" || falhas=$((falhas+1))

caso "buster sobrando no bullseye" nao "buster" bullseye \
     "deb http://archive.debian.org/debian buster main" \
     "deb http://ftp.debian.org/debian bullseye main" || falhas=$((falhas+1))

caso "em voo 8->9 com residuo antigo" sim "bullseye" bookworm \
     "deb http://ftp.debian.org/debian trixie main" \
     "deb http://old bullseye main" || falhas=$((falhas+1))

echo
if [[ $falhas -eq 0 ]]; then echo "todos os casos passaram"; else echo "$falhas caso(s) FALHARAM"; exit 1; fi
