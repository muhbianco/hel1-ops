"""Which `${VARS}` the Portainer Env has to carry.

This is the piece that decides whether a deploy runs at all, and it got it wrong once: a
`${VAR:-default}` was demanded as required, so a stack that carried its own fallback aborted
with "YAML needs env without value". A parser bug here stops production, silently and at the
worst moment, so it gets a test even though nothing else in this repo has one.
"""

from __future__ import annotations

import importlib.util
import pathlib

import pytest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "portainer-stack-update.py"
_spec = importlib.util.spec_from_file_location("portainer_stack_update", SCRIPT)
assert _spec and _spec.loader
psu = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(psu)


@pytest.mark.parametrize(
    ("yaml_text", "expected"),
    [
        ("a: ${PLAIN}", ["PLAIN"]),
        # Carries its own fallback: optional by definition.
        ("a: ${WITH_DEFAULT:-x,y}", []),
        ("a: ${DASH_DEFAULT-x}", []),
        # `:?` exists precisely to demand the value.
        ("a: ${REQUIRED:?missing}", ["REQUIRED"]),
        ("a: ${REQ2?missing}", ["REQ2"]),
        # `:+` uses the alternate only when the var is set, so the var still has to be there.
        ("a: ${ALT:+x}", ["ALT"]),
        # `$${...}` is an escaped literal (Traefik regex groups), not a variable.
        ("a: $${NOT_A_VAR}", []),
        ("# a: ${IN_COMMENT}", []),
    ],
)
def test_needed_vars(yaml_text: str, expected: list[str]) -> None:
    assert psu.needed_vars(yaml_text) == expected


def test_the_commerce_stack_asks_for_secrets_and_not_for_the_allowlists() -> None:
    """The real shape of the commerce stack: tag and secrets required, allowlists optional."""
    yaml_text = (
        "image: muhrilobianco/commerce_api:${COMMERCE_TAG:?COMMERCE_TAG obrigatorio}\n"
        "DB_PASSWORD: ${DB_PASSWORD}\n"
        "PAYMENTS_ALLOWED_PROVIDERS: ${PAYMENTS_ALLOWED_PROVIDERS:-mercadopago,pagbank}\n"
        "SHIPPING_ALLOWED_PROVIDERS: ${SHIPPING_ALLOWED_PROVIDERS:-melhorenvio}\n"
    )
    assert psu.needed_vars(yaml_text) == ["COMMERCE_TAG", "DB_PASSWORD"]
