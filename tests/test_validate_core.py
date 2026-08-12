"""Matriz RED/GREEN dos modulos core e tuning.

Mesma regra da suite de bind: um defeito por teste, uma cor por defeito, e
nenhum efeito colateral em outro caso. Aqui a matriz roda com `--only
core,tuning` — o alvo e o motor de decisao de cada caso, nao a integracao
entre modulos, que a suite de bind ja exercita por inteiro.
"""

import pytest

from conftest import KERNEL, cenario_bind, apenas_amarelo, sem_vermelho

MODS = ("--only", "core,tuning")


@pytest.fixture(scope="module")
def linha_base(tmp_path_factory):
    h = cenario_bind(tmp_path_factory.mktemp("core-base"))
    mapa, _d, proc = h.casos(*MODS)
    assert proc.returncode == 0, proc.stdout[-2000:]
    return mapa


def test_core_saudavel_fica_verde_e_identifica_o_sistema(host_bind):
    """Casos informativos entram no relatorio; um assert os prende no lugar."""
    mapa, dados, proc = host_bind.casos(*MODS)
    sem_vermelho(mapa, proc)
    assert mapa["core.sistema"] == "GREEN"
    caso = next(c for c in dados["checks"] if c["id"] == "core.sistema")
    assert "bookworm" in caso["actual"] and KERNEL in caso["actual"], caso
    assert proc.returncode == 0


def test_tuning_de_host_pve_e_cobrado_por_kernel(host_bind):
    """O estado do proxmox_tune.sh e por kernel: trocar de kernel invalida.

    So existe em host Proxmox, entao nao cabe na matriz — mas tem os dois
    lados aqui.
    """
    host_bind.diretorio("/var/lib/pkops/tune")
    mapa, _d, _p = host_bind.casos(*MODS)
    assert mapa["tuning.pve"] == "YELLOW", "sem estado para o kernel atual tem de avisar"

    host_bind.arquivo(f"/var/lib/pkops/tune/state-{KERNEL}.env", "aplicado=1\n")
    mapa, _d, proc = host_bind.casos(*MODS)
    assert mapa["tuning.pve"] == "GREEN"
    assert proc.returncode == 0


def _meminfo(total_kb, disp_kb):
    return f"MemTotal: {total_kb} kB\nMemFree: 100 kB\nMemAvailable: {disp_kb} kB\n"


def _df(usado_pct, disp_kb=26000000):
    return (
        "Filesystem     1024-blocks     Used Available Capacity Mounted on\n"
        f"/dev/sda1         41152636 12345678  {disp_kb}      {usado_pct}% /\n"
    )


DEFEITOS = [
    (
        "disco em 85%",
        lambda h: h.caso("df", "*", 0, _df(85)),
        "core.disco", "YELLOW",
    ),
    (
        "disco em 93%",
        lambda h: h.caso("df", "*", 0, _df(93)),
        "core.disco", "RED",
    ),
    (
        "memoria com 15% disponivel",
        lambda h: h.arquivo("/proc/meminfo", _meminfo(8000000, 1200000)),
        "core.memoria", "YELLOW",
    ),
    (
        "memoria com 5% disponivel",
        lambda h: h.arquivo("/proc/meminfo", _meminfo(8000000, 400000)),
        "core.memoria", "RED",
    ),
    (
        "PSI de io saturado",
        lambda h: h.arquivo("/proc/pressure/io",
                            "some avg10=40.0 avg60=35.20 avg300=20.0 total=99\n"),
        "core.psi.io", "YELLOW",
    ),
    (
        "PSI de memoria sob pressao",
        lambda h: h.arquivo("/proc/pressure/memory",
                            "some avg10=20.0 avg60=15.50 avg300=9.0 total=99\n"),
        "core.psi.mem", "YELLOW",
    ),
    (
        "kernel novo instalado sem reboot",
        lambda h: h.caso("dpkg-query", "*linux-image*", 0,
                         f"linux-image-{KERNEL}\nlinux-image-6.9.7-amd64\n"),
        "core.reboot", "YELLOW",
    ),
    (
        # Mesma chave em dois arquivos: vence o de nome lexicograficamente
        # maior, e nao o que o operador editou por ultimo.
        "mesma chave de sysctl em dois arquivos",
        lambda h: h.arquivo("/etc/sysctl.d/99-local.conf", "net.core.rmem_max = 8388608\n"),
        "core.sysctl.colisao", "YELLOW",
    ),
    (
        "relogio sem sincronia",
        lambda h: h.caso("timedatectl", "*NTPSynchronized*", 0, "no\n"),
        "core.relogio", "YELLOW",
    ),
    (
        # Efeito secundario declarado: sem o arquivo nao existe valor para
        # comparar, entao a deriva vira SKIP. SKIP explicito, e nao um caso
        # que some do relatorio — quem le um painel entende ausencia como
        # "esta tudo bem".
        "arquivo do perfil de tuning removido a mao",
        lambda h: h.apaga("/etc/sysctl.d/96-tune-profile-dns.conf"),
        "tuning.arquivo", "RED", {"tuning.deriva": "SKIP"},
    ),
    (
        "valor efetivo divergente do declarado",
        lambda h: h.caso("sysctl", "-n net.core.rmem_max", 0, "212992\n"),
        "tuning.deriva", "YELLOW",
    ),
    (
        "perfil aplicado em outro kernel",
        lambda h: h.arquivo("/var/lib/pkops/state/tuning.env",
                            "profile=dns\nPK_KERNEL=5.10.0-26-amd64\n"),
        "tuning.kernel", "YELLOW",
    ),
]


@pytest.mark.parametrize(
    "mutar,alvo,cor,colaterais",
    [(d[1], d[2], d[3], d[4] if len(d) > 4 else {}) for d in DEFEITOS],
    ids=[d[0] for d in DEFEITOS],
)
def test_defeito_muda_exatamente_um_caso(host_bind, linha_base, mutar, alvo, cor, colaterais):
    """Um defeito, um caso — mais os efeitos secundarios DECLARADOS.

    Efeito secundario nao e proibido: as vezes um dado ausente torna outro
    caso impossivel de medir. O que e proibido e o efeito NAO declarado, que
    e como se perde o rastro da causa durante um incidente.
    """
    mutar(host_bind)
    mapa, dados, proc = host_bind.casos(*MODS)

    assert mapa.get(alvo) == cor, (
        f"{alvo} deveria ficar {cor}, ficou {mapa.get(alvo)}\n{proc.stdout[-2500:]}"
    )
    for outro, esperado in colaterais.items():
        assert mapa.get(outro) == esperado, (
            f"efeito secundario declarado nao ocorreu: {outro} deveria ser "
            f"{esperado}, veio {mapa.get(outro)}"
        )

    mudaram = {k for k in set(mapa) | set(linha_base) if mapa.get(k) != linha_base.get(k)}
    previstos = {alvo} | set(colaterais)
    assert mudaram == previstos, f"efeito colateral nao declarado em {sorted(mudaram - previstos)}"

    assert proc.returncode == (2 if cor == "RED" else 1)
    assert dados["verdict"] == ("FALHA" if cor == "RED" else "ATENCAO")


# =============================================================================
# casos que nao cabem na matriz de um defeito -> um caso
# =============================================================================
def test_sysctl_conf_com_conteudo_ativo_e_falha_no_debian_13(host_bind):
    """No Debian 13 o arquivo continua no disco e deixou de ser lido.

    Parece aplicado, nao esta. E o tipo de mudanca que so aparece meses depois,
    quando alguem repara que o tuning sumiu.
    """
    host_bind.arquivo("/etc/os-release", 'ID=debian\nVERSION_CODENAME=trixie\n')
    host_bind.arquivo("/etc/sysctl.conf", "net.ipv4.ip_forward = 1\n")
    mapa, _d, proc = host_bind.casos(*MODS)
    assert mapa["core.sysctl.conf"] == "RED"
    assert proc.returncode == 2


def test_no_debian_13_comentario_em_sysctl_conf_nao_acusa_falha(host_bind):
    host_bind.arquivo("/etc/os-release", 'ID=debian\nVERSION_CODENAME=trixie\n')
    host_bind.arquivo("/etc/sysctl.conf", "# so comentario\n#net.ipv4.ip_forward = 1\n")
    mapa, _d, proc = host_bind.casos(*MODS)
    assert mapa["core.sysctl.conf"] == "GREEN"
    sem_vermelho(mapa, proc)


def test_sysctl_multivalor_com_tab_nao_acusa_deriva(host_bind):
    """Bug 29 do catalogo, agora com o dado do jeito que o kernel devolve.

    O arquivo declara os valores separados por espaco; o kernel os devolve
    separados por TAB. Sem normalizar os dois lados, toda chave multivalor
    aparece como deriva e o operador reaplica tuning que ja estava aplicado.
    """
    host_bind.caso("sysctl", "-n net.ipv4.udp_mem", 0, "189141\t252188\t378282\n")
    mapa, _d, proc = host_bind.casos(*MODS)
    assert mapa["tuning.deriva"] == "GREEN", proc.stdout[-2000:]


def test_deriva_de_multivalor_real_e_detectada(host_bind):
    """O contraponto do teste acima: a normalizacao nao pode esconder deriva."""
    host_bind.caso("sysctl", "-n net.ipv4.udp_mem", 0, "1\t2\t3\n")
    mapa, _d, _p = host_bind.casos(*MODS)
    assert mapa["tuning.deriva"] == "YELLOW"


def test_sem_perfil_aplicado_o_tuning_avisa_e_nao_falha(host_bind):
    """Host sem tuning e host a tunar, nao host quebrado."""
    host_bind.apaga("/var/lib/pkops/state/tuning.env")
    mapa, _d, proc = host_bind.casos(*MODS)
    assert mapa["tuning.perfil"] == "YELLOW"
    assert "tuning.deriva" not in mapa, "nao ha o que comparar sem perfil declarado"
    sem_vermelho(mapa, proc)
    assert proc.returncode == 1


def test_coerencia_de_kernel_sobrevive_ao_sumico_do_arquivo(host_bind):
    """Perder o arquivo do perfil nao pode apagar o que ainda da para saber.

    O estado declarado continua no disco com o kernel em que foi aplicado; o
    caso tem de continuar respondendo em vez de desaparecer junto.
    """
    host_bind.apaga("/etc/sysctl.d/96-tune-profile-dns.conf")
    host_bind.arquivo("/var/lib/pkops/state/tuning.env",
                      "profile=dns\nPK_KERNEL=5.10.0-26-amd64\n")
    mapa, _d, _p = host_bind.casos(*MODS)
    assert mapa["tuning.arquivo"] == "RED"
    assert mapa["tuning.kernel"] == "YELLOW", (
        "a incoerencia de kernel sumiu junto com o arquivo do perfil"
    )
    assert mapa["tuning.deriva"] == "SKIP"


def test_estado_legado_do_tune_profile_ainda_e_lido(host_bind):
    """Host que ainda nao migrou para /var/lib/pkops nao pode aparecer como
    'sem tuning' — seria um alarme falso na frota inteira durante a migracao."""
    host_bind.apaga("/var/lib/pkops/state/tuning.env")
    host_bind.arquivo("/var/lib/tune-profile/profile", "dns\n")
    mapa, _d, _p = host_bind.casos(*MODS)
    assert mapa["tuning.perfil"] == "GREEN"
    assert mapa["tuning.arquivo"] == "GREEN"
    assert mapa["tuning.deriva"] == "GREEN"
    assert mapa["tuning.kernel"] == "SKIP", (
        "sem PK_KERNEL no estado legado nao da para afirmar coerencia: SKIP, nao GREEN"
    )


def test_meminfo_ilegivel_vira_skip_e_nao_divisao_por_zero(host_bind):
    """MemTotal ausente nao pode derrubar a suite com erro de aritmetica."""
    host_bind.arquivo("/proc/meminfo", "Buffers: 1 kB\n")
    mapa, _d, proc = host_bind.casos(*MODS)
    assert mapa["core.memoria"] == "SKIP"
    assert "division by 0" not in proc.stderr
    sem_vermelho(mapa, proc)


def test_kernel_sem_psi_nao_inventa_metrica(host_bind):
    host_bind.apaga("/proc/pressure")
    mapa, _d, proc = host_bind.casos(*MODS)
    assert mapa["core.psi.io"] == "SKIP"
    assert "core.psi.mem" not in mapa
    sem_vermelho(mapa, proc)


def test_timedatectl_ausente_vira_skip(host_bind):
    """Container sem systemd nao pode virar YELLOW por falta de timedatectl."""
    host_bind.remove_comando("timedatectl")
    mapa, _d, proc = host_bind.casos(*MODS)
    assert mapa["core.relogio"] == "SKIP"
    apenas_amarelo(mapa)
    assert proc.returncode == 0
