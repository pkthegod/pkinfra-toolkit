"""proxmox_tune.sh: a baliza das decisoes do tuning de host, executada pelo CI.

As funcoes testadas decidem coisas que, erradas, falham em silencio: o
firewall do PVE define se o trafego das VMs passa pelo iptables do host; o
piso do ARC define se o teto pedido pega ou e ignorado pelo ZFS; a demanda de
hugepages define se o pool reservado tem consumidor. `prova-tune.sh` extrai as
funcoes REAIS do script e as roda contra uma raiz falsa.
"""

import re

from conftest import RAIZ, bash, posix, roda_bash

PROVA = RAIZ / "tests" / "prova-tune.sh"
TUNE = RAIZ / "bin" / "proxmox_tune.sh"
UPGRADE = RAIZ / "bin" / "pve-upgrade.sh"


def test_a_baliza_do_tuning_passa_inteira():
    proc = roda_bash([bash(), posix(PROVA), posix(TUNE)])
    assert "TODOS OS CASOS PASSARAM" in proc.stdout, (
        "a baliza de proxmox_tune.sh falhou:\n"
        f"--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}"
    )


def _bloco(caminho):
    texto = caminho.read_text(encoding="utf-8")
    m = re.search(r"^# ==== BLOCO DE ESTADO.*?^# ==== FIM DO BLOCO[^\n]*$", texto, re.M | re.S)
    assert m, f"bloco compartilhado nao encontrado em {caminho.name}"
    return m.group(0)


def test_bloco_de_estado_e_identico_nos_dois_scripts():
    """Secao 3.9 do TOOLKIT: o bloco e byte-identico. Divergir e como o bug 3
    voltou — corrigido num script, esquecido no outro."""
    assert _bloco(TUNE) == _bloco(UPGRADE)


def test_nenhum_env_gerado_sem_aspas():
    """Bug 3: toda linha CHAVE=valor escrita em .env pelo tuning leva aspas."""
    texto = TUNE.read_text(encoding="utf-8")
    sem_aspas = re.findall(r"^(?:FACT|TUNE)_[A-Z_]+=[^\"\n].*$", texto, re.M)
    assert not sem_aspas, f"valor de .env sem aspas: {sem_aspas}"
