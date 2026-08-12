"""Cobertura da matriz: nenhum caso de validacao fica sem teste de falha.

Este e o teste que fecha o conjunto. Os outros arquivos provam que CADA
defeito injetado acende a cor certa; este prova que nao existe caso da suite
sem defeito injetado.

Sem ele, a suite cresce e a matriz nao: alguem acrescenta uma checagem nova,
ela nunca e exercitada em falha, e o primeiro incidente descobre que ela nunca
funcionou. Aqui, adicionar um caso a `validate.sh` sem adicionar o teste
correspondente quebra o CI na hora — com o id do caso na mensagem.

Duas camadas:
  1. todo id emitido pela suite aparece em algum lugar de tests/
  2. todo id que PODE ficar RED/YELLOW tem um defeito declarado na matriz,
     ou uma isencao com motivo escrito
"""

import re
from pathlib import Path

import pytest

import test_validate_bind as t_bind
import test_validate_core as t_core
import test_validate_servicos as t_srv
from conftest import RAIZ

VALIDATE = RAIZ / "bin" / "validate.sh"
FONTE = VALIDATE.read_text(encoding="utf-8")
TESTES = Path(__file__).parent

# Emissores de caso. Se um novo for criado em validate.sh sem entrar aqui, o
# primeiro assert deste arquivo cai — de proposito.
#
# `caso_porta` esta na lista porque tambem emite: por dentro ele chama
# `verde`/`vermelho` com o id em "$1", que o extrator nao enxerga. Sem ele aqui
# os quatro casos de porta ficariam invisiveis para a matriz — e a suite
# passaria a ter checagem de socket sem prova de que detecta socket ausente.
EMISSORES = ("verde", "vermelho", "amarelo", "pulado", "afere", "afere_min",
             "afere_max", "caso_porta")
ACENDEM = ("vermelho", "amarelo", "afere", "afere_min", "afere_max", "caso_porta")


def _extrai(emissores):
    """Devolve (ids literais, prefixos de id montado em laco).

    Alguns casos tem o id construido: `afere "pve.servico.${s}"` dentro de um
    for. O id final so existe em tempo de execucao, entao aqui guarda-se o
    PREFIXO literal e a cobertura e conferida por prefixo. Tratar isso a mao e
    melhor do que o extrator ignorar a linha em silencio e a suite passar a
    ter casos invisiveis para a matriz.
    """
    alt = "|".join(emissores)
    literais = set(re.findall(rf'\b(?:{alt})\s+"([a-z0-9][a-z0-9._-]*)"', FONTE))
    prefixos = set(re.findall(rf'\b(?:{alt})\s+"([a-z0-9][a-z0-9._-]*\.)\$\{{', FONTE))
    return literais, prefixos


IDS, PREFIXOS = _extrai(EMISSORES)
IDS_ACENDEM, PREFIXOS_ACENDEM = _extrai(ACENDEM)


def existe(id_caso: str) -> bool:
    return id_caso in IDS or any(id_caso.startswith(p) for p in PREFIXOS)


def alvos_testados() -> set:
    """Ids cobertos por um defeito declarado nas matrizes RED/GREEN."""
    matrizes = (
        t_bind.DEFEITOS_PASSIVOS,
        t_bind.DEFEITOS_ATIVOS,
        t_core.DEFEITOS,
        t_srv.DEFEITOS_UNBOUND,
        t_srv.DEFEITOS_DOCKER,
        t_srv.DEFEITOS_ZABBIX,
        t_srv.DEFEITOS_PVE,
    )
    return {d[2] for m in matrizes for d in m}


# Casos sem defeito na matriz, cada um com o motivo. Nao e lista de perdao: e
# documentacao do que a matriz nao consegue cobrir e por que. Toda entrada
# aponta o teste dedicado que faz o papel dela.
ISENTOS = {
    "bind.zonas":
        "acompanha bind.q.serial; coberto por test_zona_invalida_falha_e_derruba_a_comparacao_de_serial",
    "bind.q.cache":
        "precisa de duas respostas diferentes na mesma execucao; "
        "coberto por test_cache_ttl_crescente_acende_amarelo",
    "bind.q.latencia":
        "depende de tempo real; coberto por test_latencia_de_cache_respeita_o_orcamento",
    "unbound.q.latencia":
        "mesmo motivo de bind.q.latencia; o limiar e o mesmo codigo (afere_max)",
    "core.sysctl.conf":
        "so acende no Debian 13; coberto por test_sysctl_conf_com_conteudo_ativo_e_falha_no_debian_13",
    "tuning.perfil":
        "amarelo por ausencia de estado; coberto por test_sem_perfil_aplicado_o_tuning_avisa_e_nao_falha",
    "tuning.pve":
        "so existe em host Proxmox com estado por kernel; "
        "coberto por test_tuning_de_host_pve_e_cobrado_por_kernel",
    "zabbix.thp":
        "so existe com postgresql presente; coberto por test_thp_com_postgresql_exige_never",
    "pve.quorum":
        "so existe em cluster; coberto por test_cluster_sem_quorum_e_falha",
}


def test_o_padrao_de_extracao_ainda_encontra_casos():
    """Guarda contra teste que passa por vazio.

    Se o jeito de emitir caso mudar em validate.sh e este padrao parar de
    casar, todos os asserts abaixo passariam sobre conjuntos vazios — o pior
    tipo de teste verde.
    """
    assert len(IDS) >= 50, f"so {len(IDS)} ids extraidos; o padrao ficou obsoleto"
    for esperado in ("bind.q.axfr", "core.disco", "unbound.trustanchor"):
        assert esperado in IDS, f"{esperado} nao foi extraido do fonte"
    assert PREFIXOS, "o extrator deixou de reconhecer id montado em laco"


def test_toda_matriz_aponta_para_caso_que_existe():
    """Defeito mirando id inexistente e teste que nao testa nada.

    Acontece ao renomear um caso: a matriz continua verde porque o teste
    injeta o defeito e afere um id que a suite nunca emite.
    """
    fantasmas = {i for i in alvos_testados() if not existe(i)}
    assert not fantasmas, (
        f"a matriz aponta para ids que a suite nao emite: {sorted(fantasmas)}"
    )


def test_toda_isencao_aponta_para_caso_que_existe():
    fantasmas = {i for i in ISENTOS if not existe(i)}
    assert not fantasmas, (
        f"isencao para id inexistente (renomeado ou removido?): {sorted(fantasmas)}"
    )


def test_nenhuma_isencao_sobra_depois_de_entrar_na_matriz():
    """Isencao que virou teste de verdade tem de sair da lista."""
    redundantes = set(ISENTOS) & alvos_testados()
    assert not redundantes, (
        f"estes ids ja estao na matriz e nao precisam mais de isencao: {sorted(redundantes)}"
    )


def test_todo_caso_que_pode_falhar_tem_teste_de_falha():
    """O contrato central: nenhuma validacao entra sem prova de que detecta."""
    cobertos = alvos_testados() | set(ISENTOS)
    descobertos = IDS_ACENDEM - cobertos
    # id montado em laco: basta um irmao coberto para o ramo estar exercitado
    for p in PREFIXOS_ACENDEM:
        if not any(i.startswith(p) for i in cobertos):
            descobertos.add(p + "*")
    assert not descobertos, (
        "casos sem teste de falha:\n  "
        + "\n  ".join(sorted(descobertos))
        + "\n\nAcrescente um defeito na matriz do modulo correspondente, ou "
        "uma entrada em ISENTOS com o motivo e o teste dedicado."
    )


def test_todo_id_da_suite_e_citado_em_algum_teste():
    """Camada mais larga: nenhum caso passa despercebido, nem os informativos.

    Caso informativo tambem aparece no relatorio e no painel. Se ninguem o
    cita em teste nenhum, ele pode sumir num refactor sem que nada acuse.
    """
    corpo = "\n".join(
        p.read_text(encoding="utf-8")
        for p in TESTES.glob("test_*.py")
        if p.name != Path(__file__).name
    )
    orfaos = {i for i in IDS if f'"{i}"' not in corpo}
    assert not orfaos, (
        "ids que nenhum teste menciona:\n  " + "\n  ".join(sorted(orfaos))
    )


@pytest.mark.parametrize(
    "modulo", ["core", "tuning", "bind", "unbound", "zabbix", "docker", "pve"]
)
def test_cada_modulo_tem_cobertura_de_falha(modulo):
    """Modulo inteiro sem um unico teste de falha e ponto cego de suite."""
    prefixo = modulo + "."
    do_modulo = {i for i in IDS_ACENDEM if i.startswith(prefixo)}
    assert do_modulo, f"o modulo {modulo} nao tem caso que possa falhar"
    cobertos = do_modulo & (alvos_testados() | set(ISENTOS))
    assert cobertos, f"o modulo {modulo} nao tem nenhum teste de falha"


def test_id_segue_a_convencao_de_nome():
    """`modulo.assunto` em minusculas — o id vai para painel e para alerta.

    Id fora do padrao quebra filtro de dashboard escrito por prefixo, que e
    como o operador separa o que e DNS do que e disco.
    """
    prefixos = ("core.", "tuning.", "bind.", "unbound.", "zabbix.", "docker.", "pve.")
    fora = {i for i in IDS | PREFIXOS if not i.startswith(prefixos)}
    assert not fora, f"ids fora da convencao modulo.assunto: {sorted(fora)}"
    assert all(i == i.lower() for i in IDS)


def test_todo_caso_vermelho_ou_amarelo_do_fonte_traz_correcao():
    """RED sem 'o que fazer' transfere o problema em vez de resolver.

    Cobre tambem os ramos que nenhum cenario de teste alcanca: aqui a leitura
    e do fonte, nao da execucao.
    """
    sem_fix = []
    # cada chamada de `vermelho`/`amarelo` ocupa de 1 a 3 linhas fisicas;
    # junta as continuacoes antes de contar os argumentos
    unido = re.sub(r"\\\n\s*", " ", FONTE)
    for m in re.finditer(r'\b(vermelho|amarelo)\s+"([a-z0-9._-]+)"(.*)', unido):
        cid, resto = m.group(2), m.group(3)
        # 4 argumentos depois do id = titulo, esperado, obtido, correcao
        if len(re.findall(r'"[^"]*"', resto)) < 4:
            sem_fix.append(cid)
    # `caso_porta` monta o RED por dentro, entao o laco acima nao o alcanca: a
    # correcao dele e o 5o argumento da chamada, e sem ela o operador recebe
    # "sem socket" e nenhum caminho a seguir.
    for m in re.finditer(r'\bcaso_porta\s+"([a-z0-9._-]+)"(.*)', unido):
        # 2 argumentos citados depois do id = titulo e correcao (proto e porta
        # entram sem aspas)
        if len(re.findall(r'"[^"]*"', m.group(2))) < 2:
            sem_fix.append(m.group(1))
    assert not sem_fix, (
        f"casos que acendem sem instrucao de correcao: {sorted(set(sem_fix))}"
    )
