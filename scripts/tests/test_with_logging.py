"""Patch de rotação de log no YAML vivo de uma stack.

Ele roda contra o YAML que só existe no editor do Portainer — aquele com segredo inline, que
por isso nunca é baixado para arquivo nem impresso. Como ninguém consegue conferir o resultado
a olho antes do PUT, o que dá confiança é este teste.
"""

from __future__ import annotations

import importlib.util
import pathlib

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "portainer-stack-update.py"
_spec = importlib.util.spec_from_file_location("portainer_stack_update", SCRIPT)
assert _spec and _spec.loader
psu = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(psu)

STACK = """version: "3.8"

services:
  app_site:
    image: muhrilobianco/app_site:latest
    environment:
      SEGREDO: valor-inline
    deploy:
      replicas: 1
  worker:
    image: muhrilobianco/app_site:latest
    command: worker

networks:
  chatbot-net:
    external: true
"""


def test_cada_servico_ganha_a_rotacao() -> None:
    saida, postos = psu.with_logging(STACK)
    assert postos == 2
    assert saida.count("logging: *logging") == 2
    assert "x-logging: &logging" in saida
    # A âncora tem de vir antes do primeiro uso, senão o YAML não resolve.
    assert saida.index("x-logging: &logging") < saida.index("logging: *logging")


def test_nao_confunde_chave_de_topo_com_servico() -> None:
    """`networks:` fecha o bloco de serviços; o que vem depois dele não é serviço."""
    saida, _ = psu.with_logging(STACK)
    depois = saida.split("networks:")[1]
    assert "logging" not in depois


def test_o_que_ja_estava_no_yaml_continua_la() -> None:
    saida, _ = psu.with_logging(STACK)
    for linha in STACK.split("\n"):
        assert linha in saida


def test_rodar_duas_vezes_nao_duplica() -> None:
    uma, _ = psu.with_logging(STACK)
    duas, postos = psu.with_logging(uma)
    assert postos == 0
    assert duas == uma


def test_yaml_sem_servicos_nao_e_tocado() -> None:
    texto = "version: '3.8'\nnetworks:\n  x: {}\n"
    assert psu.with_logging(texto) == (texto, 0)
