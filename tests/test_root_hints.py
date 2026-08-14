"""update-root-hints.sh: a matriz de casos, executada pelo CI.

Por que a matriz e um script bash e nao pytest puro
---------------------------------------------------
O que precisa ser provado aqui e ORDEM DE OPERACOES num sistema de arquivos:
quem foi escrito, quando, e o que sobrou quando algo falhou no meio. Isso se
expressa melhor no mesmo shell que o script usa. `prova-root-hints.sh` monta
um host sintetico — stubs de systemctl/curl/dig/named-checkconf no PATH e o
hints apontado para um tmp — entao nenhum arquivo real e tocado.

Este arquivo existe para que essa matriz RODE NO CI. Um arnes que so o autor
executa a mao envelhece junto com o script e para de valer sem ninguem notar.
"""

from conftest import RAIZ, bash, posix, roda_bash

PROVA = RAIZ / "tests" / "prova-root-hints.sh"
ALVO = RAIZ / "bin" / "update-root-hints.sh"

# Os casos que a prova cobre. Ficam aqui tambem para que a mensagem de falha do
# pytest diga o que se perdeu, sem obrigar a abrir o .sh.
CASOS = [
    "hints identico ao publicado -> ATUAL, sem restart",
    "hints antigo -> --check acusa e NAO altera",
    "hints antigo -> atualiza, faz backup e reinicia",
    "download falha -> NADA e alterado",
    "portal cativo devolve HTML 200 -> rejeita e preserva",
    "arquivo truncado -> rejeita",
    "resolvedor nao volta depois do restart -> DESFAZ",
    "--dry-run nao escreve nem reinicia",
    "staging fica no disco, ao lado, com o conteudo publicado",
    "publicado MAIS ANTIGO que o instalado -> recusa",
    "--stage apontando para o proprio hints -> recusa",
    "mesma versao, conteudo divergente -> instala mas avisa",
]


def test_a_matriz_de_root_hints_passa_inteira():
    """O contrato: em toda falha possivel, o hints em uso sobrevive.

    Metade dos casos nao verifica o caminho feliz — verifica que, quando o
    download falha, quando vem HTML de portal cativo, quando o resolvedor nao
    volta depois do restart, o arquivo que estava funcionando CONTINUA la. E o
    unico jeito de a ferramenta ser segura de rodar em cron.
    """
    proc = roda_bash([bash(), posix(PROVA), posix(ALVO)])
    assert "TODOS OS CASOS PASSARAM" in proc.stdout, (
        "a matriz de update-root-hints.sh falhou:\n"
        f"--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}"
    )
    assert proc.returncode == 0, f"prova saiu com {proc.returncode}"


def test_a_prova_cobre_todos_os_casos_declarados():
    """Guarda contra a prova encolher em silencio.

    Apagar um caso do .sh continuaria deixando o teste acima verde — ele so
    olha a linha final. Aqui cada caso e cobrado pelo nome.
    """
    corpo = PROVA.read_text(encoding="utf-8")
    faltando = [c for c in CASOS if c.split(" -> ")[0] not in corpo]
    assert not faltando, f"casos sumiram da prova: {faltando}"
