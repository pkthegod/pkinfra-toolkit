"""Matriz RED/GREEN da suite de DNS (bind9).

A regra desta matriz, e o motivo dela existir
---------------------------------------------
Para CADA caso da suite bind ha um teste que injeta o defeito correspondente e
exige tres coisas:

  1. o caso alvo muda para a cor certa (RED ou YELLOW);
  2. NENHUM outro caso muda de cor;
  3. o codigo de saida do processo acompanha.

O item 2 e o que costuma faltar. Uma checagem que derruba tres casos ao mesmo
tempo faz o operador perseguir sintoma em vez de causa — e no dia do incidente
isso custa mais caro que a falha em si.

O item 3 fecha o contrato com o cron e com o Zabbix: cor no terminal nao serve
de gatilho, exit code serve.
"""

import pytest

from conftest import (
    SERIAL,
    SIMPLES,
    ZONA,
    apenas_amarelo,
    apenas_vermelho,
    cenario_bind,
    dig_resposta,
    dump_bind,
    sem_vermelho,
)

# A matriz roda so o modulo bind: o alvo e o motor de decisao de cada caso, e
# limitar o escopo corta um terco do tempo de suite. A nao-interferencia entre
# modulos fica por conta de test_host_saudavel_fica_todo_verde, que roda tudo.
BIND = ("--only", "bind", "--deep")


@pytest.fixture(scope="module")
def linha_base(tmp_path_factory):
    """Mapa id -> cor do host saudavel. Referencia de comparacao da matriz."""
    h = cenario_bind(tmp_path_factory.mktemp("bind-base"))
    mapa, _dados, proc = h.casos(*BIND)
    assert proc.returncode == 0, (
        f"o cenario saudavel precisa sair 0, saiu {proc.returncode}. "
        f"Sem isso a matriz inteira mede a coisa errada.\n{proc.stdout[-3000:]}"
    )
    return mapa


def _dump(h, **kw):
    """Substitui o dump de config do named por uma variante."""
    h.caso("named-checkconf", "-p *", 0, dump_bind(**kw))


# =============================================================================
# o cenario saudavel
# =============================================================================
def test_host_saudavel_fica_todo_verde(host_bind):
    mapa, dados, proc = host_bind.casos("--deep")
    sem_vermelho(mapa, proc)
    apenas_amarelo(mapa)
    assert proc.returncode == 0
    assert dados["verdict"] == "OK"


def test_suite_bind_cobre_as_duas_camadas(host_bind):
    """Passiva e ativa tem de existir; sem as duas isto vira 'ping no processo'."""
    mapa, _d, _p = host_bind.casos(*BIND)
    ids = set(mapa)
    passivos = {"bind.servico", "bind.porta.tcp", "bind.checkconf", "bind.zonas",
                "bind.recursao", "bind.transferencia", "bind.dnssec.validacao"}
    ativos = {"bind.q.recursiva", "bind.q.tcp", "bind.q.dnssec.positivo",
              "bind.q.dnssec.negativo", "bind.q.axfr", "bind.q.serial",
              "bind.q.autoritativa", "bind.q.nxdomain", "bind.q.cache"}
    assert passivos <= ids, f"faltam casos passivos: {sorted(passivos - ids)}"
    assert ativos <= ids, f"faltam casos ativos: {sorted(ativos - ids)}"


def test_sem_deep_a_camada_ativa_nao_roda(host_bind):
    """Sem --deep nada de rede acontece — o cron de 5 em 5 minutos depende disso."""
    mapa, _d, proc = host_bind.casos("--only", "bind")
    ativos = [k for k in mapa if k.startswith("bind.q.")]
    assert not ativos, f"consulta ativa rodou sem --deep: {ativos}"
    assert mapa["bind.deep"] == "SKIP"
    assert mapa["bind.servico"] == "GREEN", "a camada passiva tem de continuar rodando"
    assert proc.returncode == 0


def test_bind_ausente_pula_a_suite_inteira(host_vazio):
    """Host sem DNS nao pode acusar falha de DNS."""
    mapa, _d, proc = host_vazio.casos(*BIND)
    assert mapa == {"bind.unidade": "SKIP"}
    assert proc.returncode == 0


def test_unidade_inexistente_nao_e_confundida_com_existente(host_vazio):
    """`systemctl list-unit-files X` sai 0 mesmo sem a unidade em varias versoes.

    Quem confere so o codigo de saida roda a suite de bind num host sem bind e
    reporta RED em tudo. A deteccao tem de olhar a SAIDA.
    """
    host_vazio.caso("systemctl", "list-unit-files named.service", 0,
                    "UNIT FILE STATE PRESET\n\n0 unit files listed.\n")
    mapa, _d, _p = host_vazio.casos(*BIND)
    assert mapa == {"bind.unidade": "SKIP"}, (
        "saida sem a unidade listada foi tratada como bind instalado"
    )


# =============================================================================
# a matriz — camada passiva
# =============================================================================
DEFEITOS_PASSIVOS = [
    (
        "servico parado",
        lambda h: h.caso("systemctl", "is-active named", 0, "failed\n"),
        "bind.servico", "RED",
    ),
    (
        "53/udp sem socket",
        lambda h: h.caso("ss", "-lnu", 0, "State Recv-Q Send-Q Local Address:Port\n"),
        "bind.porta.udp", "RED",
    ),
    (
        # O classico: firewall libera 53/udp e esquece 53/tcp. Tudo parece
        # funcionar ate a primeira resposta grande.
        "53/tcp sem socket",
        lambda h: h.caso("ss", "-lnt", 0, "State Recv-Q Send-Q Local Address:Port\n"),
        "bind.porta.tcp", "RED",
    ),
    (
        "named-checkconf -z falha",
        lambda h: h.caso("named-checkconf", "-z *", 1,
                         "/etc/bind/db.exemplo.local:12: unknown RR type 'AAA'\n"),
        "bind.checkconf", "RED",
    ),
    (
        "rndc sem resposta",
        lambda h: h.caso("rndc", "status", 1, "rndc: connect failed: connection refused\n"),
        "bind.rndc", "YELLOW",
    ),
    (
        "allow-recursion any (resolvedor aberto)",
        lambda h: _dump(h, recursion="any;"),
        "bind.recursao", "RED",
    ),
    (
        "allow-recursion nao declarado",
        lambda h: _dump(h, recursion=None),
        "bind.recursao", "RED",
    ),
    (
        "allow-transfer any (zona vaza inteira)",
        lambda h: _dump(h, transfer="any;"),
        "bind.transferencia", "RED",
    ),
    (
        "allow-transfer nao declarado",
        lambda h: _dump(h, transfer=None),
        "bind.transferencia", "RED",
    ),
    (
        "dnssec-validation no",
        lambda h: _dump(h, dnssec="no"),
        "bind.dnssec.validacao", "RED",
    ),
    (
        "dnssec-validation nao declarado",
        lambda h: _dump(h, dnssec=None),
        "bind.dnssec.validacao", "YELLOW",
    ),
    (
        "version exposta",
        lambda h: _dump(h, version=None),
        "bind.version", "YELLOW",
    ),
    (
        "querylog ligado em producao",
        lambda h: _dump(h, querylog="yes"),
        "bind.querylog", "YELLOW",
    ),
    (
        "max-cache-size sem teto",
        lambda h: _dump(h, cache=None),
        "bind.cache.limite", "YELLOW",
    ),
    (
        "root hints apontando para arquivo que sumiu",
        lambda h: h.apaga("/usr/share/dns/root.hints"),
        "bind.roothints", "RED",
    ),
    (
        "LimitNOFILE de default",
        lambda h: h.caso("systemctl", "show named -p LimitNOFILE --value", 0, "1024\n"),
        "bind.limitnofile", "YELLOW",
    ),
    (
        "LimitNOFILE vazio nao pode passar por configurado",
        lambda h: h.caso("systemctl", "show named -p LimitNOFILE --value", 0, "\n"),
        "bind.limitnofile", "YELLOW",
    ),
]


# =============================================================================
# a matriz — camada ativa (--deep)
# =============================================================================
_ANS_GOOGLE = ["google.com.\t\t168\tIN\tA\t142.250.219.174"]

DEFEITOS_ATIVOS = [
    (
        # O sufixo `SIMPLES` ancora o padrao na consulta por UDP: sem ele o
        # mesmo stub responderia tambem pelo +tcp e pelo +bufsize, e o teste
        # passaria a medir tres casos de uma vez.
        "resolvedor nao resolve",
        lambda h: h.caso("dig", f"*google.com A*{SIMPLES}", 0, dig_resposta(status="SERVFAIL")),
        "bind.q.recursiva", "RED",
    ),
    (
        # NOERROR com zero registro nao e resolucao. Checar so o codigo de
        # saida do dig, como fazia a v1, chamava isto de sucesso.
        "NOERROR com resposta vazia",
        lambda h: h.caso("dig", f"*google.com A*{SIMPLES}", 0, dig_resposta(status="NOERROR")),
        "bind.q.recursiva", "RED",
    ),
    (
        # Forwarder de provedor que devolve portal de busca em vez de NXDOMAIN:
        # todo nome errado passa a "existir".
        "NXDOMAIN sequestrado pelo forwarder",
        lambda h: h.caso("dig", "*invalid A*", 0,
                         dig_resposta(answer=["busca.provedor.\t60\tIN\tA\t200.1.2.3"])),
        "bind.q.nxdomain", "RED",
    ),
    (
        "TCP nao responde",
        lambda h: h.caso("dig", "*google.com A*+tcp*", 9, ""),
        "bind.q.tcp", "RED",
    ),
    (
        "EDNS truncando em 1232",
        lambda h: h.caso("dig", "*google.com A*+bufsize*", 0,
                         dig_resposta(flags="qr tc rd ra", answer=_ANS_GOOGLE)),
        "bind.q.edns", "YELLOW",
    ),
    (
        "sem flag AD em dominio assinado",
        lambda h: h.caso("dig", "*iana.org A*+dnssec*", 0,
                         dig_resposta(flags="qr rd ra",
                                      answer=["iana.org.\t300\tIN\tA\t192.0.43.8"])),
        "bind.q.dnssec.positivo", "RED",
    ),
    (
        # O caso que 'funciona' e por isso passa despercebido: o resolvedor
        # aceita a zona quebrada porque nao esta validando nada.
        "dominio DNSSEC quebrado aceito como valido",
        lambda h: h.caso("dig", "*dnssec-failed.org A*", 0,
                         dig_resposta(answer=["dnssec-failed.org.\t60\tIN\tA\t68.87.109.242"])),
        "bind.q.dnssec.negativo", "RED",
    ),
    (
        "AXFR liberado para quem pedir",
        lambda h: h.caso("dig", f"*{ZONA} AXFR*", 0,
                         f"{ZONA}.\t3600\tIN\tSOA\tns1.{ZONA}. root.{ZONA}. {SERIAL} 7200 3600 1209600 3600\n"
                         f"{ZONA}.\t3600\tIN\tNS\tns1.{ZONA}.\n"
                         f"www.{ZONA}.\t3600\tIN\tA\t10.0.0.9\n"),
        "bind.q.axfr", "RED",
    ),
    (
        # Zona editada no disco e reload esquecido. Nenhum check de servico
        # enxerga: o named esta de pe, feliz, servindo dado velho.
        "zona editada sem reload",
        lambda h: h.caso("named-checkzone", f"{ZONA} *", 0,
                         f"zone {ZONA}/IN: loaded serial 2026081299\nOK\n"),
        "bind.q.serial", "RED",
    ),
    (
        "sem flag AA na propria zona",
        lambda h: h.caso("dig", f"*{ZONA} SOA*", 0,
                         dig_resposta(flags="qr rd ra", answer=[
                             f"{ZONA}.\t3600\tIN\tSOA\tns1.{ZONA}. root.{ZONA}. "
                             f"{SERIAL} 7200 3600 1209600 3600"])),
        "bind.q.autoritativa", "RED",
    ),
    (
        "version.bind revelando a versao exata",
        lambda h: h.caso("dig", "*version.bind CH TXT*", 0, '"9.18.24-1-Debian"\n'),
        "bind.q.version.chaos", "YELLOW",
    ),
]


@pytest.mark.parametrize(
    "mutar,alvo,cor",
    [(d[1], d[2], d[3]) for d in DEFEITOS_PASSIVOS + DEFEITOS_ATIVOS],
    ids=[d[0] for d in DEFEITOS_PASSIVOS + DEFEITOS_ATIVOS],
)
def test_defeito_muda_exatamente_um_caso(host_bind, linha_base, mutar, alvo, cor):
    mutar(host_bind)
    mapa, dados, proc = host_bind.casos(*BIND)

    assert alvo in mapa, f"o caso {alvo} sumiu da suite"
    assert mapa[alvo] == cor, (
        f"{alvo} deveria ficar {cor}, ficou {mapa[alvo]}\n{proc.stdout[-2500:]}"
    )

    mudaram = {k for k in set(mapa) | set(linha_base) if mapa.get(k) != linha_base.get(k)}
    assert mudaram == {alvo}, (
        f"o defeito deveria mexer so em {alvo}; mexeu em {sorted(mudaram)}. "
        "Checagem acoplada faz o operador perseguir sintoma."
    )

    esperado = 2 if cor == "RED" else 1
    assert proc.returncode == esperado, (
        f"exit esperado {esperado} para um {cor}, veio {proc.returncode}"
    )
    assert dados["verdict"] == ("FALHA" if cor == "RED" else "ATENCAO")


# =============================================================================
# casos que legitimamente atravessam varios checks
# =============================================================================
def test_sem_zona_master_os_testes_de_zona_saem_skip(host_bind):
    """Resolvedor puro nao tem zona propria — nao pode virar RED por isso."""
    _dump(host_bind, zona=None)
    mapa, _d, proc = host_bind.casos(*BIND)
    assert mapa["bind.zonas"] == "SKIP"
    assert mapa["bind.q.axfr"] == "SKIP"
    assert "bind.q.serial" not in mapa
    assert "bind.q.autoritativa" not in mapa
    sem_vermelho(mapa, proc)
    assert proc.returncode == 0


def test_config_com_varios_defeitos_reporta_todos(host_bind):
    """Um defeito nao pode mascarar o outro: a suite reporta a lista inteira."""
    _dump(host_bind, recursion="any;", transfer="any;", dnssec="no", version=None)
    mapa, dados, proc = host_bind.casos(*BIND)
    apenas_vermelho(mapa, "bind.recursao", "bind.transferencia", "bind.dnssec.validacao")
    apenas_amarelo(mapa, "bind.version")
    assert dados["summary"]["fail"] == 3
    assert dados["summary"]["warn"] == 1
    assert proc.returncode == 2


def test_zona_invalida_falha_e_derruba_a_comparacao_de_serial(host_bind, linha_base):
    """Zona que nao carrega e RED — e o serial passa a SKIP, nao a GREEN.

    Este e o unico acoplamento intencional da suite: sem carregar a zona nao
    existe serial de arquivo para comparar. Afirmar coerencia ali seria mentir
    com cara de verde, entao o caso sai de cena. Fica fora da matriz de "um
    defeito, um caso" de proposito, com o efeito duplo escrito por extenso.
    """
    host_bind.caso("named-checkzone", f"{ZONA} *", 1,
                   f"zone {ZONA}/IN: has no NS records\nzone {ZONA}/IN: not loaded due to errors.\n")
    mapa, _d, proc = host_bind.casos(*BIND)
    assert mapa["bind.zonas"] == "RED"
    assert mapa["bind.q.serial"] == "SKIP"
    mudaram = {k for k in mapa if mapa[k] != linha_base.get(k)}
    assert mudaram == {"bind.zonas", "bind.q.serial"}, sorted(mudaram)
    assert proc.returncode == 2


def test_config_ilegivel_vira_skip_e_nao_uma_lista_de_falsas_falhas(host_bind):
    """Sem root, `named-checkconf -p` volta vazio no Debian (rndc.key e 0640).

    Concluir "allow-recursion nao declarado" a partir disso encheria o
    relatorio de RED que sao so falta de permissao — e uma suite que grita
    errado uma vez passa a ser ignorada sempre.
    """
    host_bind.caso("named-checkconf", "-p *", 1, "")
    mapa, dados, proc = host_bind.casos(*BIND)

    for cid in ("bind.recursao", "bind.transferencia", "bind.dnssec.validacao",
                "bind.zonas", "bind.roothints", "bind.version", "bind.querylog",
                "bind.cache.limite"):
        assert mapa[cid] == "SKIP", f"{cid} virou {mapa[cid]} por falta de permissao"

    # o que NAO depende do dump continua sendo medido
    assert mapa["bind.servico"] == "GREEN"
    assert mapa["bind.porta.tcp"] == "GREEN"
    assert mapa["bind.limitnofile"] == "GREEN"
    sem_vermelho(mapa, proc)
    assert proc.returncode == 0

    motivo = next(c for c in dados["checks"] if c["id"] == "bind.recursao")["actual"]
    assert "root" in motivo, f"o SKIP tem de dizer o que fazer: {motivo!r}"


def test_serial_ilegivel_nao_inventa_falha(host_bind):
    """Sem serial dos dois lados, o caso e SKIP — nunca um RED especulativo."""
    host_bind.caso("named-checkzone", f"{ZONA} *", 0, "OK\n")
    mapa, _d, proc = host_bind.casos(*BIND)
    assert mapa["bind.q.serial"] == "SKIP"
    sem_vermelho(mapa, proc)


def test_latencia_de_cache_respeita_o_orcamento(host_bind):
    """Com orcamento zero o caso tem de acender; e o unico jeito de provar
    que o limiar e comparado de verdade."""
    mapa, _d, proc = host_bind.casos("--deep", env={"LAT_BUDGET_MS": "0"})
    assert mapa["bind.q.latencia"] == "YELLOW"
    assert proc.returncode == 1


def _dig_ttl_crescente(h, primeiro=60, segundo=300):
    """Faz a mesma consulta responder TTL diferente na 1a e na 2a vez."""
    contador = (h.base / "contador-ttl").as_posix()
    h.caso_script(
        "dig",
        "*example.com A*",
        f"""
        n=$(cat '{contador}' 2>/dev/null || echo 0); echo $((n+1)) > '{contador}'
        [[ $n -eq 0 ]] && ttl={primeiro} || ttl={segundo}
        printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\\n'
        printf ';; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1\\n\\n'
        printf ';; ANSWER SECTION:\\n'
        printf 'example.com.\\t%s\\tIN\\tA\\t93.184.216.34\\n\\n' "$ttl"
        exit 0
        """,
    )


def test_cache_em_uso_quando_o_ttl_decresce(host_bind):
    """O caminho GREEN do mesmo mecanismo: 2a consulta com TTL menor."""
    _dig_ttl_crescente(host_bind, primeiro=300, segundo=240)
    mapa, _d, proc = host_bind.casos(*BIND)
    assert mapa["bind.q.cache"] == "GREEN", proc.stdout[-2000:]
    assert proc.returncode == 0


def test_cache_ttl_crescente_acende_amarelo(host_bind, linha_base):
    """TTL da segunda consulta MAIOR que o da primeira: resposta sem cache.

    Sintoma real de forwarder reescrevendo TTL ou de cache desabilitado — e
    invisivel para qualquer checagem que faca uma consulta so.
    """
    _dig_ttl_crescente(host_bind, primeiro=60, segundo=300)
    mapa, _d, proc = host_bind.casos(*BIND)
    assert mapa["bind.q.cache"] == "YELLOW", proc.stdout[-2000:]
    mudaram = {k for k in mapa if mapa[k] != linha_base.get(k)}
    assert mudaram == {"bind.q.cache"}, sorted(mudaram)
    assert proc.returncode == 1


def test_ids_dos_casos_sao_unicos(host_bind):
    """Id repetido faz o painel do operador somar duas linhas como se fosse uma."""
    _mapa, dados, _p = host_bind.casos(*BIND)
    ids = [c["id"] for c in dados["checks"]]
    repetidos = {i for i in ids if ids.count(i) > 1}
    assert not repetidos, f"ids duplicados: {sorted(repetidos)}"


def test_todo_red_traz_instrucao_de_correcao(host_bind):
    """RED sem 'o que fazer' transfere o problema em vez de resolver."""
    _dump(host_bind, recursion="any;", transfer="any;", dnssec="no")
    host_bind.caso("ss", "-lnt", 0, "State Recv-Q Send-Q Local Address:Port\n")
    _mapa, dados, _p = host_bind.casos(*BIND)
    sem_fix = [c["id"] for c in dados["checks"]
               if c["status"] in ("RED", "YELLOW") and not c["fix"].strip()]
    assert not sem_fix, f"casos sem orientacao de correcao: {sem_fix}"


def test_arquivo_de_zona_e_conferido_pelo_caminho_do_dump(host_bind):
    """O caminho do arquivo de zona vem do dump, nao de um palpite fixo."""
    host_bind.arquivo("/srv/zonas/db.outro", "$TTL 3600\n")
    _dump(host_bind, arquivo_zona="/srv/zonas/db.outro")
    host_bind.caso("named-checkzone", f"{ZONA} */srv/zonas/db.outro", 0,
                   f"zone {ZONA}/IN: loaded serial {SERIAL}\nOK\n")
    mapa, _d, proc = host_bind.casos(*BIND)
    assert mapa["bind.zonas"] == "GREEN", proc.stdout[-2000:]
    assert mapa["bind.q.serial"] == "GREEN"
