"""Contrato da ferramenta: CLI, exit code, JSON e relatorio.

O JSON e o relatorio sao o produto que sai do host e vira decisao — item de
Zabbix, agregacao de frota, anexo de laudo. Um campo renomeado quebra painel de
terceiro em silencio, e um JSON invalido some do agregador sem erro nenhum.
Por isso o contrato tem teste separado da logica de cada checagem.
"""

import json
import re


import pytest

from conftest import VALIDATE, bash, posix, roda_bash

MODULOS = ["core", "tuning", "bind", "unbound", "zabbix-proxy", "docker", "pve"]


def _cli(*args):
    return roda_bash([bash(), posix(VALIDATE), *args])


# =============================================================================
# CLI
# =============================================================================
def test_list_publica_exatamente_os_modulos_aceitos_por_only():
    """`--list` e a fonte da verdade: o que ela imprime, `--only` aceita."""
    proc = _cli("--list")
    assert proc.returncode == 0
    listados = proc.stdout.split()
    assert listados == MODULOS, listados
    for m in listados:
        r = _cli("--only", m, "--json")
        assert r.returncode != 2 or '"schema"' in r.stdout, (
            f"--list publica '{m}' mas --only o rejeita: {r.stderr}"
        )


def test_flag_desconhecida_falha_em_vez_de_ignorar():
    """Flag ignorada em silencio faz o operador achar que filtrou algo."""
    proc = _cli("--nao-existe")
    assert proc.returncode == 2
    assert "flag desconhecida" in proc.stderr


def test_modulo_desconhecido_em_only_falha():
    """`--only bind9` (o nome errado) rodava TUDO calado antes deste teste."""
    proc = _cli("--only", "bind9")
    assert proc.returncode == 2
    assert "bind9" in proc.stderr


def test_modulo_desconhecido_em_skip_falha():
    proc = _cli("--skip", "dns")
    assert proc.returncode == 2
    assert "dns" in proc.stderr


def test_json_e_report_juntos_sao_recusados():
    """Os dois escrevem no stdout; misturar entrega um arquivo inutil."""
    proc = _cli("--json", "--report")
    assert proc.returncode == 2
    assert "escolha um" in proc.stderr


def test_help_sai_zero_e_descreve_as_duas_camadas():
    proc = _cli("--help")
    assert proc.returncode == 0
    assert "--deep" in proc.stdout
    assert "--json" in proc.stdout


# =============================================================================
# filtros
# =============================================================================
def test_only_roda_so_o_modulo_pedido(host_bind):
    dados, _p = host_bind.json("--only", "bind", "--deep")
    suites = set(dados["suites"])
    assert suites == {"bind"}, suites


def test_only_aceita_varios_modulos(host_bind):
    dados, _p = host_bind.json("--only", "core,tuning")
    assert set(dados["suites"]) == {"core", "tuning"}


def test_skip_remove_o_modulo_da_execucao(host_bind):
    dados, _p = host_bind.json("--skip", "bind,unbound,pve,docker,zabbix-proxy")
    assert set(dados["suites"]) == {"core", "tuning"}


def test_skip_vence_only_quando_os_dois_citam_o_mesmo_modulo(host_bind):
    """Precedencia declarada: `--skip` e uma exclusao dura."""
    dados, _p = host_bind.json("--only", "core,bind", "--skip", "bind")
    assert set(dados["suites"]) == {"core"}


# =============================================================================
# exit code
# =============================================================================
def test_exit_zero_quando_tudo_verde(host_bind):
    _m, dados, proc = host_bind.casos("--deep")
    assert proc.returncode == 0
    assert dados["exit"] == 0
    assert dados["verdict"] == "OK"


def test_exit_um_com_amarelo(host_bind):
    host_bind.caso("rndc", "status", 1, "rndc: connect failed\n")
    _m, dados, proc = host_bind.casos("--only", "bind")
    assert proc.returncode == 1
    assert dados["exit"] == 1
    assert dados["verdict"] == "ATENCAO"


def test_exit_dois_com_vermelho(host_bind):
    host_bind.caso("systemctl", "is-active named", 0, "failed\n")
    _m, dados, proc = host_bind.casos("--only", "bind")
    assert proc.returncode == 2
    assert dados["verdict"] == "FALHA"


def test_strict_promove_amarelo_a_falha(host_bind):
    """Para o gate de janela de manutencao: nenhuma ressalva passa."""
    host_bind.caso("rndc", "status", 1, "rndc: connect failed\n")
    _m, dados, proc = host_bind.casos("--only", "bind", "--strict")
    assert proc.returncode == 2, "com --strict um YELLOW tem de valer falha"
    assert dados["strict"] is True
    assert dados["verdict"] == "ATENCAO", (
        "o veredito descreve o estado; quem decide a severidade e o --strict"
    )


def test_strict_nao_inventa_falha_em_host_verde(host_bind):
    _m, _d, proc = host_bind.casos("--deep", "--strict")
    assert proc.returncode == 0


# =============================================================================
# JSON — schema
# =============================================================================
CAMPOS_OBRIGATORIOS = {
    "id", "module", "suite", "status", "severity", "name",
    "expected", "actual", "detail", "fix", "ms",
}


def test_json_tem_o_cabecalho_do_schema(host_bind):
    dados, _p = host_bind.json("--deep")
    assert dados["schema"] == 2
    assert dados["tool"] == "validate"
    assert dados["deep"] is True
    for chave in ("version", "host", "ts", "verdict", "exit", "summary", "suites", "checks"):
        assert chave in dados, f"falta {chave} no JSON"


def test_todo_caso_traz_os_campos_do_schema(host_bind):
    dados, _p = host_bind.json("--deep")
    assert dados["checks"], "nenhum caso no JSON"
    for c in dados["checks"]:
        faltando = CAMPOS_OBRIGATORIOS - set(c)
        assert not faltando, f"{c.get('id')} sem campos {sorted(faltando)}"
        assert c["status"] in ("GREEN", "YELLOW", "RED", "SKIP"), c
        assert isinstance(c["ms"], int)


def test_summary_bate_com_a_contagem_dos_casos(host_bind):
    """Resumo que nao fecha com a lista faz o painel mentir sem quebrar."""
    host_bind.caso("systemctl", "is-active named", 0, "failed\n")
    host_bind.caso("rndc", "status", 1, "")
    dados, _p = host_bind.json("--deep")
    casos = dados["checks"]
    s = dados["summary"]
    assert s["green"] == sum(1 for c in casos if c["status"] == "GREEN")
    assert s["red"] == sum(1 for c in casos if c["status"] == "RED")
    assert s["yellow"] == sum(1 for c in casos if c["status"] == "YELLOW")
    assert s["skip"] == sum(1 for c in casos if c["status"] == "SKIP")
    assert s["total"] == len(casos)


def test_summary_mantem_as_chaves_do_schema_1(host_bind):
    """`pkops fleet` e os itens de Zabbix ja instalados leem ok/warn/fail.

    Renomear estas chaves quebra painel de terceiro sem aviso — o toolkit
    manteria a nova nomenclatura e o operador veria zero em tudo.
    """
    dados, _p = host_bind.json("--deep")
    s = dados["summary"]
    assert s["ok"] == s["green"]
    assert s["warn"] == s["yellow"]
    assert s["fail"] == s["red"]
    for c in dados["checks"]:
        assert c["severity"] in ("OK", "WARN", "FAIL", "SKIP")
        assert c["module"] == c["suite"], "module e o nome antigo de suite"


def test_resumo_por_suite_reflete_a_pior_cor(host_bind):
    host_bind.caso("systemctl", "is-active named", 0, "failed\n")
    dados, _p = host_bind.json("--deep")
    assert dados["suites"]["bind"]["status"] == "RED"
    assert dados["suites"]["core"]["status"] == "GREEN"


def test_suite_so_com_skip_aparece_como_skip(host_vazio):
    dados, _p = host_vazio.json("--only", "bind")
    assert dados["suites"]["bind"]["status"] == "SKIP"


# =============================================================================
# JSON — escape
# =============================================================================
def test_valor_com_tab_nao_quebra_o_json(host_bind):
    """O caso real que quebrava: sysctl multivalor vem do kernel com TAB.

    TAB cru dentro de string e JSON invalido. O `jq` do agregador engolia o
    arquivo em silencio e o host sumia do relatorio da frota como se
    estivesse ok — a pior falha possivel num painel.
    """
    host_bind.caso("sysctl", "-n net.ipv4.udp_mem", 0, "1\t2\t3\n")
    dados, _p = host_bind.json("--only", "tuning")
    caso = next(c for c in dados["checks"] if c["id"] == "tuning.deriva")
    assert caso["status"] == "YELLOW"
    assert "\t" not in caso["actual"] or json.dumps(caso["actual"])


@pytest.mark.parametrize(
    "hostil,rotulo",
    [
        ('aspa " no meio', "aspa"),
        ("barra \\ invertida", "barra"),
        ('json falso: {"a": 1}', "chaves"),
        ("pipe | e ponto-e-virgula ;", "separadores"),
        ("unidade\x1fseparadora", "separador interno"),
        ("acentuado: configuração", "utf-8"),
        ("controle\x07sino", "controle"),
    ],
    ids=lambda v: v if isinstance(v, str) and len(v) < 20 else "",
)
def test_conteudo_hostil_sai_como_json_valido(host_bind, hostil, rotulo):
    """O detalhe do caso vem de saida de comando: nao da para confiar nela.

    O separador interno de registro (0x1f) esta na lista de proposito: se
    vazar de uma saida de comando para dentro do registro, os campos do JSON
    saem trocados de lugar e ninguem percebe.
    """
    host_bind.caso("systemctl", "is-active named", 0, f"{hostil}\n")
    dados, proc = host_bind.json("--only", "bind")   # json() ja falha se nao parsear
    caso = next(c for c in dados["checks"] if c["id"] == "bind.servico")
    assert caso["status"] == "RED"
    assert proc.returncode == 2


def test_separador_interno_nao_desloca_os_campos(host_bind):
    """0x1f vindo de fora nao pode partir o registro em campos extras."""
    host_bind.caso("systemctl", "is-active named", 0, "ativo\x1fRED\x1finjetado\n")
    dados, _p = host_bind.json("--only", "bind")
    caso = next(c for c in dados["checks"] if c["id"] == "bind.servico")
    assert caso["name"] == "servico named", f"campo deslocado: {caso}"
    assert caso["expected"] == "active"


def test_json_e_parseavel_com_a_suite_inteira_em_falha(host_bind):
    """O pior caso para o gerador: tudo vermelho, todo campo preenchido."""
    host_bind.caso("systemctl", "is-active named", 0, 'quebrado "com" aspas\n')
    host_bind.caso("named-checkconf", "-z *", 1, "erro: linha 3\\4 invalida\n")
    host_bind.caso("ss", "-lnt", 0, "")
    host_bind.caso("ss", "-lnu", 0, "")
    dados, proc = host_bind.json("--only", "bind", "--deep")
    assert dados["summary"]["fail"] >= 4
    assert proc.returncode == 2


# =============================================================================
# relatorio
# =============================================================================
def test_relatorio_declara_veredito_ok(host_bind):
    proc = host_bind.roda("--report", "--deep")
    assert proc.returncode == 0
    assert "**Veredito**" in proc.stdout
    assert "OK — nada a fazer" in proc.stdout


def test_relatorio_declara_veredito_de_falha_e_lista_o_que_fazer(host_bind):
    host_bind.caso("systemctl", "is-active named", 0, "failed\n")
    proc = host_bind.roda("--report", "--only", "bind")
    assert proc.returncode == 2
    assert "NAO OK — ha falha" in proc.stdout
    assert "Falhas (RED)" in proc.stdout
    assert "bind.servico" in proc.stdout
    assert "journalctl -u named" in proc.stdout, "o relatorio tem de trazer a correcao"


def test_relatorio_tem_placar_e_tabela_por_modulo(host_bind):
    proc = host_bind.roda("--report", "--deep")
    for esperado in ("## Placar", "## Por modulo", "## Todos os casos",
                     "| GREEN | YELLOW | RED | SKIP |"):
        assert esperado in proc.stdout, f"falta '{esperado}' no relatorio"


def test_relatorio_escapa_pipe_para_nao_quebrar_a_tabela(host_bind):
    """Detalhe com '|' parte a coluna e o markdown vira lixo visual.

    Conta so o pipe NAO escapado: e ele que o renderizador trata como
    separador de celula.
    """
    host_bind.caso("systemctl", "is-active named", 0, "a | b | c\n")
    proc = host_bind.roda("--report", "--only", "bind")
    linha = next(l for l in proc.stdout.splitlines() if "`bind.servico`" in l)
    separadores = len(re.findall(r"(?<!\\)\|", linha))
    assert separadores == 6, (
        f"esperadas 5 colunas (6 separadores), vieram {separadores}: {linha}"
    )
    assert r"a \| b \| c" in linha, "o pipe do conteudo tem de sair escapado"


def test_relatorio_nao_emite_json(host_bind):
    proc = host_bind.roda("--report", "--only", "core")
    assert not proc.stdout.lstrip().startswith("{")


# =============================================================================
# quiet
# =============================================================================
def test_quiet_esconde_o_verde_e_mantem_o_vermelho(host_bind):
    host_bind.caso("systemctl", "is-active named", 0, "failed\n")
    proc = host_bind.roda("--quiet", "--only", "bind")
    assert "RED" in proc.stdout
    assert "GREEN  porta 53/udp" not in proc.stdout
    assert proc.returncode == 2


def test_saida_humana_usa_o_vocabulario_red_green(host_bind):
    proc = host_bind.roda("--only", "core")
    assert "GREEN" in proc.stdout
    assert "veredito:" in proc.stdout


def test_saida_humana_avisa_que_a_camada_ativa_nao_rodou(host_bind):
    """Sem o aviso, 'tudo verde' sem --deep passa impressao errada."""
    proc = host_bind.roda("--only", "bind")
    assert "--deep" in proc.stdout
