#!/usr/bin/env bash
# =============================================================================
# update-root-hints.sh — v1.1
# Atualiza o root.hints do resolvedor local NA ORDEM QUE NAO DERRUBA O DNS.
#
# A ordem e o ponto inteiro deste script. A sequencia intuitiva
#
#     mv /usr/share/dns/root.hints /usr/share/dns/root.hints.$(date +%Y%m%d)
#     apt install wget -y
#     wget https://www.internic.net/domain/named.root -O /usr/share/dns/root.hints
#
# se autodestroi. Tirado o hints, o resolvedor perde o ponto de partida da
# recursao; www.internic.net deixa de resolver, o apt deixa de resolver, e o
# host fica sem como buscar exatamente o arquivo que o conserta. O estrago
# aparece um passo DEPOIS da linha que o causou, que e o pior lugar.
#
# Aqui o download vai para um arquivo AO LADO (root.hints2 por padrao). O
# hints em uso so e tocado depois que esse arquivo existe, passa na validacao
# e prova ser MAIS ATUAL. Se qualquer etapa falhar, o resolvedor continua com
# o hints velho — que funciona.
#
# O arquivo de staging FICA no disco de proposito: da para abri-lo, comparar a
# mao e repetir a decisao do script. Cada execucao o reescreve, entao ele nao
# se acumula.
#
# ORDEM
#   1. descobre resolvedor e o caminho REAL do hints (lendo a config, nao
#      chutando o caminho do Debian)
#   2. garante um baixador ANTES de mexer em qualquer coisa
#   3. baixa para <hints>2
#   4. valida o que baixou (tamanho, formato, 13 servidores raiz, nao-HTML)
#   5. compara VERSAO: so segue se o publicado for mais atual que o instalado
#   6. so entao: backup datado, copia atomica, restart
#   7. confere se o resolvedor voltou respondendo; se nao, DESFAZ e reinicia
#
# Uso:
#   ./update-root-hints.sh --check          baixa, compara e relata; nao instala
#   ./update-root-hints.sh --dry-run        mostra o que faria
#   ./update-root-hints.sh                  instala se o publicado for mais atual
#   ./update-root-hints.sh --force          instala mesmo se igual ou mais antigo
#   ./update-root-hints.sh --stage /tmp/x   outro caminho para o staging
#
# CODIGO DE SAIDA
#   0 = atual (ou atualizado com sucesso) | 1 = desatualizado (--check) | 2 = erro
# =============================================================================
set -uo pipefail

VERSION="1.1"
URL="${ROOT_HINTS_URL:-https://www.internic.net/domain/named.root}"
CHECK=0; DRY=0; FORCE=0; STAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   CHECK=1 ;;
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    --url)     shift; URL="${1:-}" ;;
    --stage)   shift; STAGE="${1:-}" ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "flag desconhecida: $1" >&2; exit 2 ;;
  esac
  shift
done

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
[[ -t 1 ]] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; }
ok()   { printf '  %sOK%s   %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!!%s   %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '  %sXX%s   %s\n' "$C_R" "$C_0" "$*"; }
info() { printf '  %s::%s   %s\n' "$C_B" "$C_0" "$*"; }
head1(){ printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
die()  { err "$*"; exit 2; }
run()  { [[ $DRY -eq 1 ]] && { printf '  %s[dry]%s %s\n' "$C_Y" "$C_0" "$*"; return 0; }; "$@"; }

# =============================================================================
# deteccao
# =============================================================================
# `list-unit-files` retorna 0 mesmo para unidade inexistente em varias versoes
# do systemd; quem responde e a saida, nao o codigo.
svc_existe() { systemctl list-unit-files "$1.service" 2>/dev/null | grep -q "^${1}\.service"; }
svc_ativo()  { systemctl is-active --quiet "$1" 2>/dev/null; }

SVC=""; RESOLVEDOR=""
for s in named bind9; do
  svc_existe "$s" && { SVC="$s"; RESOLVEDOR="bind"; break; }
done
[[ -z "$SVC" ]] && svc_existe unbound && { SVC="unbound"; RESOLVEDOR="unbound"; }

# Caminho do hints lido da CONFIG RESOLVIDA, nao adivinhado. Host que separa
# options em outro arquivo, ou que aponta o hints para fora de /usr/share/dns,
# faria um caminho fixo atualizar um arquivo que ninguem le — e o operador
# ficaria com a impressao de ter corrigido algo.
descobre_hints() {
  local p=""
  case "$RESOLVEDOR" in
    bind)
      p=$(named-checkconf -p 2>/dev/null \
          | awk '/^zone[ \t]+"\."/{d=1} d&&/file[ \t]+"/{sub(/^.*file[ \t]+"/,"");sub(/".*$/,"");print;exit}')
      ;;
    unbound)
      p=$(unbound-checkconf -o root-hints 2>/dev/null | head -1)
      ;;
  esac
  printf '%s' "${p:-/usr/share/dns/root.hints}"
}

# =============================================================================
# validacao do arquivo baixado
# =============================================================================
# Um GET com codigo 200 NAO garante que veio o named.root: portal cativo e
# proxy corporativo respondem 200 com uma pagina HTML. Instalar isso como
# hints e trocar um arquivo velho e funcional por lixo — e o resolvedor so
# quebra no proximo restart, longe daqui.
valido() { # <arquivo>
  local f="$1" tam ns
  [[ -s "$f" ]] || { err "arquivo vazio"; return 1; }
  tam=$(wc -c < "$f")
  [[ $tam -ge 1000 && $tam -le 32768 ]] || { err "tamanho implausivel: ${tam} bytes"; return 1; }
  grep -qi '<html\|<!doctype' "$f" && { err "veio HTML, nao zona (portal cativo ou proxy?)"; return 1; }
  # 13 servidores raiz, de a. a m.root-servers.net.
  #
  # -i obrigatorio: o named.root publicado escreve os nomes em MAIUSCULAS
  # (A.ROOT-SERVERS.NET.). Um casamento sensivel a caixa rejeitaria o arquivo
  # legitimo — e o script abortaria toda vez, sempre com "nada alterado",
  # parecendo um problema de rede.
  ns=$(grep -ciE '^\.[[:space:]]+[0-9]+[[:space:]]+(IN[[:space:]]+)?NS[[:space:]]' "$f")
  [[ $ns -ge 13 ]] || { err "so ${ns} registros NS da raiz (esperado 13)"; return 1; }
  grep -qiE '^[a-m]\.root-servers\.net\.[[:space:]]+[0-9]+[[:space:]]+(IN[[:space:]]+)?A[[:space:]]' "$f" \
    || { err "sem registro A de root-servers.net"; return 1; }
  return 0
}

# O proprio arquivo carrega a versao do root zone a que corresponde:
#   ;       related version of root zone:     2026081201
# E um inteiro AAAAMMDDNN, entao compara direto como numero.
versao() { # <arquivo>
  local v
  v=$(grep -oiE 'related version of root zone:[[:space:]]*[0-9]+' "$1" 2>/dev/null \
      | grep -oE '[0-9]+$' | head -1)
  printf '%s' "${v:-}"
}

# =============================================================================
head1 "update-root-hints v${VERSION}"

[[ -z "$SVC" ]] && die "nenhum resolvedor local encontrado (named, bind9 ou unbound)"
HINTS="$(descobre_hints)"
# Staging ao lado do alvo: mesmo diretorio, sufixo 2. Mesmo filesystem, entao
# a instalacao no fim e um mv atomico.
[[ -z "$STAGE" ]] && STAGE="${HINTS}2"

# Um --stage apontando para o proprio hints recriaria exatamente o acidente
# que este script existe para evitar: escrita direta por cima do arquivo vivo.
[[ "$STAGE" == "$HINTS" ]] && die "--stage nao pode ser o proprio hints (${HINTS})"

info "resolvedor: ${SVC} (${RESOLVEDOR})"
info "hints:      ${HINTS}"
info "staging:    ${STAGE}"
svc_ativo "$SVC" && ok "${SVC} ativo" || warn "${SVC} instalado mas parado"

# Caminho de pacote e territorio do dpkg: o proximo `apt upgrade` do
# dns-root-data sobrescreve o arquivo de volta, em silencio, e a atualizacao
# feita aqui evapora sem nenhum aviso.
if command -v dpkg >/dev/null 2>&1 && dpkg -S "$HINTS" >/dev/null 2>&1; then
  warn "${HINTS} pertence ao pacote $(dpkg -S "$HINTS" 2>/dev/null | cut -d: -f1)"
  warn "um 'apt upgrade' desse pacote reverte esta atualizacao sem avisar"
  warn "para durar: aponte a config para um caminho proprio (ex.: /var/lib/${RESOLVEDOR}/root.hints)"
fi

# --- baixador ANTES de qualquer alteracao ------------------------------------
# Instalar o baixador depois de remover o hints e o erro que trava o host: o
# apt tambem precisa resolver nome. Se falta, falha aqui, com tudo intacto.
head1 "Baixando"
if command -v curl >/dev/null 2>&1;   then BAIXA=(curl -fsSL --max-time 30 -o "$STAGE" "$URL")
elif command -v wget >/dev/null 2>&1; then BAIXA=(wget -q --timeout=30 -O "$STAGE" "$URL")
else
  err "nem curl nem wget instalados"
  err "instale ANTES de mexer no hints — com o hints removido o apt tambem para de resolver:"
  err "  apt-get install -y curl"
  exit 2
fi

info "origem: ${URL}"
if ! "${BAIXA[@]}"; then
  err "download falhou — NADA foi alterado, ${HINTS} continua no lugar"
  err "se o DNS ja estiver quebrado, resolva por um servidor externo para baixar:"
  err "  dig +short www.internic.net @1.1.1.1"
  exit 2
fi

valido "$STAGE" || die "o arquivo baixado nao passou na validacao — ${HINTS} intacto"
ok "baixado em ${STAGE} ($(wc -c < "$STAGE") bytes)"

# --- o teste: o publicado e MAIS ATUAL que o instalado? ----------------------
head1 "Comparando"
V_NOVA="$(versao "$STAGE")"
V_ATUAL=""
[[ -f "$HINTS" ]] && V_ATUAL="$(versao "$HINTS")"

info "instalado: versao ${V_ATUAL:-desconhecida}"
info "publicado: versao ${V_NOVA:-desconhecida}"

# ACAO: atual | atualizar | regressao
ACAO="atualizar"
if [[ ! -f "$HINTS" ]]; then
  warn "nao existe ${HINTS} — sera criado"
elif [[ "$V_NOVA" =~ ^[0-9]+$ && "$V_ATUAL" =~ ^[0-9]+$ ]]; then
  # Comparacao por versao, que e o que "mais atual" quer dizer. Comparar so o
  # conteudo trataria um mirror velho como novidade e rebaixaria o hints.
  if   [[ $V_NOVA -gt $V_ATUAL ]]; then ACAO="atualizar"
  elif [[ $V_NOVA -lt $V_ATUAL ]]; then ACAO="regressao"
  else
    # Mesma versao: normalmente identico. Se o conteudo diverge, o arquivo
    # local foi editado a mao — vale dizer, nao instalar em silencio.
    if cmp -s "$HINTS" "$STAGE"; then ACAO="atual"
    else ACAO="divergente"; fi
  fi
else
  # Sem rotulo de versao em algum dos lados, so resta o conteudo.
  warn "sem 'related version of root zone' legivel — comparando conteudo"
  cmp -s "$HINTS" "$STAGE" && ACAO="atual"
fi

case "$ACAO" in
  atual)
    ok "root.hints JA ESTA ATUAL (versao ${V_ATUAL}) — sem alteracao, sem restart"
    [[ $FORCE -eq 0 ]] && exit 0
    warn "--force: reinstalando mesmo atual" ;;
  regressao)
    err "o publicado (${V_NOVA}) e MAIS ANTIGO que o instalado (${V_ATUAL})"
    err "mirror desatualizado ou --url errado; instalar aqui seria rebaixar o hints"
    [[ $FORCE -eq 0 ]] && exit 2
    warn "--force: instalando versao mais antiga assim mesmo" ;;
  divergente)
    warn "mesma versao (${V_ATUAL}) mas conteudo diferente — ${HINTS} foi editado a mao?" ;;
  atualizar)
    warn "DESATUALIZADO: ${V_ATUAL:-ausente} -> ${V_NOVA}" ;;
esac

if [[ -f "$HINTS" ]]; then
  # diff so das linhas de dado; o cabecalho de comentario muda a cada
  # republicacao e poluiria a saida sem indicar mudanca de servidor raiz.
  diff <(grep -vE '^;|^$' "$HINTS") <(grep -vE '^;|^$' "$STAGE") \
    | grep -E '^[<>]' | head -12 | sed 's/^/       /'
fi

if [[ $CHECK -eq 1 ]]; then
  info "--check: ${HINTS} nao foi tocado; o baixado ficou em ${STAGE}"
  [[ "$ACAO" == "atual" ]] && exit 0 || exit 1
fi

# --- instalacao --------------------------------------------------------------
head1 "Instalando"
BACKUP=""
if [[ -f "$HINTS" ]]; then
  BACKUP="${HINTS}.$(date +%Y%m%d-%H%M%S)"
  run cp -p "$HINTS" "$BACKUP" || die "backup falhou — nada alterado"
  ok "backup: ${BACKUP}"
fi

# Copia para um temporario no diretorio final e move por cima: `mv` no mesmo
# filesystem e atomico, entao o resolvedor nunca enxerga um hints pela metade.
# Copiar o staging direto por cima do arquivo vivo cria essa janela.
DESTTMP="${HINTS}.novo.$$"
if [[ $DRY -eq 0 ]]; then
  cp "$STAGE" "$DESTTMP" || die "nao consegui escrever em $(dirname "$HINTS") (precisa de root?)"
  if [[ -n "$BACKUP" ]]; then
    chmod --reference="$BACKUP" "$DESTTMP" 2>/dev/null || chmod 0644 "$DESTTMP"
    chown --reference="$BACKUP" "$DESTTMP" 2>/dev/null || true
  else
    chmod 0644 "$DESTTMP"
  fi
  mv -f "$DESTTMP" "$HINTS" || die "instalacao falhou"
else
  run cp "$STAGE" "$HINTS"
fi
ok "instalado: ${HINTS} (versao ${V_NOVA})"

# --- restart -----------------------------------------------------------------
# O hints e lido na carga da zona raiz, entao o processo precisa reler.
# `systemctl restart` e o pedido; note que para o bind um `rndc reload`
# releria o hints PRESERVANDO o cache — o restart zera o cache inteiro.
head1 "Reiniciando ${SVC}"
if ! run systemctl restart "$SVC"; then
  err "restart de ${SVC} falhou"
  if [[ -n "$BACKUP" && $DRY -eq 0 ]]; then
    warn "restaurando ${BACKUP}"
    cp -p "$BACKUP" "$HINTS" && systemctl restart "$SVC"
  fi
  exit 2
fi
ok "${SVC} reiniciado"

# --- verificacao: o resolvedor voltou mesmo? ---------------------------------
# Sem este passo o script "termina com sucesso" tendo derrubado o DNS: o
# restart retorna 0 assim que a unidade sobe, muito antes de a recursao
# funcionar.
head1 "Verificando"
if [[ $DRY -eq 1 ]]; then
  info "[dry] pularia a verificacao"
  exit 0
fi
if ! command -v dig >/dev/null 2>&1; then
  warn "dig ausente — nao da para confirmar a recursao (instale dnsutils)"
  svc_ativo "$SVC" && ok "${SVC} ativo" || { err "${SVC} NAO esta ativo"; exit 2; }
  exit 0
fi

RESP=""
for _ in 1 2 3 4 5; do
  RESP=$(dig @127.0.0.1 . NS +time=3 +tries=1 2>/dev/null)
  grep -q 'status: NOERROR' <<<"$RESP" && grep -q '^\.' <<<"$RESP" && break
  sleep 1
done

if grep -q 'status: NOERROR' <<<"$RESP" && grep -q '^\.' <<<"$RESP"; then
  ok "a raiz responde: $(grep -cE '^\.[[:space:]]' <<<"$RESP") registros NS"
  ok "root.hints atualizado de ${V_ATUAL:-ausente} para ${V_NOVA}"
  exit 0
fi

err "o resolvedor NAO respondeu pela raiz depois do restart"
if [[ -n "$BACKUP" ]]; then
  warn "desfazendo: restaurando ${BACKUP}"
  cp -p "$BACKUP" "$HINTS" && systemctl restart "$SVC" && warn "hints anterior restaurado"
fi
err "investigue: journalctl -u ${SVC} -n 50"
exit 2
