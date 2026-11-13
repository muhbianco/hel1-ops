"""Troca exata no YAML vivo de uma stack (`--yaml-replace`).

Roda contra o YAML que só existe no Portainer, com segredo inline, e que por isso nunca é
impresso: ninguém confere o resultado a olho antes do PUT. A contagem exigida é o que impede uma
troca de pegar a linha errada, e este teste é o que garante que ela segura.
"""

from __future__ import annotations

import importlib.util
import pathlib

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "portainer-stack-update.py"
_spec = importlib.util.spec_from_file_location("portainer_stack_update", SCRIPT)
assert _spec and _spec.loader
psu = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(psu)

TYPEBOT = """services:
  typebot_builder:
    image: baptistearno/typebot-builder:latest ## Versão do Builder do Typebot
    environment:
      - DISABLE_SIGNUP=false
      - SEGREDO=valor-inline
  typebot_viewer:
    image: baptistearno/typebot-viewer:latest ## Versão do Viewer do Typebot
    environment:
      - DISABLE_SIGNUP=false
"""


def test_troca_todas_as_ocorrencias_esperadas() -> None:
    saida, status = psu.replace_exact(TYPEBOT, "DISABLE_SIGNUP=false", "DISABLE_SIGNUP=true", 2)
    assert status == "trocado"
    assert saida.count("DISABLE_SIGNUP=true") == 2
    assert "DISABLE_SIGNUP=false" not in saida
    # O resto do YAML, segredo inclusive, sai intacto.
    assert saida.replace("DISABLE_SIGNUP=true", "DISABLE_SIGNUP=false") == TYPEBOT


def test_contagem_diferente_aborta_sem_mexer() -> None:
    saida, status = psu.replace_exact(TYPEBOT, "DISABLE_SIGNUP=false", "DISABLE_SIGNUP=true", 1)
    assert status.startswith("ABORT")
    assert "2 vez(es)" in status
    assert saida == TYPEBOT


def test_linha_ausente_aborta() -> None:
    saida, status = psu.replace_exact(TYPEBOT, "N8N_IMAGE=x", "N8N_IMAGE=y", 1)
    assert status.startswith("ABORT")
    assert saida == TYPEBOT


def test_segunda_rodada_e_idempotente() -> None:
    uma, _ = psu.replace_exact(TYPEBOT, "DISABLE_SIGNUP=false", "DISABLE_SIGNUP=true", 2)
    duas, status = psu.replace_exact(uma, "DISABLE_SIGNUP=false", "DISABLE_SIGNUP=true", 2)
    assert status == "ja aplicado"
    assert duas == uma


def test_pin_de_imagem_pelo_digest_mantem_o_comentario() -> None:
    old = "image: baptistearno/typebot-builder:latest"
    new = old + "@sha256:" + "a" * 64
    saida, status = psu.replace_exact(TYPEBOT, old, new, 1)
    assert status == "trocado"
    assert new + " ## Versão do Builder do Typebot" in saida
    # O viewer não é tocado por uma troca que mira o builder.
    assert "image: baptistearno/typebot-viewer:latest ##" in saida


def test_pin_ja_aplicado_nao_casa_de_novo() -> None:
    """Depois do pin, OLD continua prefixo de NEW: a contagem tem de impedir pin duplo."""
    old = "image: baptistearno/typebot-builder:latest"
    new = old + "@sha256:" + "a" * 64
    uma, _ = psu.replace_exact(TYPEBOT, old, new, 1)
    duas, status = psu.replace_exact(uma, old, new, 1)
    assert status == "ja aplicado"
    assert duas == uma
    assert duas.count("@sha256:") == 1


def test_pin_parcial_aborta() -> None:
    """Uma de duas ocorrências já pinada: o YAML não é o esperado, então não mexe."""
    old = "DISABLE_SIGNUP=false"
    new = "DISABLE_SIGNUP=false-x"
    meio = TYPEBOT.replace(old, new, 1)
    saida, status = psu.replace_exact(meio, old, new, 2)
    assert status.startswith("ABORT")
    assert saida == meio


def test_recusa_multilinha_e_vazio() -> None:
    assert psu.replace_exact(TYPEBOT, "a\nb", "c", 1)[1].startswith("ABORT")
    assert psu.replace_exact(TYPEBOT, "", "c", 1)[1].startswith("ABORT")
    assert psu.replace_exact(TYPEBOT, "x", "x", 1)[1].startswith("ABORT")
    assert psu.replace_exact(TYPEBOT, "DISABLE_SIGNUP=false", "y", 0)[1].startswith("ABORT")
