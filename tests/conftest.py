"""Infra compartilhada da suite de testes do pkinfra-toolkit.

O problema que este arquivo resolve
-----------------------------------
As checagens do toolkit so valem se cada uma souber DETECTAR o defeito que diz
detectar. Testar isso exigia, ate agora, um Debian de verdade com bind, unbound
e Proxmox instalados — ou seja, nao era testado.

Aqui montamos um HOST SINTETICO: um sysroot com os arquivos que a suite le e um
diretorio de stubs no inicio do PATH com os comandos que ela executa. Com isso
cada caso ganha os dois lados da baliza:

    GREEN  cenario saudavel -> o caso passa
    RED    um unico defeito injetado -> aquele caso, e so aquele, falha

O `HostFalso.caso()` insere um padrao NO INICIO da lista do stub, entao
sobrescrever uma unica resposta e uma linha por teste. E o que torna a matriz
RED/GREEN viavel de escrever e de ler.
"""

import base64
import json
import os
import re
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

RAIZ = Path(__file__).resolve().parent.parent
VALIDATE = RAIZ / "bin" / "validate.sh"
PKOPS = RAIZ / "lib" / "pkops.sh"

KERNEL = "6.1.0-18-amd64"
SERIAL = "2026081201"
ZONA = "exemplo.local"
ARQ_ZONA = "/etc/bind/db.exemplo.local"

# Sufixo que SO a consulta simples tem. A suite pergunta o mesmo nome por UDP,
# por TCP e com EDNS, e as tres linhas de comando comecam igual; sem ancorar,
# um padrao para a consulta simples sequestra as outras duas e o teste passa a
# medir tres casos de uma vez.
SIMPLES = "+tries=1"


# =============================================================================
# bash
# =============================================================================
def bash() -> str:
    """Localiza um bash que entenda os caminhos desta plataforma.

    No Windows, `which('bash')` costuma achar o bash do WSL em System32 — ele
    nao resolve `C:/...`, so `/mnt/c/...`. O Git Bash resolve os dois, entao
    ele vem primeiro.
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


def posix(p) -> str:
    return Path(p).as_posix()


def roda_bash(cmd, env=None, cwd=None):
    """subprocess.run com a decodificacao amarrada em UTF-8.

    `text=True` decodifica pelo locale do sistema. Numa maquina Windows isso e
    cp1252, e todo travessao ou acento que os scripts emitem em UTF-8 chega ao
    teste corrompido — o assert falha por encoding e a mensagem de erro nao da
    a menor pista disso. Os scripts falam UTF-8; o arnes le UTF-8.
    """
    return subprocess.run(
        cmd,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        env=env,
        cwd=cwd if cwd is not None else str(RAIZ),
    )


def _glob_seguro(padrao: str) -> str:
    """Prepara um glob para virar rotulo de `case` em bash.

    Espaco NAO citado em rotulo de case e erro de sintaxe — e o script inteiro
    morre em runtime, nao na geracao. Citamos os trechos literais e deixamos
    `*` e `?` de fora das aspas, que e onde precisam continuar valendo como
    curinga. Classe de caractere ([abc]) nao e suportada de proposito: nenhum
    stub precisa e o silencio seria pior que a limitacao.
    """
    saida = []
    for parte in re.split(r"([*?])", padrao):
        if parte in ("*", "?"):
            saida.append(parte)
        elif parte:
            saida.append("'" + parte.replace("'", "'\\''") + "'")
    return "".join(saida) or "''"


# =============================================================================
# respostas de dig realistas
# =============================================================================
def dig_resposta(status="NOERROR", flags="qr rd ra", answer=(), extra_ans=0):
    """Monta a saida de um `dig` sem +short, no formato que a suite parseia.

    Realista de proposito: a suite le `status:`, `;; flags:`, o contador
    `ANSWER:` do cabecalho e a ANSWER SECTION. Um stub que devolvesse so o
    status faria os parsers passarem sem nunca terem sido exercitados.
    """
    linhas = [
        "; <<>> DiG 9.18.24-1 <<>> consulta",
        ";; global options: +cmd",
        ";; Got answer:",
        f";; ->>HEADER<<- opcode: QUERY, status: {status}, id: 40118",
        f";; flags: {flags}; QUERY: 1, ANSWER: {len(answer) + extra_ans}, "
        "AUTHORITY: 0, ADDITIONAL: 1",
        "",
        ";; OPT PSEUDOSECTION:",
        "; EDNS: version: 0, flags:; udp: 1232",
        ";; QUESTION SECTION:",
        ";consulta.\t\t\tIN\tA",
        "",
    ]
    if answer:
        linhas.append(";; ANSWER SECTION:")
        linhas.extend(answer)
        linhas.append("")
    linhas += [
        ";; Query time: 3 msec",
        ";; SERVER: 127.0.0.1#53(127.0.0.1) (UDP)",
        ";; MSG SIZE  rcvd: 55",
        "",
    ]
    return "\n".join(linhas)


def _soa(serial=SERIAL, zona=ZONA):
    return (
        f"{zona}.\t\t3600\tIN\tSOA\tns1.{zona}. root.{zona}. "
        f"{serial} 7200 3600 1209600 3600"
    )


# =============================================================================
# host sintetico
# =============================================================================
class HostFalso:
    """Sysroot + stubs de comando. Uma instancia por teste."""

    def __init__(self, base: Path):
        self.base = base
        self.sysroot = base / "sysroot"
        self.stubs = base / "stubs"
        self.sysroot.mkdir(parents=True, exist_ok=True)
        self.stubs.mkdir(parents=True, exist_ok=True)
        self._cmds = {}

    # --- sysroot ------------------------------------------------------------
    def arquivo(self, caminho: str, conteudo: str = "", modo: int = 0o644) -> Path:
        alvo = self.sysroot / caminho.lstrip("/")
        alvo.parent.mkdir(parents=True, exist_ok=True)
        alvo.write_text(textwrap.dedent(conteudo).lstrip("\n"), encoding="utf-8", newline="\n")
        os.chmod(alvo, modo)
        return alvo

    def diretorio(self, caminho: str) -> Path:
        alvo = self.sysroot / caminho.lstrip("/")
        alvo.mkdir(parents=True, exist_ok=True)
        return alvo

    def apaga(self, caminho: str) -> None:
        alvo = self.sysroot / caminho.lstrip("/")
        if alvo.is_dir():
            shutil.rmtree(alvo)
        elif alvo.exists():
            alvo.unlink()

    # --- stubs de comando ---------------------------------------------------
    def comando(self, nome: str, casos=(), padrao=(1, "")) -> None:
        """Cria (ou substitui) um comando falso.

        `casos` e uma lista de (padrao_glob, rc, stdout) avaliada em ordem
        contra `"$*"`. O primeiro que casar responde.
        """
        self._cmds[nome] = ([list(c) for c in casos], list(padrao))
        self._escreve(nome)

    def caso(self, nome: str, padrao_glob: str, rc: int = 0, saida: str = "") -> None:
        """Poe um padrao na FRENTE da lista — o jeito de injetar um defeito."""
        if nome not in self._cmds:
            self.comando(nome)
        self._cmds[nome][0].insert(0, [padrao_glob, rc, saida])
        self._escreve(nome)

    def caso_script(self, nome: str, padrao_glob: str, corpo: str) -> None:
        """Como `caso`, mas o braco do case leva shell arbitrario.

        Existe para stub COM ESTADO — o caso do cache, em que a segunda
        consulta ao mesmo nome precisa responder diferente da primeira. Sem
        isso nao da para provar que a suite compara duas respostas.
        """
        if nome not in self._cmds:
            self.comando(nome)
        self._cmds[nome][0].insert(0, [padrao_glob, None, textwrap.dedent(corpo)])
        self._escreve(nome)

    def padrao(self, nome: str, rc: int, saida: str = "") -> None:
        """Troca a resposta de fallback do stub."""
        if nome not in self._cmds:
            self.comando(nome)
        self._cmds[nome][1] = [rc, saida]
        self._escreve(nome)

    def remove_comando(self, nome: str) -> None:
        """Faz o comando sumir do PATH — simula pacote nao instalado."""
        self._cmds.pop(nome, None)
        alvo = self.stubs / nome
        if alvo.exists():
            alvo.unlink()

    def _escreve(self, nome: str) -> None:
        casos, padrao = self._cmds[nome]
        linhas = ["#!/usr/bin/env bash", 'arg="$*"', 'case "$arg" in']
        for glob, rc, saida in casos:
            if rc is None:  # corpo shell cru, vindo de caso_script
                linhas.append(f"  {_glob_seguro(glob)})")
                linhas.extend("    " + l for l in saida.strip("\n").splitlines())
                linhas.append("    ;;")
                continue
            b64 = base64.b64encode(saida.encode("utf-8")).decode("ascii")
            # base64 evita todo o inferno de aspas: a saida vai literal, com
            # aspas, TAB, cifrao e quebra de linha, sem escapar nada.
            linhas.append(f"  {_glob_seguro(glob)}) base64 -d <<< '{b64}'; exit {rc} ;;")
        linhas.append("esac")
        b64 = base64.b64encode(str(padrao[1]).encode("utf-8")).decode("ascii")
        linhas.append(f"base64 -d <<< '{b64}'")
        linhas.append(f"exit {padrao[0]}")
        alvo = self.stubs / nome
        alvo.write_text("\n".join(linhas) + "\n", encoding="utf-8", newline="\n")
        os.chmod(alvo, 0o755)

    # --- execucao -----------------------------------------------------------
    def roda(self, *args, env=None, script=None):
        """Executa a suite contra este host e devolve o CompletedProcess."""
        alvo = posix(script or VALIDATE)
        # PATH no Git Bash precisa estar em forma POSIX (/c/...): entrada em
        # C:/... e simplesmente ignorada na busca de comando, e todo stub
        # deixaria de existir sem erro nenhum.
        envoltorio = textwrap.dedent(
            f"""
            d='{posix(self.stubs)}'
            command -v cygpath >/dev/null 2>&1 && d="$(cygpath -u "$d")"
            export PATH="$d:$PATH"
            r='{posix(self.sysroot)}'
            command -v cygpath >/dev/null 2>&1 && r="$(cygpath -u "$r")"
            export PK_SYSROOT="$r"
            exec "{alvo}" "$@"
            """
        )
        amb = os.environ.copy()
        # Orcamento generoso: no host de desenvolvimento o custo de subir o
        # stub e maior que o de um dig real. O limiar em si tem teste proprio.
        amb["LAT_BUDGET_MS"] = "100000"
        amb["DNS_TIMEOUT"] = "1"
        amb.update(env or {})
        return roda_bash([bash(), "-c", envoltorio, "validate", *args], env=amb)

    def json(self, *args, env=None):
        """Roda com --json e devolve (dict, proc). Falha se o JSON nao parsear."""
        proc = self.roda("--json", *args, env=env)
        try:
            return json.loads(proc.stdout), proc
        except json.JSONDecodeError as e:
            raise AssertionError(
                f"--json produziu JSON invalido ({e}).\n"
                f"stdout:\n{proc.stdout[:2000]}\nstderr:\n{proc.stderr[:2000]}"
            ) from None

    def casos(self, *args, env=None):
        """Mapa id -> status, o formato em que a matriz RED/GREEN e escrita."""
        dados, proc = self.json(*args, env=env)
        return {c["id"]: c["status"] for c in dados["checks"]}, dados, proc


# =============================================================================
# cenarios
# =============================================================================
def _base_core(h: HostFalso) -> None:
    """Host saudavel no que o modulo core olha."""
    h.arquivo(
        "/etc/os-release",
        """
        PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
        ID=debian
        VERSION_ID="12"
        VERSION_CODENAME=bookworm
        """,
    )
    h.arquivo(
        "/proc/meminfo",
        """
        MemTotal:        8165432 kB
        MemFree:         2001234 kB
        MemAvailable:    4402100 kB
        SwapTotal:       2097148 kB
        """,
    )
    h.arquivo("/proc/pressure/io", "some avg10=0.00 avg60=0.12 avg300=0.05 total=1234\n"
                                   "full avg10=0.00 avg60=0.00 avg300=0.00 total=12\n")
    h.arquivo("/proc/pressure/memory", "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
                                       "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")
    h.arquivo("/etc/sysctl.conf", "# nada ativo aqui\n#net.ipv4.ip_forward=1\n")

    h.comando("uname", [("-r", 0, f"{KERNEL}\n")], padrao=(0, "Linux\n"))
    h.comando(
        "df",
        [
            ("*", 0,
             "Filesystem     1024-blocks     Used Available Capacity Mounted on\n"
             "/dev/sda1         41152636 12345678  26000000      33% /\n"),
        ],
    )
    h.comando(
        "dpkg-query",
        [("*linux-image*", 0, f"linux-image-{KERNEL}\nlinux-image-amd64\n")],
        padrao=(0, ""),
    )
    h.comando("timedatectl", [("*NTPSynchronized*", 0, "yes\n")], padrao=(0, ""))


def _base_tuning(h: HostFalso) -> None:
    """Perfil aplicado, coerente com o kernel e sem deriva."""
    h.arquivo(
        "/var/lib/pkops/state/tuning.env",
        f"""
        profile=dns
        PK_APPLIED_AT=2026-08-10T09:00:00-03:00
        PK_KERNEL={KERNEL}
        PK_TOOL=tune-profile
        PK_TOOL_VERSION=1.0
        """,
    )
    h.arquivo(
        "/etc/sysctl.d/96-tune-profile-dns.conf",
        """
        # perfil dns
        net.core.rmem_max = 16777216
        net.ipv4.udp_mem = 189141 252188 378282
        """,
    )
    h.arquivo("/proc/sys/net/core/rmem_max", "16777216\n")
    h.arquivo("/proc/sys/net/ipv4/udp_mem", "189141\t252188\t378282\n")
    h.comando(
        "sysctl",
        [
            ("-n net.core.rmem_max", 0, "16777216\n"),
            # O kernel devolve chave multivalor separada por TAB. E o caso que
            # gerava deriva fantasma e, no JSON, TAB cru dentro de string.
            ("-n net.ipv4.udp_mem", 0, "189141\t252188\t378282\n"),
            ("-n fs.inotify.max_user_instances", 0, "8192\n"),
            ("-n fs.inotify.max_user_watches", 0, "524288\n"),
            ("-n net.ipv4.ip_forward", 0, "1\n"),
            ("-n net.bridge.bridge-nf-call-iptables", 0, "1\n"),
        ],
        padrao=(1, ""),
    )


def dump_bind(
    recursion="10.0.0.0/8; localhost;",
    transfer='"none";',
    dnssec="auto",
    cache="30%",
    version='"none"',
    querylog="no",
    hints="/usr/share/dns/root.hints",
    zona=ZONA,
    arquivo_zona=ARQ_ZONA,
):
    """Reproduz a saida de `named-checkconf -p` — a config JA resolvida.

    Cada diretiva e um parametro: passar `None` a OMITE. E assim que os testes
    injetam um defeito de postura (allow-transfer ausente, dnssec-validation
    no) sem mexer em string com replace, que quebra ao primeiro reindentado.
    """
    o = ['options {', '\tdirectory "/var/cache/bind";']
    if recursion is not None:
        o.append("\tallow-recursion {\n\t\t" + "\n\t\t".join(recursion.split()) + "\n\t};")
    if transfer is not None:
        o.append("\tallow-transfer {\n\t\t" + "\n\t\t".join(transfer.split()) + "\n\t};")
    if dnssec is not None:
        o.append(f"\tdnssec-validation {dnssec};")
    if cache is not None:
        o.append(f"\tmax-cache-size {cache};")
    if version is not None:
        o.append(f"\tversion {version};")
    if querylog is not None:
        o.append(f"\tquerylog {querylog};")
    o.append("};")

    if hints is not None:
        o += ['zone "." IN {', "\ttype hint;", f'\tfile "{hints}";', "};"]
    if zona is not None:
        o += [f'zone "{zona}" IN {{', "\ttype master;", f'\tfile "{arquivo_zona}";', "};"]
    return "\n".join(o) + "\n"


DUMP_BIND_OK = dump_bind()


def _base_bind(h: HostFalso) -> None:
    h.arquivo("/etc/bind/named.conf", 'include "/etc/bind/named.conf.options";\n')
    h.arquivo(ARQ_ZONA, f"$TTL 3600\n@ IN SOA ns1 root ( {SERIAL} 7200 3600 1209600 3600 )\n")
    h.arquivo("/usr/share/dns/root.hints", ".  3600000  IN  NS  a.root-servers.net.\n")

    h.comando(
        "systemctl",
        [
            ("list-unit-files named.service", 0, "UNIT FILE     STATE   PRESET\nnamed.service enabled enabled\n\n1 unit files listed.\n"),
            ("is-active --quiet named", 0, ""),
            ("is-active named", 0, "active\n"),
            ("show named -p LimitNOFILE --value", 0, "32768\n"),
        ],
        # Nenhuma outra unidade existe: unbound, docker, zabbix e pve saem SKIP.
        padrao=(1, ""),
    )
    h.comando(
        "ss",
        [
            ("-lnt", 0, "State  Recv-Q Send-Q Local Address:Port Peer Address:Port\n"
                        "LISTEN 0      10          127.0.0.1:53        0.0.0.0:*\n"),
            ("-lnu", 0, "State  Recv-Q Send-Q Local Address:Port Peer Address:Port\n"
                        "UNCONN 0      0           127.0.0.1:53        0.0.0.0:*\n"),
        ],
        padrao=(0, ""),
    )
    h.comando(
        "named-checkconf",
        [("-z *", 0, ""), ("-p *", 0, DUMP_BIND_OK)],
        padrao=(0, ""),
    )
    h.comando(
        "named-checkzone",
        [(f"{ZONA} *", 0, f"zone {ZONA}/IN: loaded serial {SERIAL}\nOK\n")],
        padrao=(1, "zone desconhecida: nao carrega\n"),
    )
    h.comando("rndc", [("status", 0, "version: BIND 9.18.24\nserver is up and running\n")],
              padrao=(1, ""))

    ans_a = ["google.com.\t\t168\tIN\tA\t142.250.219.174"]
    h.comando(
        "dig",
        [
            # ordem importa: as variantes de transporte vem antes da consulta base
            ("*google.com A*+tcp*", 0, dig_resposta(answer=ans_a)),
            ("*google.com A*+bufsize*", 0, dig_resposta(answer=ans_a)),
            (f"*google.com A*{SIMPLES}", 0, dig_resposta(answer=ans_a)),
            ("*invalid A*", 0, dig_resposta(status="NXDOMAIN", flags="qr rd ra")),
            ("*iana.org A*+dnssec*", 0,
             dig_resposta(flags="qr rd ra ad",
                          answer=["iana.org.\t\t300\tIN\tA\t192.0.43.8"])),
            ("*dnssec-failed.org A*", 0, dig_resposta(status="SERVFAIL", flags="qr rd ra")),
            ("*example.com A*", 0,
             dig_resposta(answer=["example.com.\t\t120\tIN\tA\t93.184.216.34"])),
            (f"*{ZONA} AXFR*", 0,
             f"; <<>> DiG 9.18.24-1 <<>> @127.0.0.1 {ZONA} AXFR\n"
             "; (1 server found)\n"
             "; Transfer failed.\n"),
            (f"*{ZONA} SOA*", 0, dig_resposta(flags="qr aa rd ra", answer=[_soa()])),
            ("*version.bind CH TXT*", 0, ""),
        ],
        padrao=(0, dig_resposta(status="SERVFAIL")),
    )


def cenario_bind(base: Path) -> HostFalso:
    """Host DNS autoritativo+recursivo 100% saudavel. Toda checagem GREEN."""
    h = HostFalso(base)
    _base_core(h)
    _base_tuning(h)
    _base_bind(h)
    return h


DUMP_UNBOUND_OK = {
    "auto-trust-anchor-file": "/var/lib/unbound/root.key",
    "outgoing-range": "4096",
    "num-threads": "2",
    "access-control": "127.0.0.0/8 allow\n10.0.0.0/8 allow\n0.0.0.0/0 refuse",
    "qname-minimisation": "yes",
}


def cenario_unbound(base: Path) -> HostFalso:
    """Host com unbound saudavel, sem bind."""
    h = HostFalso(base)
    _base_core(h)
    _base_tuning(h)
    h.arquivo("/var/lib/unbound/root.key", ". IN DS 20326 8 2 e06d44b8...\n")
    h.arquivo("/etc/security/limits.conf", "# sem entrada para unbound\n")

    h.comando(
        "systemctl",
        [
            ("list-unit-files unbound.service", 0,
             "UNIT FILE       STATE   PRESET\nunbound.service enabled enabled\n\n1 unit files listed.\n"),
            ("is-active --quiet unbound", 0, ""),
            ("is-active unbound", 0, "active\n"),
            ("show unbound -p LimitNOFILE --value", 0, "16384\n"),
        ],
        padrao=(1, ""),
    )
    h.comando(
        "ss",
        [
            ("-lnt", 0, "LISTEN 0 10 127.0.0.1:53 0.0.0.0:*\n"),
            ("-lnu", 0, "UNCONN 0 0  127.0.0.1:53 0.0.0.0:*\n"),
        ],
        padrao=(0, ""),
    )
    h.comando(
        "unbound-checkconf",
        [(f"-o {k}", 0, v + "\n") for k, v in DUMP_UNBOUND_OK.items()] + [("", 0, "unbound-checkconf: no errors\n")],
        padrao=(0, ""),
    )
    h.comando(
        "dig",
        [
            ("*google.com A*+tcp*", 0, dig_resposta(answer=["google.com.\t168\tIN\tA\t142.250.219.174"])),
            (f"*google.com A*{SIMPLES}", 0, dig_resposta(answer=["google.com.\t168\tIN\tA\t142.250.219.174"])),
            ("*iana.org A*+dnssec*", 0,
             dig_resposta(flags="qr rd ra ad", answer=["iana.org.\t300\tIN\tA\t192.0.43.8"])),
            ("*dnssec-failed.org A*", 0, dig_resposta(status="SERVFAIL")),
            ("*example.com A*", 0, dig_resposta(answer=["example.com.\t120\tIN\tA\t93.184.216.34"])),
        ],
        padrao=(0, dig_resposta(status="SERVFAIL")),
    )
    return h


def cenario_docker(base: Path) -> HostFalso:
    h = HostFalso(base)
    _base_core(h)
    _base_tuning(h)
    h.arquivo(
        "/etc/docker/daemon.json",
        """
        {
          "log-driver": "json-file",
          "log-opts": {"max-size": "50m", "max-file": "3"}
        }
        """,
    )
    h.arquivo("/proc/sys/net/bridge/bridge-nf-call-iptables", "1\n")
    h.comando(
        "systemctl",
        [
            ("list-unit-files docker.service", 0,
             "UNIT FILE      STATE   PRESET\ndocker.service enabled enabled\n\n1 unit files listed.\n"),
            ("is-active --quiet docker", 0, ""),
            ("is-active docker", 0, "active\n"),
        ],
        padrao=(1, ""),
    )
    return h


def cenario_zabbix(base: Path) -> HostFalso:
    h = HostFalso(base)
    _base_core(h)
    _base_tuning(h)
    h.arquivo(
        "/etc/zabbix/zabbix_proxy.conf",
        """
        Server=10.20.30.40
        Hostname=proxy-01
        ProxyConfigFrequency=60
        DBPassword=segredo
        """,
        modo=0o640,
    )
    h.comando(
        "systemctl",
        [
            ("list-unit-files zabbix-proxy.service", 0,
             "UNIT FILE            STATE   PRESET\nzabbix-proxy.service enabled enabled\n\n1 unit files listed.\n"),
            ("is-active --quiet zabbix-proxy", 0, ""),
            ("is-active zabbix-proxy", 0, "active\n"),
            ("show zabbix-proxy -p LimitNOFILE --value", 0, "32768\n"),
        ],
        padrao=(1, ""),
    )
    h.comando("stat", [("*", 0, "640\n")], padrao=(1, ""))
    return h


def cenario_pve(base: Path) -> HostFalso:
    h = HostFalso(base)
    _base_core(h)
    _base_tuning(h)
    h.diretorio("/etc/pve/nodes")
    h.comando("pveversion", [("*", 0, "pve-manager/8.2.4/abcdef (running kernel: 6.8.12-1-pve)\n")],
              padrao=(0, "pve-manager/8.2.4/abcdef\n"))
    h.comando("pvesm", [("status", 0,
                         "Name        Type     Status  Total   Used   Avail  %\n"
                         "local        dir     active  100G    20G     80G  20\n"
                         "local-lvm  lvmthin   active  400G   100G    300G  25\n")],
              padrao=(0, ""))
    h.comando(
        "systemctl",
        [(f"is-active {s}", 0, "active\n") for s in
         ("pve-cluster", "pvedaemon", "pveproxy", "pvestatd")] +
        [("is-active --quiet *", 0, "")],
        padrao=(1, ""),
    )
    return h


# =============================================================================
# fixtures
# =============================================================================
@pytest.fixture
def host_bind(tmp_path):
    return cenario_bind(tmp_path)


@pytest.fixture
def host_unbound(tmp_path):
    return cenario_unbound(tmp_path)


@pytest.fixture
def host_docker(tmp_path):
    return cenario_docker(tmp_path)


@pytest.fixture
def host_zabbix(tmp_path):
    return cenario_zabbix(tmp_path)


@pytest.fixture
def host_pve(tmp_path):
    return cenario_pve(tmp_path)


@pytest.fixture(scope="session")
def bit_de_execucao_adere(tmp_path_factory):
    """Pula o teste quando o filesystem ignora o bit de execucao.

    No NTFS o chmod 0644 do Python nao adere e o bash continua vendo o arquivo
    como executavel. Testes que dependem de +x/-x medem o filesystem, nao o
    toolkit — e falhar neles no Windows treinaria o operador a ignorar
    vermelho na suite. No Linux (CI e frota) rodam normalmente.
    """
    d = tmp_path_factory.mktemp("chmod")
    f = d / "sonda.sh"
    f.write_text("#!/usr/bin/env bash\n", encoding="utf-8", newline="\n")
    os.chmod(f, 0o644)
    proc = roda_bash([bash(), "-c", f'[[ -x "{posix(f)}" ]] && echo SIM || echo NAO'])
    if "NAO" not in proc.stdout:
        pytest.skip("filesystem nao guarda o bit de execucao (NTFS)")
    return True


@pytest.fixture
def host_vazio(tmp_path):
    """So o core respondendo; todo servico ausente."""
    h = HostFalso(tmp_path)
    _base_core(h)
    h.comando("systemctl", padrao=(1, ""))
    return h


# =============================================================================
# asserts de alto nivel
# =============================================================================
def sem_vermelho(mapa, proc=None):
    """Nenhum caso RED. Mostra quais falharam quando quebra."""
    ruins = {k: v for k, v in mapa.items() if v == "RED"}
    assert not ruins, (
        f"esperado nenhum RED, vieram: {ruins}"
        + (f"\n--- stdout ---\n{proc.stdout[:1500]}" if proc else "")
    )


def apenas_vermelho(mapa, *ids):
    """Exatamente estes ids em RED — nem um a mais, nem um a menos.

    O 'nem um a mais' e a parte que importa: um defeito injetado que derruba
    tres casos indica checagem acoplada, e o operador perde o rastro da causa.
    """
    esperados = set(ids)
    vieram = {k for k, v in mapa.items() if v == "RED"}
    assert vieram == esperados, (
        f"RED esperados {sorted(esperados)}, vieram {sorted(vieram)}; "
        f"sobrando {sorted(vieram - esperados)}, faltando {sorted(esperados - vieram)}"
    )


def apenas_amarelo(mapa, *ids):
    esperados = set(ids)
    vieram = {k for k, v in mapa.items() if v == "YELLOW"}
    assert vieram == esperados, (
        f"YELLOW esperados {sorted(esperados)}, vieram {sorted(vieram)}; "
        f"sobrando {sorted(vieram - esperados)}, faltando {sorted(esperados - vieram)}"
    )
