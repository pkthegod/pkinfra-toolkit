"""Testes funcionais da biblioteca lib/pkops.sh.

Roda o bash de verdade contra um PK_ROOT descartavel — sem mock. A camada de
estado e o que os outros seis scripts consomem; quebrar aqui quebra tudo.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

RAIZ = Path(__file__).resolve().parent.parent
PKOPS = RAIZ / "lib" / "pkops.sh"


def _bash():
    if os.name == "nt":
        for git_bash in (
            r"C:\Program Files\Git\bin\bash.exe",
            r"C:\Program Files (x86)\Git\bin\bash.exe",
        ):
            if Path(git_bash).exists():
                return git_bash
    achado = shutil.which("bash")
    if achado and "System32" not in achado:
        return achado
    if Path("/usr/bin/bash").exists():
        return "/usr/bin/bash"
    pytest.skip("bash utilizavel indisponivel")


def _roda(script: str, pk_root: Path) -> subprocess.CompletedProcess:
    """Executa um trecho com pkops.sh carregado e PK_ROOT isolado."""
    prelude = (
        "set +u\n"
        f'export PK_ROOT="{pk_root.as_posix()}"\n'
        "TOOL=teste; VERSION=0.1\n"
        f'. "{PKOPS.as_posix()}" 2>/dev/null\n'
    )
    return subprocess.run(
        [_bash(), "-c", prelude + script],
        capture_output=True,
        text=True,
        cwd=str(RAIZ),
    )


@pytest.fixture
def pk_root(tmp_path):
    raiz = tmp_path / "pkops"
    (raiz / "state").mkdir(parents=True)
    return raiz


def test_state_list_vazio_nao_imprime_nada(pk_root):
    """Diretorio sem estado deve sair silencioso, nao ecoar o padrao do glob."""
    proc = _roda("pk_state_list", pk_root)
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == "", f"esperado vazio, veio: {proc.stdout!r}"


def test_state_list_devolve_nomes_sem_extensao(pk_root):
    for nome in ("tuning", "upgrade", "unbound"):
        (pk_root / "state" / f"{nome}.env").touch()

    proc = _roda("pk_state_list", pk_root)
    assert proc.returncode == 0, proc.stderr
    assert sorted(proc.stdout.split()) == ["tuning", "unbound", "upgrade"]


def test_state_list_preserva_nome_com_espaco(pk_root):
    """O `ls -1 | xargs basename` antigo cortava aqui — um nome virava dois.

    Guarda o SC2011 corrigido: nome com espaco tem de sair como UMA linha.
    """
    (pk_root / "state" / "com espaco.env").touch()
    (pk_root / "state" / "simples.env").touch()

    proc = _roda("pk_state_list", pk_root)
    assert proc.returncode == 0, proc.stderr
    linhas = [l for l in proc.stdout.splitlines() if l.strip()]
    assert sorted(linhas) == ["com espaco", "simples"], (
        f"nome com espaco foi partido: {linhas}"
    )


def test_state_list_nao_vaza_nullglob_para_o_chamador(pk_root):
    """A funcao liga nullglob; deixar ligado muda o glob de quem a chamou."""
    proc = _roda(
        "shopt -u nullglob\n"
        "pk_state_list >/dev/null\n"
        "shopt -q nullglob && echo VAZOU || echo PRESERVADO\n",
        pk_root,
    )
    assert proc.returncode == 0, proc.stderr
    assert "PRESERVADO" in proc.stdout, proc.stdout


def test_state_list_respeita_nullglob_previamente_ligado(pk_root):
    """Se o chamador ja tinha nullglob ligado, tem de continuar ligado."""
    proc = _roda(
        "shopt -s nullglob\n"
        "pk_state_list >/dev/null\n"
        "shopt -q nullglob && echo MANTIDO || echo DESLIGOU\n",
        pk_root,
    )
    assert proc.returncode == 0, proc.stderr
    assert "MANTIDO" in proc.stdout, proc.stdout


def test_biblioteca_sobrevive_a_set_e_do_chamador(pk_root):
    """pkops.sh e sourceado por scripts de terceiros; `set -e` e comum.

    A versao anterior fazia `shopt -q nullglob; local x=$?` — e `shopt -q`
    retorna 1 quando a opcao esta desligada, o que sob `set -e` derrubava o
    script do chamador na primeira chamada a pk_state_list. Falha do tipo
    mais caro: quem chamou apanha sem entender por que.
    """
    (pk_root / "state" / "tuning.env").touch()
    proc = _roda(
        "set -e\n"
        "pk_state_list >/dev/null\n"
        "pk_sysctl_norm 'a b' >/dev/null\n"
        "echo CHEGOU_AO_FIM\n",
        pk_root,
    )
    assert "CHEGOU_AO_FIM" in proc.stdout, (
        f"biblioteca abortou sob set -e (exit={proc.returncode}): {proc.stderr}"
    )


def test_state_list_funciona_com_diretorio_vazio_e_set_e(pk_root):
    """Diretorio vazio e o caminho onde o glob nao casa — o mais arriscado."""
    proc = _roda("set -e\npk_state_list\necho FIM\n", pk_root)
    assert "FIM" in proc.stdout, (
        f"abortou com state/ vazio sob set -e: {proc.stderr}"
    )
    assert proc.stdout.strip() == "FIM", f"imprimiu lixo: {proc.stdout!r}"


def test_norm_sysctl_trata_tab_como_espaco(pk_root):
    """Bug 29 do catalogo: o kernel separa sysctl multivalor com TAB.

    `tr -s ' '` nao converte tab, entao a comparacao declarado x efetivo
    acusava deriva inexistente em udp_mem, tcp_rmem e ip_local_port_range —
    o operador reaplicava tuning que ja estava aplicado.
    """
    proc = _roda(
        # valores reais como o kernel os devolve: separados por TAB
        'com_tab=$(printf "189141\\t252188\\t378282")\n'
        'com_espaco="189141 252188 378282"\n'
        'a=$(pk_sysctl_norm "$com_tab")\n'
        'b=$(pk_sysctl_norm "$com_espaco")\n'
        'printf "a=[%s]\\nb=[%s]\\n" "$a" "$b"\n',
        pk_root,
    )
    assert proc.returncode == 0, proc.stderr
    # Compara com o literal esperado, nao apenas a == b: com a funcao ausente
    # os dois sairiam vazios e o teste passaria sem nada implementado.
    assert "a=[189141 252188 378282]" in proc.stdout, proc.stdout
    assert "b=[189141 252188 378282]" in proc.stdout, proc.stdout


def test_norm_sysctl_apara_bordas_e_colapsa_repeticao(pk_root):
    """Borda com espaco e o outro jeito de gerar deriva fantasma."""
    proc = _roda(
        'r=$(pk_sysctl_norm "$(printf "  4096\\t\\t87380   6291456  ")")\n'
        'printf "[%s]\\n" "$r"\n',
        pk_root,
    )
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == "[4096 87380 6291456]", proc.stdout


def test_norm_sysctl_existe_como_funcao(pk_root):
    """Guarda contra teste que passa por ausencia.

    Varios testes deste grupo comparam saidas entre si; com a funcao
    inexistente todas sairiam vazias e as comparacoes fechariam. Este fixa
    que a funcao existe de fato.
    """
    proc = _roda('declare -F pk_sysctl_norm >/dev/null && echo EXISTE\n', pk_root)
    assert proc.returncode == 0, proc.stderr
    assert "EXISTE" in proc.stdout, "pk_sysctl_norm nao esta definida em lib/pkops.sh"


def test_norm_sysctl_aceita_valor_vazio(pk_root):
    """Chave sem valor nao pode explodir sob `set -u`."""
    proc = _roda(
        'declare -F pk_sysctl_norm >/dev/null || { echo AUSENTE; exit 0; }\n'
        'r=$(pk_sysctl_norm ""); printf "[%s]\\n" "$r"\n',
        pk_root,
    )
    assert proc.returncode == 0, proc.stderr
    assert "AUSENTE" not in proc.stdout, "pk_sysctl_norm nao esta definida"
    assert proc.stdout.strip() == "[]", proc.stdout


def test_state_set_e_get_fazem_ida_e_volta(pk_root):
    """Contrato basico da camada: o que pk_state_set grava, pk_state_get le."""
    proc = _roda(
        "pk_init >/dev/null 2>&1\n"
        'pk_state_set tuning profile=dns kernel=6.1.0-test\n'
        "pk_state_get tuning profile\n",
        pk_root,
    )
    assert proc.returncode == 0, proc.stderr
    assert "dns" in proc.stdout, proc.stdout
