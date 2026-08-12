"""Matriz RED/GREEN dos demais modulos: unbound, docker, zabbix-proxy e pve.

Cada modulo roda isolado com `--only`, entao a linha de base de um nao carrega
ruido do outro. O que se prova aqui e sempre o mesmo: a checagem detecta o
defeito que promete detectar, e nada alem dele.
"""

import pytest

from conftest import (
    SIMPLES,
    cenario_docker,
    cenario_pve,
    cenario_unbound,
    cenario_zabbix,
    dig_resposta,
    sem_vermelho,
)


def _linha_base(h, *args):
    mapa, _d, proc = h.casos(*args)
    assert proc.returncode == 0, (
        f"cenario saudavel precisa sair 0, saiu {proc.returncode}\n{proc.stdout[-2500:]}"
    )
    return mapa


def _matriz(h, base, mutar, alvo, cor, *args):
    mutar(h)
    mapa, dados, proc = h.casos(*args)
    assert mapa.get(alvo) == cor, (
        f"{alvo} deveria ficar {cor}, ficou {mapa.get(alvo)}\n{proc.stdout[-2500:]}"
    )
    mudaram = {k for k in set(mapa) | set(base) if mapa.get(k) != base.get(k)}
    assert mudaram == {alvo}, f"efeito colateral em {sorted(mudaram - {alvo})}"
    assert proc.returncode == (2 if cor == "RED" else 1)
    assert dados["verdict"] == ("FALHA" if cor == "RED" else "ATENCAO")


# =============================================================================
# unbound
# =============================================================================
UNB = ("--only", "unbound", "--deep")


@pytest.fixture(scope="module")
def base_unbound(tmp_path_factory):
    return _linha_base(cenario_unbound(tmp_path_factory.mktemp("unb")), *UNB)


DEFEITOS_UNBOUND = [
    (
        "servico parado",
        lambda h: h.caso("systemctl", "is-active unbound", 0, "inactive\n"),
        "unbound.servico", "RED",
    ),
    (
        "53/tcp sem socket",
        lambda h: h.caso("ss", "-lnt", 0, "State Recv-Q Send-Q Local Address:Port\n"),
        "unbound.porta.tcp", "RED",
    ),
    (
        "53/udp sem socket",
        lambda h: h.caso("ss", "-lnu", 0, "State Recv-Q Send-Q Local Address:Port\n"),
        "unbound.porta.udp", "RED",
    ),
    (
        "resolvedor nao resolve",
        lambda h: h.caso("dig", f"*google.com A*{SIMPLES}", 0, dig_resposta(status="SERVFAIL")),
        "unbound.q.recursiva", "RED",
    ),
    (
        # NOERROR com zero registro nao e resolucao: e "nao existe esse tipo".
        "NOERROR com resposta vazia",
        lambda h: h.caso("dig", f"*google.com A*{SIMPLES}", 0, dig_resposta(status="NOERROR")),
        "unbound.q.recursiva", "RED",
    ),
    (
        "checkconf reprovando",
        lambda h: h.caso("unbound-checkconf", "", 1,
                         "/etc/unbound/unbound.conf:12: error: syntax error\n"),
        "unbound.checkconf", "RED",
    ),
    (
        # Sobrescrever unbound.conf tira o include de conf.d/ e leva junto a
        # trust anchor. O validator sobe e nao valida nada, sem erro no log.
        "trust anchor ausente",
        lambda h: h.caso("unbound-checkconf", "-o auto-trust-anchor-file", 0, "\n"),
        "unbound.trustanchor", "RED",
    ),
    (
        "trust anchor apontando para arquivo vazio",
        lambda h: h.arquivo("/var/lib/unbound/root.key", ""),
        "unbound.trustanchor", "RED",
    ),
    (
        # outgoing-range x num-threads define quantos descritores o unbound
        # precisa. Estourar aparece como resolucao intermitente sob carga.
        "LimitNOFILE abaixo do necessario",
        lambda h: h.caso("systemctl", "show unbound -p LimitNOFILE --value", 0, "4096\n"),
        "unbound.limitnofile", "RED",
    ),
    (
        "limits.conf enganando o operador",
        lambda h: h.arquivo("/etc/security/limits.conf", "unbound soft nofile 65536\n"),
        "unbound.limits.conf", "YELLOW",
    ),
    (
        "resolvedor aberto",
        lambda h: h.caso("unbound-checkconf", "-o access-control", 0,
                         "127.0.0.0/8 allow\n0.0.0.0/0 allow\n"),
        "unbound.accesscontrol", "RED",
    ),
    (
        "qname-minimisation desligada",
        lambda h: h.caso("unbound-checkconf", "-o qname-minimisation", 0, "no\n"),
        "unbound.qnamemin", "YELLOW",
    ),
    (
        "sem flag AD em dominio assinado",
        lambda h: h.caso("dig", "*iana.org A*+dnssec*", 0,
                         dig_resposta(flags="qr rd ra",
                                      answer=["iana.org.\t300\tIN\tA\t192.0.43.8"])),
        "unbound.q.dnssec.positivo", "RED",
    ),
    (
        "dominio DNSSEC quebrado aceito",
        lambda h: h.caso("dig", "*dnssec-failed.org A*", 0,
                         dig_resposta(answer=["dnssec-failed.org.\t60\tIN\tA\t68.87.109.242"])),
        "unbound.q.dnssec.negativo", "RED",
    ),
    (
        "TCP nao responde",
        lambda h: h.caso("dig", "*google.com A*+tcp*", 9, ""),
        "unbound.q.tcp", "RED",
    ),
]


def test_unbound_saudavel_fica_verde(host_unbound):
    mapa, dados, proc = host_unbound.casos(*UNB)
    sem_vermelho(mapa, proc)
    assert proc.returncode == 0
    assert dados["suites"]["unbound"]["status"] == "GREEN"
    # Casos informativos: nao acendem nunca, mas aparecem no relatorio e no
    # painel. Sem afirmacao aqui, somem num refactor sem nada acusar.
    assert mapa["unbound.unidade"] == "GREEN"
    assert mapa["unbound.q.recursiva"] == "GREEN"
    assert mapa["unbound.porta.udp"] == "GREEN"
    assert mapa["unbound.q.latencia"] == "GREEN"


@pytest.mark.parametrize(
    "mutar,alvo,cor",
    [(d[1], d[2], d[3]) for d in DEFEITOS_UNBOUND],
    ids=[d[0] for d in DEFEITOS_UNBOUND],
)
def test_matriz_unbound(host_unbound, base_unbound, mutar, alvo, cor):
    _matriz(host_unbound, base_unbound, mutar, alvo, cor, *UNB)


def test_sem_deep_a_camada_ativa_do_unbound_nao_roda(host_unbound):
    mapa, _d, proc = host_unbound.casos("--only", "unbound")
    assert mapa["unbound.deep"] == "SKIP"
    assert not [k for k in mapa if k.startswith("unbound.q.")]
    assert proc.returncode == 0


def test_orcamento_de_descritores_acompanha_a_config(host_unbound):
    """O limite necessario e outgoing-range x num-threads, nao um numero fixo.

    Dobrar num-threads sem mexer no LimitNOFILE e exatamente como se chega ao
    'resolucao intermitente sob carga' — e o caso tem de acender sozinho.
    """
    host_unbound.caso("unbound-checkconf", "-o num-threads", 0, "8\n")
    mapa, dados, _p = host_unbound.casos(*UNB)
    assert mapa["unbound.limitnofile"] == "RED"
    caso = next(c for c in dados["checks"] if c["id"] == "unbound.limitnofile")
    assert caso["expected"] == ">= 32768", caso
    assert "4096x8" in caso["name"], caso["name"]


# =============================================================================
# docker
# =============================================================================
DOK = ("--only", "docker")


@pytest.fixture(scope="module")
def base_docker(tmp_path_factory):
    return _linha_base(cenario_docker(tmp_path_factory.mktemp("dk")), *DOK)


DEFEITOS_DOCKER = [
    (
        "servico parado",
        lambda h: h.caso("systemctl", "is-active docker", 0, "inactive\n"),
        "docker.servico", "RED",
    ),
    (
        # json-file sem limite: a causa numero um de host cheio sem ninguem
        # ter instalado nada.
        "log sem rotacao",
        lambda h: h.arquivo("/etc/docker/daemon.json", '{"log-driver":"json-file"}\n'),
        "docker.logrotate", "RED",
    ),
    (
        "daemon.json inexistente",
        lambda h: h.apaga("/etc/docker/daemon.json"),
        "docker.logrotate", "RED",
    ),
    (
        "inotify instances de default",
        lambda h: h.caso("sysctl", "-n fs.inotify.max_user_instances", 0, "128\n"),
        "docker.inotify.instances", "RED",
    ),
    (
        "inotify watches baixo",
        lambda h: h.caso("sysctl", "-n fs.inotify.max_user_watches", 0, "8192\n"),
        "docker.inotify.watches", "YELLOW",
    ),
    (
        "ip_forward desligado",
        lambda h: h.caso("sysctl", "-n net.ipv4.ip_forward", 0, "0\n"),
        "docker.ip_forward", "RED",
    ),
    (
        "bridge-nf desligado",
        lambda h: h.caso("sysctl", "-n net.bridge.bridge-nf-call-iptables", 0, "0\n"),
        "docker.bridge_nf", "YELLOW",
    ),
]


@pytest.mark.parametrize(
    "mutar,alvo,cor",
    [(d[1], d[2], d[3]) for d in DEFEITOS_DOCKER],
    ids=[d[0] for d in DEFEITOS_DOCKER],
)
def test_matriz_docker(host_docker, base_docker, mutar, alvo, cor):
    _matriz(host_docker, base_docker, mutar, alvo, cor, *DOK)


def test_docker_saudavel_fica_verde(host_docker):
    mapa, _d, proc = host_docker.casos(*DOK)
    sem_vermelho(mapa, proc)
    assert mapa["docker.unidade"] == "GREEN"
    assert proc.returncode == 0


def test_sem_br_netfilter_o_caso_e_skip(host_docker):
    """Modulo nao carregado nao e o mesmo que valor errado."""
    host_docker.apaga("/proc/sys/net/bridge/bridge-nf-call-iptables")
    mapa, _d, proc = host_docker.casos(*DOK)
    assert mapa["docker.bridge_nf"] == "SKIP"
    sem_vermelho(mapa, proc)


def test_sysctl_sem_valor_nao_passa_por_configurado(host_docker):
    """Valor vazio tem de acender. Era assim que 'sysctl inexistente' virava OK."""
    host_docker.caso("sysctl", "-n fs.inotify.max_user_instances", 1, "")
    mapa, _d, _p = host_docker.casos(*DOK)
    assert mapa["docker.inotify.instances"] == "RED"


# =============================================================================
# zabbix-proxy
# =============================================================================
ZBX = ("--only", "zabbix-proxy")


@pytest.fixture(scope="module")
def base_zabbix(tmp_path_factory):
    return _linha_base(cenario_zabbix(tmp_path_factory.mktemp("zbx")), *ZBX)


DEFEITOS_ZABBIX = [
    (
        "servico parado",
        lambda h: h.caso("systemctl", "is-active zabbix-proxy", 0, "inactive\n"),
        "zabbix.servico", "RED",
    ),
    (
        # O arquivo guarda DBPassword em texto claro; 644 entrega a senha do
        # banco para qualquer usuario local.
        "conf legivel por todo mundo",
        lambda h: h.caso("stat", "*", 0, "644\n"),
        "zabbix.conf.permissao", "RED",
    ),
    (
        "diretiva depreciada no 7.0",
        lambda h: h.arquivo("/etc/zabbix/zabbix_proxy.conf",
                            "Server=10.20.30.40\nConfigFrequency=60\n", modo=0o640),
        "zabbix.conf.frequencia", "YELLOW",
    ),
    (
        "proxy apontando para si mesmo",
        lambda h: h.arquivo("/etc/zabbix/zabbix_proxy.conf",
                            "Server=127.0.0.1\nProxyConfigFrequency=60\n", modo=0o640),
        "zabbix.conf.server", "YELLOW",
    ),
    (
        "LimitNOFILE de default",
        lambda h: h.caso("systemctl", "show zabbix-proxy -p LimitNOFILE --value", 0, "1024\n"),
        "zabbix.limitnofile", "YELLOW",
    ),
]


@pytest.mark.parametrize(
    "mutar,alvo,cor",
    [(d[1], d[2], d[3]) for d in DEFEITOS_ZABBIX],
    ids=[d[0] for d in DEFEITOS_ZABBIX],
)
def test_matriz_zabbix(host_zabbix, base_zabbix, mutar, alvo, cor):
    _matriz(host_zabbix, base_zabbix, mutar, alvo, cor, *ZBX)


def test_zabbix_saudavel_fica_verde(host_zabbix):
    mapa, _d, proc = host_zabbix.casos(*ZBX)
    sem_vermelho(mapa, proc)
    assert mapa["zabbix.unidade"] == "GREEN"
    assert proc.returncode == 0


def test_thp_so_e_cobrado_quando_ha_postgresql(host_zabbix):
    """Sem banco no host, THP nao e problema — e nao pode gerar caso nenhum."""
    mapa, _d, _p = host_zabbix.casos(*ZBX)
    assert "zabbix.thp" not in mapa


def test_thp_com_postgresql_exige_never(host_zabbix):
    host_zabbix.caso("systemctl", "list-unit-files postgresql.service", 0,
                     "UNIT FILE          STATE   PRESET\npostgresql.service enabled enabled\n")
    host_zabbix.arquivo("/sys/kernel/mm/transparent_hugepage/enabled",
                        "always [madvise] never\n")
    mapa, _d, proc = host_zabbix.casos(*ZBX)
    assert mapa["zabbix.thp"] == "RED", proc.stdout[-1500:]

    host_zabbix.arquivo("/sys/kernel/mm/transparent_hugepage/enabled",
                        "always madvise [never]\n")
    mapa, _d, _p = host_zabbix.casos(*ZBX)
    assert mapa["zabbix.thp"] == "GREEN"


# =============================================================================
# pve
# =============================================================================
PVE = ("--only", "pve")


@pytest.fixture(scope="module")
def base_pve(tmp_path_factory):
    return _linha_base(cenario_pve(tmp_path_factory.mktemp("pve")), *PVE)


DEFEITOS_PVE = [
    (
        "pveproxy caido",
        lambda h: h.caso("systemctl", "is-active pveproxy", 0, "failed\n"),
        "pve.servico.pveproxy", "RED",
    ),
    (
        "pmxcfs nao montado",
        lambda h: h.apaga("/etc/pve/nodes"),
        "pve.pmxcfs", "RED",
    ),
    (
        "storage inativo",
        lambda h: h.caso("pvesm", "status", 0,
                         "Name       Type   Status    Total Used Avail %\n"
                         "local       dir   active     100G 20G  80G 20\n"
                         "nfs-bkp     nfs   inactive     0G  0G   0G  0\n"),
        "pve.storages", "RED",
    ),
]


@pytest.mark.parametrize(
    "mutar,alvo,cor",
    [(d[1], d[2], d[3]) for d in DEFEITOS_PVE],
    ids=[d[0] for d in DEFEITOS_PVE],
)
def test_matriz_pve(host_pve, base_pve, mutar, alvo, cor):
    _matriz(host_pve, base_pve, mutar, alvo, cor, *PVE)


def test_host_fora_de_cluster_nao_cobra_quorum(host_pve):
    mapa, _d, proc = host_pve.casos(*PVE)
    assert mapa["pve.quorum"] == "SKIP"
    sem_vermelho(mapa, proc)


def test_cluster_sem_quorum_e_falha(host_pve):
    host_pve.arquivo("/etc/pve/corosync.conf", "totem {\n  cluster_name: pk\n}\n")
    host_pve.comando("pvecm", [("status", 0, "Quorate:          No\n")], padrao=(0, ""))
    mapa, _d, proc = host_pve.casos(*PVE)
    assert mapa["pve.quorum"] == "RED"
    assert proc.returncode == 2


def test_cluster_com_quorum_fica_verde(host_pve):
    host_pve.arquivo("/etc/pve/corosync.conf", "totem {\n  cluster_name: pk\n}\n")
    host_pve.comando("pvecm", [("status", 0,
                                "Cluster information\n"
                                "Quorum information\n"
                                "Quorate:          Yes\n")], padrao=(0, ""))
    mapa, _d, proc = host_pve.casos(*PVE)
    assert mapa["pve.quorum"] == "GREEN"
    assert proc.returncode == 0


def test_host_sem_pveversion_pula_o_modulo(host_vazio):
    mapa, _d, proc = host_vazio.casos("--only", "pve")
    assert mapa == {"pve.host": "SKIP"}
    assert proc.returncode == 0
