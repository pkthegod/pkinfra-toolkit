#!/usr/bin/env bash
# Exercita bin/update-root-hints.sh contra um host sintetico: stubs no PATH e
# um hints apontado para o tmp, entao nada real e tocado.
set -uo pipefail
SCRIPT="$1"
BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
STUBS="$BASE/stubs"; mkdir -p "$STUBS"
HINTS="$BASE/root.hints"

# --- named.root publicado, em MAIUSCULAS como o de verdade -------------------
gera_root() { # <versao>
  { echo ";       This file holds the information on root name servers"
    echo ";       last update:     January 15, 2026"
    echo ";       related version of root zone:     $1"
    echo ";"
    for L in A B C D E F G H I J K L M; do
      echo ".                        3600000      NS    ${L}.ROOT-SERVERS.NET."
    done
    n=4
    for L in A B C D E F G H I J K L M; do
      echo "${L}.ROOT-SERVERS.NET.      3600000      A     198.41.0.${n}"
      n=$((n+1))
    done
    echo "; End of file"; } > "$2"
}
PUBLICADO="$BASE/publicado"; gera_root 2026011501 "$PUBLICADO"

# --- stubs -------------------------------------------------------------------
cat > "$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "list-unit-files named.service") echo "UNIT FILE     STATE   PRESET"; echo "named.service enabled enabled"; exit 0 ;;
  "is-active --quiet named") exit 0 ;;
  "restart named") echo "restart named" >> "$LOG"; exit "${RESTART_RC:-0}" ;;
  *) exit 1 ;;
esac
EOF
cat > "$STUBS/named-checkconf" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "-p" ]] && { printf 'zone "." IN {\n\ttype hint;\n\tfile "%s";\n};\n' "$HINTS"; exit 0; }
exit 0
EOF
cat > "$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-o" ]] && { shift; out="$1"; }; shift; done
[[ "${CURL_RC:-0}" != "0" ]] && exit "$CURL_RC"
cat "${CURL_BODY:-$PUBLICADO_G}" > "$out"
EOF
cat > "$STUBS/dig" <<'EOF'
#!/usr/bin/env bash
[[ "${DIG_QUEBRADO:-0}" == "1" ]] && { echo ";; status: SERVFAIL"; exit 0; }
echo ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1"
for L in a b c d e f g h i j k l m; do echo ".			3600000	IN	NS	${L}.root-servers.net."; done
EOF
cat > "$STUBS/dpkg" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"
export PUBLICADO_G="$PUBLICADO"
export LOG="$BASE/acoes.log"

falhas=0
caso() { printf '\n\033[36m--- %s ---\033[0m\n' "$*"; : > "$LOG"; }
espera() { # <descricao> <esperado> <obtido>
  if [[ "$2" == "$3" ]]; then printf '  OK   %s (%s)\n' "$1" "$3"
  else printf '  \033[31mFALHA\033[0m %s: esperado %s, veio %s\n' "$1" "$2" "$3"; falhas=$((falhas+1)); fi
}

# =============================================================================
caso "1. hints identico ao publicado -> ATUAL, sem restart"
cp "$PUBLICADO" "$HINTS"
saida=$(bash "$SCRIPT" 2>&1); rc=$?
espera "exit" 0 "$rc"
grep -q "JA ESTA ATUAL" <<<"$saida" && echo "  OK   disse 'JA ESTA ATUAL'" || { echo "  FALHA nao detectou atual"; falhas=$((falhas+1)); }
espera "nao reiniciou o servico" "" "$(cat "$LOG")"

caso "2. hints antigo -> --check acusa e NAO altera"
gera_root 2020010101 "$HINTS"
antes=$(md5sum < "$HINTS")
saida=$(bash "$SCRIPT" --check 2>&1); rc=$?
espera "exit (1 = desatualizado)" 1 "$rc"
grep -q "DESATUALIZADO" <<<"$saida" && echo "  OK   disse 'DESATUALIZADO'" || { echo "  FALHA"; falhas=$((falhas+1)); }
espera "arquivo intocado" "$antes" "$(md5sum < "$HINTS")"
espera "nao reiniciou" "" "$(cat "$LOG")"

caso "3. hints antigo -> atualiza, faz backup e reinicia"
gera_root 2020010101 "$HINTS"
saida=$(bash "$SCRIPT" 2>&1); rc=$?
espera "exit" 0 "$rc"
espera "conteudo virou o publicado" "$(md5sum < "$PUBLICADO")" "$(md5sum < "$HINTS")"
espera "reiniciou uma vez" "restart named" "$(cat "$LOG")"
n=$(find "$BASE" -name 'root.hints.2*' | wc -l)
espera "backup datado criado" 1 "$n"
grep -q "2020010101 para 2026011501" <<<"$saida" && echo "  OK   relatou a transicao de versao" || { echo "  FALHA sem transicao"; falhas=$((falhas+1)); }

caso "4. download falha -> NADA e alterado (o caso que trava o host)"
gera_root 2020010101 "$HINTS"; antes=$(md5sum < "$HINTS")
saida=$(CURL_RC=7 bash "$SCRIPT" 2>&1); rc=$?
espera "exit" 2 "$rc"
espera "hints preservado" "$antes" "$(md5sum < "$HINTS")"
espera "nao reiniciou" "" "$(cat "$LOG")"
grep -q "NADA foi alterado" <<<"$saida" && echo "  OK   avisou que nada mudou" || { echo "  FALHA"; falhas=$((falhas+1)); }

caso "5. portal cativo devolve HTML 200 -> rejeita e preserva"
gera_root 2020010101 "$HINTS"; antes=$(md5sum < "$HINTS")
# Precisa passar do piso de 1000 bytes, senao a checagem de TAMANHO barra
# antes e o ramo de HTML nunca e exercitado — portal cativo real tem
# quilobytes de markup, entao o tamanho sozinho nao protege.
{ printf '<!doctype html><html><head><title>Autenticacao</title></head><body>\n'
  for i in $(seq 60); do printf '  <div class="linha-%d">Faca login para acessar a internet</div>\n' "$i"; done
  printf '</body></html>\n'; } > "$BASE/portal"
saida=$(CURL_BODY="$BASE/portal" bash "$SCRIPT" 2>&1); rc=$?
espera "exit" 2 "$rc"
espera "hints preservado" "$antes" "$(md5sum < "$HINTS")"
grep -q "veio HTML" <<<"$saida" && echo "  OK   identificou HTML" || { echo "  FALHA"; falhas=$((falhas+1)); }

caso "6. arquivo truncado -> rejeita"
gera_root 2020010101 "$HINTS"; antes=$(md5sum < "$HINTS")
head -c 200 "$PUBLICADO" > "$BASE/curto"
saida=$(CURL_BODY="$BASE/curto" bash "$SCRIPT" 2>&1); rc=$?
espera "exit" 2 "$rc"
espera "hints preservado" "$antes" "$(md5sum < "$HINTS")"

caso "7. resolvedor nao volta depois do restart -> DESFAZ"
gera_root 2020010101 "$HINTS"; antes=$(md5sum < "$HINTS")
saida=$(DIG_QUEBRADO=1 bash "$SCRIPT" 2>&1); rc=$?
espera "exit" 2 "$rc"
espera "hints ANTERIOR restaurado" "$antes" "$(md5sum < "$HINTS")"
grep -q "restaurado" <<<"$saida" && echo "  OK   avisou o rollback" || { echo "  FALHA sem aviso"; falhas=$((falhas+1)); }

caso "8. --dry-run nao escreve nem reinicia"
gera_root 2020010101 "$HINTS"; antes=$(md5sum < "$HINTS")
saida=$(bash "$SCRIPT" --dry-run 2>&1); rc=$?
espera "exit" 0 "$rc"
espera "hints intocado" "$antes" "$(md5sum < "$HINTS")"
espera "nao reiniciou" "" "$(cat "$LOG")"

caso "9. staging fica no disco, ao lado, com o conteudo publicado"
gera_root 2020010101 "$HINTS"; rm -f "${HINTS}2"
bash "$SCRIPT" >/dev/null 2>&1
espera "root.hints2 existe" "sim" "$([[ -f "${HINTS}2" ]] && echo sim || echo nao)"
espera "staging == publicado" "$(md5sum < "$PUBLICADO")" "$(md5sum < "${HINTS}2")"

caso "10. publicado MAIS ANTIGO que o instalado -> recusa (nao rebaixa)"
gera_root 2030010101 "$HINTS"        # local no futuro: o publicado fica antigo
antes=$(md5sum < "$HINTS")
saida=$(bash "$SCRIPT" 2>&1); rc=$?
espera "exit" 2 "$rc"
espera "hints preservado" "$antes" "$(md5sum < "$HINTS")"
espera "nao reiniciou" "" "$(cat "$LOG")"
grep -q "MAIS ANTIGO" <<<"$saida" && echo "  OK   identificou a regressao" || { echo "  FALHA"; falhas=$((falhas+1)); }

caso "11. --stage apontando para o proprio hints -> recusa"
gera_root 2020010101 "$HINTS"; antes=$(md5sum < "$HINTS")
saida=$(bash "$SCRIPT" --stage "$HINTS" 2>&1); rc=$?
espera "exit" 2 "$rc"
espera "hints preservado" "$antes" "$(md5sum < "$HINTS")"
grep -q "nao pode ser o proprio hints" <<<"$saida" && echo "  OK   barrou o auto-atropelo" || { echo "  FALHA"; falhas=$((falhas+1)); }

caso "12. mesma versao, conteudo divergente -> instala mas avisa"
gera_root 2026011501 "$HINTS"; echo "; editado a mao" >> "$HINTS"
saida=$(bash "$SCRIPT" 2>&1); rc=$?
espera "exit" 0 "$rc"
grep -q "editado a mao" <<<"$saida" && echo "  OK   avisou a divergencia" || { echo "  FALHA"; falhas=$((falhas+1)); }
espera "convergiu para o publicado" "$(md5sum < "$PUBLICADO")" "$(md5sum < "$HINTS")"

printf '\n=========================\n'
[[ $falhas -eq 0 ]] && { printf 'TODOS OS CASOS PASSARAM\n'; exit 0; }
printf '%d CASO(S) FALHARAM\n' "$falhas"; exit 1
