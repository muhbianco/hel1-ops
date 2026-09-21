#!/usr/bin/env python3
"""Portainer stack create/update on hel1 without secrets leaving the host.

Portainer replaces the whole stack Env on update, and the MCP only sees masked values, so a
stack with `${VAR}` secrets (commerce, chatwoot, woodpecker) has to be updated with the API token
from the host (or from a CI step that mounts the token file).

  portainer-stack-update.py --stack commerce --yaml infra/docker-stack.yml \
      --set-env COMMERCE_TAG=<sha> [--env-file /root/.mucommerce-minio.env] [--prune] [--dry-run]
  portainer-stack-update.py --stack api-agents        # redeploy live YAML + Env as-is, repull
  portainer-stack-update.py --create --stack woodpecker --yaml woodpecker/docker-stack.yml \
      --env-file /root/.woodpecker.env [--dry-run]    # new Swarm stack, Env straight from the file

`--env-file` merges KEY=VALUE lines from a host file into the stack Env, so secrets go
file → Portainer directly.

Prints only stack id, env KEY names, which ${VARS} the YAML needs, sha256 of the YAML
and the HTTP status. Never prints env values or YAML content.

Environment (defaults match running on hel1 as root):
  PORTAINER_URL          http://127.0.0.1:9000
  PORTAINER_TOKEN_FILE   /root/.portainer-token
  PORTAINER_ENDPOINT_ID  1
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("PORTAINER_URL", "http://127.0.0.1:9000").rstrip("/")
TOKEN_PATH = pathlib.Path(os.environ.get("PORTAINER_TOKEN_FILE", "/root/.portainer-token"))
ENDPOINT_ID = int(os.environ.get("PORTAINER_ENDPOINT_ID", "1"))
OPTIONAL_EMPTY = {"SENTRY_DSN"}


def req(method: str, path: str, body: dict | None = None, query: dict | None = None):
    url = BASE + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = None if body is None else json.dumps(body).encode()
    headers = {"X-API-Key": TOKEN_PATH.read_text().strip(), "Content-Type": "application/json"}
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=300) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        return exc.code, {"error": exc.read().decode("utf-8", "replace")[:600]}


def sha(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def needed_vars(yaml_text: str) -> list[str]:
    # Compose interpolates values, not comments: skip comment lines.
    body_lines = [ln for ln in yaml_text.splitlines() if not ln.lstrip().startswith("#")]
    # `$${...}` is an escaped literal (e.g. a Traefik regex group), not a variable; variable
    # names start with a letter or underscore.
    return sorted(set(re.findall(r"(?<!\$)\$\{([A-Z_][A-Z0-9_]*)", "\n".join(body_lines))))


def merge_env(env: list[dict], assignments: list[str]) -> str | None:
    for item in assignments:
        key, _, value = item.partition("=")
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            return key
        for e in env:
            if e["name"] == key:
                e["value"] = value
                break
        else:
            env.append({"name": key, "value": value})
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stack", required=True)
    ap.add_argument("--yaml", type=pathlib.Path)
    ap.add_argument("--set-env", action="append", default=[])
    ap.add_argument("--env-file", action="append", default=[], type=pathlib.Path)
    ap.add_argument("--create", action="store_true", help="create a new Swarm stack (refuses if it exists)")
    ap.add_argument(
        "--allow-empty",
        action="append",
        default=[],
        metavar="KEY",
        help="a ${KEY} the YAML needs that may be empty in the Env (e.g. SMTP not configured yet)",
    )
    ap.add_argument("--prune", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    assignments = list(args.set_env)
    for env_file in args.env_file:
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                assignments.append(line)

    code, stacks = req("GET", "/api/stacks")
    if code != 200:
        print(f"stack list http={code}")
        return 2
    matches = [s for s in stacks if s.get("Name") == args.stack]

    if args.create:
        return create(args, matches, assignments)

    if len(matches) != 1:
        print(f"stack {args.stack!r} not found (matches={len(matches)})")
        return 2
    stack = matches[0]
    stack_id = stack["Id"]
    env = [dict(e) for e in (stack.get("Env") or [])]

    code, file_data = req("GET", f"/api/stacks/{stack_id}/file")
    if code != 200:
        print(f"file http={code}")
        return 2
    live_yaml = file_data.get("StackFileContent", "")
    yaml_text = args.yaml.read_text(encoding="utf-8") if args.yaml else live_yaml

    bad_key = merge_env(env, assignments)
    if bad_key is not None:
        print(f"ABORT: invalid env key {bad_key!r}")
        return 3

    needed = needed_vars(yaml_text)
    present = {e["name"]: bool(e.get("value")) for e in env}
    optional = OPTIONAL_EMPTY | set(args.allow_empty)
    missing = [k for k in needed if not present.get(k) and k not in optional]
    print(f"stack={args.stack} id={stack_id} env_keys={sorted(present)}")
    print(f"yaml live={sha(live_yaml)} new={sha(yaml_text)} needs={needed}")
    empty_allowed = sorted(k for k in needed if not present.get(k) and k in optional)
    if empty_allowed:
        print(f"empty by design: {empty_allowed}")
    if missing:
        print(f"ABORT: YAML needs env without value: {missing}")
        return 3
    if args.dry_run:
        print("dry-run: nothing sent")
        return 0

    body = {
        "StackFileContent": yaml_text,
        "Env": env,
        "Prune": bool(args.prune),
        "PullImage": True,
        "RepullImageAndRedeploy": True,
    }
    code, data = req("PUT", f"/api/stacks/{stack_id}", body=body, query={"endpointId": ENDPOINT_ID})
    print(f"update http={code} prune={bool(args.prune)}")
    if code not in (200, 201):
        print(f"error: {data.get('error', '')[:400]}")
        return 1

    code, after = req("GET", f"/api/stacks/{stack_id}")
    keys_after = sorted(e["name"] for e in (after.get("Env") or []))
    print(f"env_keys_after={keys_after}")
    added = sorted(set(keys_after) - {e["name"] for e in (stack.get("Env") or [])})
    if added:
        print(f"env_keys_added={added}")
    if keys_after != sorted(present):
        print("WARNING: env keys changed after update")
        return 4
    return 0


def create(args: argparse.Namespace, matches: list[dict], assignments: list[str]) -> int:
    if matches:
        print(f"ABORT: stack {args.stack!r} already exists (id={matches[0]['Id']}); run without --create")
        return 3
    if not args.yaml:
        print("ABORT: --create needs --yaml")
        return 3
    yaml_text = args.yaml.read_text(encoding="utf-8")
    env: list[dict] = []
    bad_key = merge_env(env, assignments)
    if bad_key is not None:
        print(f"ABORT: invalid env key {bad_key!r}")
        return 3

    needed = needed_vars(yaml_text)
    present = {e["name"]: bool(e.get("value")) for e in env}
    optional = OPTIONAL_EMPTY | set(args.allow_empty)
    missing = [k for k in needed if not present.get(k) and k not in optional]
    print(f"create stack={args.stack} env_keys={sorted(present)}")
    print(f"yaml new={sha(yaml_text)} needs={needed}")
    if missing:
        print(f"ABORT: YAML needs env without value: {missing}")
        return 3

    code, swarm = req("GET", f"/api/endpoints/{ENDPOINT_ID}/docker/swarm")
    swarm_id = swarm.get("ID") if code == 200 else None
    if not swarm_id:
        print(f"swarm id http={code}")
        return 2
    if args.dry_run:
        print("dry-run: nothing sent")
        return 0

    body = {"Name": args.stack, "SwarmID": swarm_id, "StackFileContent": yaml_text, "Env": env}
    code, data = req("POST", "/api/stacks/create/swarm/string", body=body, query={"endpointId": ENDPOINT_ID})
    print(f"create http={code}")
    if code not in (200, 201):
        print(f"error: {data.get('error', '')[:400]}")
        return 1
    keys_after = sorted(e["name"] for e in (data.get("Env") or []))
    print(f"stack id={data.get('Id')} env_keys_after={keys_after}")
    return 0 if keys_after == sorted(present) else 4


if __name__ == "__main__":
    sys.exit(main())
