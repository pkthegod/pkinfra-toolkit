"""Testes funcionais da biblioteca lib/pkops.sh.

Roda o bash de verdade contra um PK_ROOT descartavel — sem mock. A camada de
estado e o que os outros scripts consomem; quebrar aqui quebra tudo, e sempre
em outro lugar, o que torna a falha cara de diagnosticar.

Tres frentes:
  biblioteca  pk_state_*, pk_stale, pk_sysctl_norm, pk_json_esc
  eventos     formato da linha e disparo dos hooks
  CLI         drift, manifest, timeline, exit codes
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from conftest import RAIZ, PKOPS, bash, roda_bash


def _roda(script: str, pk_root: Path, env=None) -> subprocess.CompletedProcess:
    """Executa um trecho com pkops.sh carregado e PK_ROOT isolado."""
    prelude = (
        "set +u\n"
        f'export PK_ROOT="{pk_root.as_posix()}"\n'
        f'export PK_HOOKS="{(pk_root / "hooks.d").as_posix()}"\n'
        "TOOL=teste; VERSION=0.1\n"
        f'. "{PKOPS.as_posix()}" 2>/dev/null\n'
    )
    amb = os.environ.copy()
    amb.update(env or {})
    return roda_bash([bash(), "-c", prelude + script], env=amb)


def _cli(pk_root: Path, *args, env=None) -> subprocess.CompletedProcess:
    """Executa pkops.sh como CLI."""
    amb = os.environ.copy()
    amb["PK_ROOT"] = pk_root.as_posix()
    amb["PK_HOOKS"] = (pk_root / "hooks.d").as_posix()
    amb.update(env or {})
    return roda_bash([bash(), PKOPS.as_posix(), *args], env=amb)


@pytest.fixture
def pk_root(tmp_path):
    raiz = tmp_path / "pkops"
    (raiz / "state").mkdir(parents=True)
    return raiz


# =============================================================================
# pk_state_list
# =============================================================================
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
        "pk_json_esc 'x' >/dev/null\n"
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


# =============================================================================
# pk_sysctl_norm
# =============================================================================
def test_norm_sysctl_trata_tab_como_espaco(pk_root):
    """Bug 29 do catalogo: o kernel separa sysctl multivalor com TAB.

    `tr -s ' '` nao converte tab, entao a comparacao declarado x efetivo
    acusava deriva inexistente em udp_mem, tcp_rmem e ip_local_port_range —
    o operador reaplicava tuning que ja estava aplicado.
    """
    proc = _roda(
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


def test_norm_sysctl_nao_iguala_valores_diferentes(pk_root):
    """A normalizacao nao pode esconder deriva real."""
    proc = _roda(
        'a=$(pk_sysctl_norm "$(printf "4096\\t87380\\t6291456")")\n'
        'b=$(pk_sysctl_norm "4096 87380 999")\n'
        '[[ "$a" == "$b" ]] && echo IGUAIS || echo DIFERENTES\n',
        pk_root,
    )
    assert "DIFERENTES" in proc.stdout, proc.stdout


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


# =============================================================================
# pk_json_esc
# =============================================================================
@pytest.mark.parametrize(
    "bruto",
    [
        'aspa " no meio',
        "barra \\ invertida",
        "barra e aspa \\\" juntas",
        "tab\tno meio",
        "quebra\nde linha",
        "retorno\rde carro",
        "controle\x01baixo",
        "sino\x07",
        "acentuado: configuração",
        "",
    ],
    ids=["aspa", "barra", "barra+aspa", "tab", "quebra", "cr", "ctrl", "sino", "utf8", "vazio"],
)
def test_json_esc_produz_string_json_valida(pk_root, bruto):
    """O escapador e o que separa 'JSON do toolkit' de 'arquivo que o jq ignora'.

    Escapar so a aspa — o que os scripts faziam — deixa passar TAB e barra
    invertida, e valor de sysctl vem do kernel com TAB.
    """
    b64 = __import__("base64").b64encode(bruto.encode("utf-8")).decode("ascii")
    proc = _roda(
        f'v=$(base64 -d <<< "{b64}")\n'
        'printf \'{"v":"%s"}\' "$(pk_json_esc "$v")"\n',
        pk_root,
    )
    assert proc.returncode == 0, proc.stderr
    obj = json.loads(proc.stdout)   # levanta se o escape estiver errado
    assert obj["v"] == bruto, f"ida e volta perdeu conteudo: {obj['v']!r} != {bruto!r}"


def test_json_esc_nao_duplica_escape_de_barra(pk_root):
    """Ordem importa: a barra tem de ser escapada ANTES da aspa."""
    proc = _roda(
        r"""printf '{"v":"%s"}' "$(pk_json_esc 'c:\caminho')" """ + "\n",
        pk_root,
    )
    assert json.loads(proc.stdout)["v"] == "c:\\caminho"


# =============================================================================
# estado
# =============================================================================
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


def test_state_set_preserva_chave_que_nao_foi_reescrita(pk_root):
    """Gravar 'profile' nao pode apagar o que outro script gravou antes.

    Os scripts do toolkit escrevem no MESMO componente em momentos
    diferentes; se o segundo zerasse o arquivo, o manifest perderia metade da
    informacao sem ninguem notar.
    """
    proc = _roda(
        "pk_init >/dev/null 2>&1\n"
        "pk_state_set tuning profile=dns origem=pkassess >/dev/null\n"
        "pk_state_set tuning profile=proxy >/dev/null\n"
        "pk_state_get tuning origem\n"
        "pk_state_get tuning profile\n",
        pk_root,
    )
    saida = proc.stdout.split()
    assert "pkassess" in saida, f"chave antiga foi perdida: {proc.stdout!r}"
    assert "proxy" in saida, f"chave nova nao foi gravada: {proc.stdout!r}"


def test_state_set_nao_deixa_valor_duplicado_no_arquivo(pk_root):
    """Reescrever a mesma chave nao pode empilhar linhas: `grep | head -1`
    esconderia o problema ate o arquivo virar um log."""
    _roda(
        "pk_init >/dev/null 2>&1\n"
        "pk_state_set tuning profile=a >/dev/null\n"
        "pk_state_set tuning profile=b >/dev/null\n"
        "pk_state_set tuning profile=c >/dev/null\n",
        pk_root,
    )
    conteudo = (pk_root / "state" / "tuning.env").read_text(encoding="utf-8")
    assert conteudo.count("profile=") == 1, conteudo
    assert "profile=c" in conteudo


def test_stale_detecta_kernel_diferente(pk_root):
    proc = _roda(
        "pk_init >/dev/null 2>&1\n"
        "pk_state_set tuning profile=dns >/dev/null\n"
        "pk_stale tuning && echo DEFASADO || echo COERENTE\n"
        # reescreve o kernel gravado para um valor impossivel
        'sed -i "s/^PK_KERNEL=.*/PK_KERNEL=0.0.0-inexistente/" "$PK_STATE/tuning.env"\n'
        "pk_stale tuning && echo DEFASADO || echo COERENTE\n",
        pk_root,
    )
    linhas = proc.stdout.split()
    assert linhas == ["COERENTE", "DEFASADO"], proc.stdout


def test_stale_em_componente_inexistente_nao_e_defasado(pk_root):
    """Ausencia de estado nao pode ser lida como estado defasado."""
    proc = _roda("pk_stale naoexiste && echo DEFASADO || echo NAO\n", pk_root)
    assert "NAO" in proc.stdout


# =============================================================================
# eventos e hooks
# =============================================================================
def test_evento_tem_seis_campos_na_ordem_do_contrato(pk_root):
    """ISO8601|host|tool|versao|evento|detalhe.

    O formato e consumido pelo `pkops timeline`, pelos hooks e por scripts do
    operador. Trocar a ordem de dois campos nao quebra nada visivelmente — so
    passa a mostrar a informacao errada.
    """
    _roda('pk_init >/dev/null 2>&1\npk_emit "teste.evento" "detalhe=x"\n', pk_root)
    linha = (pk_root / "events.log").read_text(encoding="utf-8").strip().splitlines()[-1]
    campos = linha.split("|")
    assert len(campos) == 6, f"esperados 6 campos, vieram {len(campos)}: {linha}"
    assert campos[0].startswith("20"), campos[0]
    assert campos[2] == "teste", "campo 3 e a ferramenta que emitiu"
    assert campos[3] == "0.1", "campo 4 e a versao da ferramenta"
    assert campos[4] == "teste.evento"
    assert campos[5] == "detalhe=x"


def test_hook_executavel_recebe_evento_detalhe_e_timestamp(pk_root):
    hooks = pk_root / "hooks.d"
    hooks.mkdir(parents=True, exist_ok=True)
    alvo = pk_root / "hook-viu.txt"
    h = hooks / "10-espia.sh"
    h.write_text(
        "#!/usr/bin/env bash\n"
        f'printf "%s|%s|%s|%s\\n" "$1" "$2" "$3" "$PK_TOOL" > "{alvo.as_posix()}"\n',
        encoding="utf-8", newline="\n",
    )
    os.chmod(h, 0o755)

    _roda('pk_init >/dev/null 2>&1\npk_emit "algo.aconteceu" "chave=valor"\n', pk_root)
    assert alvo.exists(), "o hook executavel nao foi disparado"
    ev, det, ts, tool = alvo.read_text(encoding="utf-8").strip().split("|")
    assert ev == "algo.aconteceu"
    assert det == "chave=valor"
    assert ts.startswith("20")
    assert tool == "teste", "PK_TOOL tem de chegar no ambiente do hook"


def test_hook_sem_bit_de_execucao_nao_roda(pk_root, bit_de_execucao_adere):
    """Arquivo sem +x e o jeito documentado de manter um hook desativado."""
    hooks = pk_root / "hooks.d"
    hooks.mkdir(parents=True, exist_ok=True)
    alvo = pk_root / "nao-deveria.txt"
    h = hooks / "20-inerte.sh"
    h.write_text(f'#!/usr/bin/env bash\ntouch "{alvo.as_posix()}"\n',
                 encoding="utf-8", newline="\n")
    os.chmod(h, 0o644)

    _roda('pk_init >/dev/null 2>&1\npk_emit "x" "y"\n', pk_root)
    assert not alvo.exists(), "hook sem bit de execucao foi executado"


def test_hook_que_falha_nao_derruba_quem_emitiu(pk_root):
    """Callback do operador nao pode virar ponto unico de falha do toolkit."""
    hooks = pk_root / "hooks.d"
    hooks.mkdir(parents=True, exist_ok=True)
    h = hooks / "30-explode.sh"
    h.write_text("#!/usr/bin/env bash\nexit 42\n", encoding="utf-8", newline="\n")
    os.chmod(h, 0o755)

    proc = _roda(
        'pk_init >/dev/null 2>&1\n'
        'pk_emit "x" "y"\n'
        'echo SOBREVIVEU\n',
        pk_root,
    )
    assert "SOBREVIVEU" in proc.stdout, proc.stderr
    log = (pk_root / "events.log").read_text(encoding="utf-8")
    assert "hook.failed" in log, "a falha do hook tem de ficar registrada"
    assert "rc=42" in log, "o codigo de saida do hook tem de ir para o log"


def test_pk_no_hooks_desliga_o_disparo(pk_root):
    """Valvula para rodar o toolkit sem acionar integracao externa."""
    hooks = pk_root / "hooks.d"
    hooks.mkdir(parents=True, exist_ok=True)
    alvo = pk_root / "disparou.txt"
    h = hooks / "10-marca.sh"
    h.write_text(f'#!/usr/bin/env bash\ntouch "{alvo.as_posix()}"\n',
                 encoding="utf-8", newline="\n")
    os.chmod(h, 0o755)

    _roda('pk_init >/dev/null 2>&1\npk_emit "x" "y"\n', pk_root,
          env={"PK_NO_HOOKS": "1"})
    assert not alvo.exists(), "PK_NO_HOOKS=1 nao impediu o disparo"


# =============================================================================
# CLI
# =============================================================================
def test_cli_sem_argumento_mostra_ajuda(pk_root):
    proc = _cli(pk_root)
    assert proc.returncode == 0
    assert "pkops" in proc.stdout


def test_cli_comando_desconhecido_sai_dois(pk_root):
    proc = _cli(pk_root, "invencao")
    assert proc.returncode == 2
    assert "desconhecido" in proc.stdout


def test_drift_sem_estado_nao_acusa_falha(pk_root):
    """Host recem-instalado nao tem deriva de componente nenhum.

    Nao se exige exit 0: `pkops drift` avisa que os fatos nunca foram
    coletados, e esse aviso e legitimo num host que so rodou o instalador. O
    que nao pode acontecer e FAIL (exit 2) sem nada aplicado.
    """
    proc = _cli(pk_root, "drift")
    assert proc.returncode != 2, f"FAIL sem nenhum estado declarado:\n{proc.stdout}"
    assert "FAIL 0" in proc.stdout, proc.stdout


def test_drift_acusa_estado_de_outro_kernel(pk_root):
    """Componente aplicado em kernel diferente e WARN — exit 1, nunca 0.

    Usa um componente que nao seja 'tuning' de proposito: o checador de perfil
    de sysctl olha o /etc do host de verdade e, fora de um Debian tunado, o
    arquivo do perfil nao existe — o FAIL dele mascararia o WARN que este
    teste quer medir.
    """
    _roda("pk_init >/dev/null 2>&1\npk_state_set upgrade alvo=9 >/dev/null\n", pk_root)
    env = pk_root / "state" / "upgrade.env"
    linhas = [
        "PK_KERNEL=0.0.0-inexistente" if l.startswith("PK_KERNEL=") else l
        for l in env.read_text(encoding="utf-8").splitlines()
    ]
    env.write_text("\n".join(linhas) + "\n", encoding="utf-8", newline="\n")

    proc = _cli(pk_root, "drift")
    assert proc.returncode == 1, f"deriva de kernel tem de sair 1:\n{proc.stdout}"
    assert "upgrade" in proc.stdout
    assert "0.0.0-inexistente" in proc.stdout, "o kernel declarado tem de aparecer"
    assert (pk_root / "drift.log").exists(), "deriva tem de ficar no historico"


def test_manifest_gera_json_valido(pk_root):
    """O manifest.json e lido por maquina: tem de parsear sempre."""
    _roda("pk_init >/dev/null 2>&1\npk_state_set tuning profile=dns >/dev/null\n", pk_root)
    proc = _cli(pk_root, "manifest")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    bruto = (pk_root / "manifest.json").read_text(encoding="utf-8")
    dados = json.loads(bruto)
    assert dados["schema"] == 2
    assert "tuning" in dados["components"]
    assert dados["components"]["tuning"]["stale"] is False
    assert (pk_root / "manifest.md").exists()


def test_manifest_json_sobrevive_a_valor_de_estado_hostil(pk_root):
    """Valor de estado vem de saida de comando: aspas, TAB e barra acontecem.

    O manifest.json e consumido por maquina; um valor mal escapado o torna
    ilegivel e o host some do agregador da frota sem erro nenhum.
    """
    _roda(
        "pk_init >/dev/null 2>&1\n"
        "pk_state_set tuning 'nota=diz \"oi\" e usa c:\\caminho' >/dev/null\n",
        pk_root,
    )
    proc = _cli(pk_root, "manifest")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    dados = json.loads((pk_root / "manifest.json").read_text(encoding="utf-8"))
    assert "tuning" in dados["components"]
    assert "facts" in dados


def test_timeline_mostra_o_evento_emitido(pk_root):
    _roda('pk_init >/dev/null 2>&1\npk_emit "marco.unico" "id=42"\n', pk_root)
    proc = _cli(pk_root, "timeline")
    assert proc.returncode == 0
    assert "marco.unico" in proc.stdout
    assert "id=42" in proc.stdout


def test_state_list_pela_cli(pk_root):
    _roda("pk_init >/dev/null 2>&1\npk_state_set alpha x=1 >/dev/null\n"
          "pk_state_set beta y=2 >/dev/null\n", pk_root)
    proc = _cli(pk_root, "state", "list")
    assert sorted(proc.stdout.split()) == ["alpha", "beta"]


def test_doctor_roda_sem_estado(pk_root):
    proc = _cli(pk_root, "doctor")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "pkops" in proc.stdout


def test_hooks_list_distingue_ativo_de_inerte(pk_root, bit_de_execucao_adere):
    hooks = pk_root / "hooks.d"
    hooks.mkdir(parents=True, exist_ok=True)
    (hooks / "10-ativo.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8", newline="\n")
    (hooks / "20-inerte.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8", newline="\n")
    os.chmod(hooks / "10-ativo.sh", 0o755)
    os.chmod(hooks / "20-inerte.sh", 0o644)

    proc = _cli(pk_root, "hooks", "list")
    assert "10-ativo.sh" in proc.stdout
    assert "20-inerte.sh" in proc.stdout
    assert "chmod +x" in proc.stdout, "o hook inerte tem de vir com a instrucao"
