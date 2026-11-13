"""What the Traefik edge may write to its logs.

The access log goes to `docker service logs` (and Portainer). Until 2026-11 it kept the query
string, and clients put credentials there: the Stoat session token on `/ws`, the LiveKit JWT, the
Woodpecker webhook `access_token`, OAuth codes. Nothing failed, so only a check like this one
notices when a later edit brings it back.

The YAML is read as text (no PyYAML in CI): the `command:` list is one quoted flag per line.
"""

from __future__ import annotations

import pathlib
import re

import pytest

STACK = pathlib.Path(__file__).resolve().parent / "docker-stack.yml"
QUERY_DROP = "--accesslog.fields.queryparameters.defaultmode"
_FLAG = re.compile(r"""^\s*-\s*["']?(--[^"'\s]+)["']?\s*$""")


def stack_args(text: str) -> list[str]:
    return [m.group(1) for line in text.splitlines() if (m := _FLAG.match(line))]


def violations(args: list[str]) -> list[str]:
    # Traefik flag names are case-insensitive; the mode values are compared verbatim
    # (`Drop` silently falls back to the default, `keep`), so values are not normalized.
    flags = {}
    for arg in args:
        name, _, value = arg.partition("=")
        flags[name.lower()] = value
    found = []
    access_log_on = flags.get("--accesslog") != "false" and any(n.startswith("--accesslog") for n in flags)
    if access_log_on and flags.get(QUERY_DROP) != "drop":
        found.append("access log on without query parameters in drop")
    for name, value in flags.items():
        if name.startswith("--accesslog.fields.headers.") and value.lower() == "keep":
            found.append(f"header kept in access log: {name}")
    if flags.get("--log.level", "").upper() in ("DEBUG", "TRACE"):
        found.append("log.level DEBUG/TRACE logs the static config, X-Internal-Token included")
    return found


@pytest.mark.parametrize(
    ("args", "expected"),
    [
        (["--accesslog=true", "--accesslog.fields.queryParameters.defaultMode=drop"], 0),
        (["--accesslog=true"], 1),
        # Any accesslog.* option turns the access log on.
        (["--accesslog.filePath=/x.log"], 1),
        (["--accesslog=false"], 0),
        ([], 0),
        (["--accesslog=true", "--accesslog.fields.queryParameters.defaultMode=Drop"], 1),
        (["--accesslog=true", "--accesslog.fields.queryparameters.defaultmode=drop"], 0),
        (
            [
                "--accesslog=true",
                "--accesslog.fields.queryParameters.defaultMode=drop",
                "--accesslog.fields.headers.names.Referer=keep",
            ],
            1,
        ),
        (
            [
                "--accesslog=true",
                "--accesslog.fields.queryParameters.defaultMode=drop",
                "--accesslog.fields.headers.defaultMode=keep",
            ],
            1,
        ),
        (["--log.level=DEBUG"], 1),
        (["--log.level=trace"], 1),
        (["--log.level=INFO"], 0),
    ],
)
def test_violations(args: list[str], expected: int) -> None:
    assert len(violations(args)) == expected, violations(args)


def test_stack_args_reads_quoted_and_bare_flags() -> None:
    text = 'command:\n  - "--accesslog=true"\n  - --log.level=INFO\n  # - "--x=1"\nports:\n'
    assert stack_args(text) == ["--accesslog=true", "--log.level=INFO"]


def test_stack_file_passes() -> None:
    args = stack_args(STACK.read_text(encoding="utf-8"))
    # Guards the parser: an empty list would pass every rule.
    assert "--entrypoints.websecure.address=:443" in args
    assert "--accesslog=true" in args
    assert violations(args) == []
