"""Testes do build de release do pkinfra-toolkit.

O tarball e o artefato que a frota baixa e executa. Um erro aqui nao aparece
em teste de unidade nenhum: aparece como script quebrado em 300 maquinas.
Por isso o build tem teste proprio.

Guarda tres invariantes:
  1. o tarball e reproduzivel a partir da arvore versionada;
  2. os checksums publicados conferem com o conteudo entregue;
  3. todo .sh entregue tem line-ending LF (CRLF quebra o shebang no Linux).
"""

import hashlib
import os
import re
import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest

RAIZ = Path(__file__).resolve().parent.parent
BUILD = RAIZ / "build.sh"
VERSION = (RAIZ / "VERSION").read_text(encoding="utf-8").strip() if (RAIZ / "VERSION").exists() else None

# scripts que vao para dentro do pacote
ESPERADOS = {
    "install.sh",
    "README.md",
    "CHECKSUMS.sha256",
    "lib/pkops.sh",
    "bin/pkassess.sh",
    "bin/pve-upgrade.sh",
    "bin/proxmox_tune.sh",
    "bin/tune-profile.sh",
    "bin/setup-unbound.sh",
    "bin/validate.sh",
    "docs/TOOLKIT.md",
    "docs/RUNBOOK.md",
    "hooks.d/10-jsonl.sh.example",
    "hooks.d/20-zabbix.sh.example",
    "hooks.d/30-git.sh.example",
    "hooks.d/40-alerta.sh.example",
}

# nao entra no tarball: e o bootstrap remoto, vive solto no repo
FORA_DO_PACOTE = {"bootstrap.sh", "build.sh"}


def _bash():
    """Localiza um bash que entenda os caminhos desta plataforma.

    No Windows, `which('bash')` costuma achar o bash do WSL em System32 —
    ele nao resolve `C:/...`, so `/mnt/c/...`. O Git Bash resolve os dois,
    entao ele vem primeiro.
    """
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

    pytest.skip("bash utilizavel indisponivel (WSL bash nao serve no Windows)")


def _posix(p) -> str:
    """git-bash no Windows engole a barra invertida — passe sempre POSIX."""
    return Path(p).as_posix()


def _build(outdir):
    return subprocess.run(
        [_bash(), _posix(BUILD), "--outdir", _posix(outdir)],
        cwd=str(RAIZ),
        capture_output=True,
        text=True,
    )


@pytest.fixture(scope="module")
def artefato(tmp_path_factory):
    """Roda o build de verdade e devolve (caminho_do_tarball, prefixo)."""
    if not BUILD.exists():
        pytest.fail("build.sh nao existe — o build de release nao foi implementado")
    saida = tmp_path_factory.mktemp("dist")
    proc = _build(saida)
    assert proc.returncode == 0, f"build.sh falhou:\n{proc.stdout}\n{proc.stderr}"
    tarballs = list(saida.glob("pkinfra-toolkit-*.tar.gz"))
    assert len(tarballs) == 1, f"esperado 1 tarball, achei {tarballs}"
    return tarballs[0], f"pkinfra-toolkit-{VERSION}"


def test_versao_e_declarada_em_arquivo():
    """A versao mora em VERSION — build, README e CI leem dali, sem duplicar."""
    assert (RAIZ / "VERSION").exists(), "falta o arquivo VERSION"
    assert VERSION, "VERSION esta vazio"


def test_readme_declara_a_mesma_versao_do_arquivo_version():
    """README vai DENTRO do pacote — versao errada ali mente para quem instala.

    A versao aparece no README em varios lugares (linha de instalacao, exemplo
    manual, comando de verificacao). Esquecer um deles no bump entrega um
    pacote que se apresenta como outra versao.
    """
    readme = (RAIZ / "README.md").read_text(encoding="utf-8")
    declarada = re.search(r"\*\*Versão do pacote:\*\*\s*([0-9.]+)", readme)
    assert declarada, "README nao declara 'Versão do pacote:'"
    assert declarada.group(1) == VERSION, (
        f"README diz {declarada.group(1)}, VERSION diz {VERSION}"
    )

    # Checa so a parte voltada a quem INSTALA. A secao de desenvolvimento tem
    # um exemplo de bump com versao futura ficticia, que e legitimo — incluir
    # aquele trecho aqui faria o teste acusar o proprio exemplo.
    corte = readme.find("## Desenvolvimento e release")
    instalacao = readme[:corte] if corte > 0 else readme

    antigas = {
        v for v in re.findall(r"\b(2026\.\d{2}\.\d{2}(?:\.\d+)?)\b", instalacao)
        if v != VERSION
    }
    assert not antigas, (
        f"versoes desatualizadas nas instrucoes de instalacao: {sorted(antigas)}"
    )


def test_version_comeca_com_data_valida():
    """O build deriva o mtime dos 3 primeiros componentes do VERSION.

    Uma versao que nao comece em YYYY.MM.DD produz data invalida e o tar
    recusa — falha que aparece so no build, nao no bump.
    """
    partes = VERSION.split(".")
    assert len(partes) >= 3, f"VERSION precisa de ao menos YYYY.MM.DD: {VERSION}"
    ano, mes, dia = partes[0], partes[1], partes[2]
    assert len(ano) == 4 and ano.isdigit(), f"ano invalido: {ano}"
    assert len(mes) == 2 and 1 <= int(mes) <= 12, f"mes invalido: {mes}"
    assert len(dia) == 2 and 1 <= int(dia) <= 31, f"dia invalido: {dia}"


def test_tarball_tem_o_nome_da_versao(artefato):
    tarball, prefixo = artefato
    assert tarball.name == f"pkinfra-toolkit-{VERSION}.tar.gz"


def test_tarball_contem_exatamente_o_esperado(artefato):
    tarball, prefixo = artefato
    with tarfile.open(tarball) as tf:
        membros = {
            m.name[len(prefixo) + 1 :]
            for m in tf.getmembers()
            if m.isfile() and m.name.startswith(prefixo + "/")
        }
    faltando = ESPERADOS - membros
    assert not faltando, f"ausentes no pacote: {sorted(faltando)}"
    vazou = membros & FORA_DO_PACOTE
    assert not vazou, f"nao deveriam estar no pacote: {sorted(vazou)}"


def test_checksums_conferem_com_o_conteudo(artefato):
    """CHECKSUMS.sha256 e o que a frota verifica antes de rodar como root."""
    tarball, prefixo = artefato
    with tarfile.open(tarball) as tf:
        bruto = tf.extractfile(f"{prefixo}/CHECKSUMS.sha256").read().decode("utf-8")
        declarado = {}
        for linha in bruto.splitlines():
            if not linha.strip():
                continue
            digest, caminho = linha.split(maxsplit=1)
            declarado[caminho.strip().lstrip("./")] = digest

        assert declarado, "CHECKSUMS.sha256 veio vazio"
        assert "CHECKSUMS.sha256" not in declarado, "checksum nao pode se auto-referenciar"

        for caminho, digest in declarado.items():
            membro = tf.extractfile(f"{prefixo}/{caminho}")
            assert membro is not None, f"{caminho} listado no CHECKSUMS mas ausente do pacote"
            real = hashlib.sha256(membro.read()).hexdigest()
            assert real == digest, f"checksum divergente em {caminho}"


def test_todo_shell_entregue_usa_lf(artefato):
    """CRLF no shebang faz o Linux reclamar de interpretador inexistente.

    Git no Windows converte para CRLF no checkout se o .gitattributes deixar.
    Este teste e a rede que pega isso antes da frota pegar.
    """
    tarball, prefixo = artefato
    with tarfile.open(tarball) as tf:
        for m in tf.getmembers():
            if not m.isfile() or not (m.name.endswith(".sh") or m.name.endswith(".example")):
                continue
            conteudo = tf.extractfile(m).read()
            assert b"\r\n" not in conteudo, f"{m.name} tem CRLF — quebra no Linux"


def test_executaveis_preservam_bit_de_execucao(artefato):
    tarball, prefixo = artefato
    with tarfile.open(tarball) as tf:
        for m in tf.getmembers():
            if m.isfile() and (m.name.endswith(".sh") and ".example" not in m.name):
                assert m.mode & 0o111, f"{m.name} sem bit de execucao"


def test_modos_no_tarball_sao_exatos_e_independem_do_host():
    """O modo tem de vir do --mode do tar, nunca do filesystem que empacotou.

    No NTFS o chmod do build nao adere: os hooks .example saiam 0644 no CI e
    0755 no Windows, e o mesmo commit gerava tarballs diferentes conforme
    quem rodou o build. Modo e conteudo do artefato nao podem depender do
    sistema de arquivos da maquina de quem empacota.
    """
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        proc = _build(tmp)
        assert proc.returncode == 0, proc.stderr
        tarball = next(Path(tmp).glob("*.tar.gz"))
        prefixo = f"pkinfra-toolkit-{VERSION}"

        errados = []
        with tarfile.open(tarball) as tf:
            for m in tf.getmembers():
                rel = m.name[len(prefixo) + 1 :] if m.name != prefixo else "."
                if m.isdir():
                    esperado = 0o755
                elif rel.endswith(".sh") and not rel.endswith(".example"):
                    esperado = 0o755
                else:
                    # docs, README, CHECKSUMS e os hooks .example
                    esperado = 0o644
                if (m.mode & 0o777) != esperado:
                    errados.append(f"{rel}: {oct(m.mode & 0o777)} != {oct(esperado)}")

        assert not errados, "modos divergentes no pacote:\n  " + "\n  ".join(errados)


def test_tarball_e_reproduzivel(tmp_path):
    """Dois builds seguidos geram bytes identicos — uid/gid/mtime fixos."""
    a, b = tmp_path / "a", tmp_path / "b"
    for saida in (a, b):
        proc = _build(saida)
        assert proc.returncode == 0, proc.stderr

    ta = next(a.glob("*.tar.gz")).read_bytes()
    tb = next(b.glob("*.tar.gz")).read_bytes()
    assert hashlib.sha256(ta).hexdigest() == hashlib.sha256(tb).hexdigest(), (
        "build nao e reproduzivel — mtime/uid/gid variando entre execucoes"
    )


def test_indice_git_marca_scripts_como_executaveis():
    """No Windows o git nao rastreia filemode — o bit tem de ir a mao.

    Sem ele, o clone no Linux traz 0644 e todo `./build.sh` do CI morre em
    "permission denied". Regride calado; por isso tem teste.
    """
    proc = subprocess.run(
        ["git", "ls-files", "-s"],
        cwd=str(RAIZ),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        pytest.skip("fora de um repositorio git")

    modos = {}
    for linha in proc.stdout.splitlines():
        campos = linha.split(maxsplit=3)
        if len(campos) == 4:
            modos[campos[3]] = campos[0]

    devem_executar = [
        c for c in modos if c.endswith(".sh") and not c.endswith(".example")
    ]
    assert devem_executar, "nenhum .sh no indice — algo esta errado"

    sem_bit = [c for c in devem_executar if modos[c] != "100755"]
    assert not sem_bit, (
        "sem bit de execucao no indice: "
        f"{sorted(sem_bit)} — rode: git update-index --chmod=+x <arquivos>"
    )


def test_bootstrap_existe_e_e_o_alvo_do_curl():
    """bootstrap.sh e o que a frota executa via curl | bash."""
    boot = RAIZ / "bootstrap.sh"
    assert boot.exists(), "falta bootstrap.sh — sem ele nao ha instalacao remota"
    texto = boot.read_text(encoding="utf-8")
    assert "\r\n" not in texto, "bootstrap.sh com CRLF"
    assert "sha256sum" in texto, "bootstrap baixa e executa sem verificar integridade"
    assert "EUID" in texto or "id -u" in texto, "bootstrap nao checa root"
