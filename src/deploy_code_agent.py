#!/usr/bin/env python3
"""
Deploy (and optionally invoke) a Foundry Hosted Agent directly from source code,
WITHOUT building or publishing a Docker image.

Foundry's code-based deployment zips a local source folder, uploads it, and the
service builds + runs it for you. This uses the verified SDK pattern:

    client.agents.create_version_from_code(
        agent_name=...,
        content=CreateAgentVersionFromCodeContent(metadata=..., code=(zip)),
        code_zip_sha256=<sha256 of zip>,
    )

The hosted agent definition uses `code_configuration` (runtime + entry_point)
instead of a container image. Dependency resolution:
  - remote_build (default here): the service installs from requirements.txt
    inside the zip. No local install needed.
  - bundled: you must vendor all dependencies into the zip yourself.

Usage:
    az login                     # ensure DefaultAzureCredential can reach Foundry
    pip install -r requirements.txt
    python src/deploy_code_agent.py configs/code-agent.yaml
    python src/deploy_code_agent.py configs/code-agent.yaml --invoke "Hello"
    python src/deploy_code_agent.py configs/code-agent.yaml --delete
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import io
import sys
import zipfile
from pathlib import Path

import yaml
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    HostedAgentDefinition,
    CodeConfiguration,
    ProtocolVersionRecord,
    CreateAgentVersionFromCodeContent,
    CreateAgentVersionFromCodeMetadata,
)

# Files/dirs never included in the uploaded code zip.
DEFAULT_EXCLUDES = [
    ".venv", "venv", "__pycache__", "*.pyc", ".git", ".gitignore",
    ".env", ".DS_Store", "*.zip",
]


def load_config(path: Path) -> dict:
    if not path.is_file():
        sys.exit(f"ERROR: agent definition not found: {path}")
    with path.open("r", encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh)

    for key in ("foundry", "agent"):
        if key not in cfg:
            sys.exit(f"ERROR: '{key}' section missing in {path}")
    for key in ("accountName", "projectName"):
        if not cfg["foundry"].get(key):
            sys.exit(f"ERROR: foundry.{key} missing in {path}")
    for key in ("name", "sourceDir", "runtime", "entryPoint", "cpu", "memory", "protocols"):
        if not cfg["agent"].get(key):
            sys.exit(f"ERROR: agent.{key} missing in {path}")

    entry_point = cfg["agent"]["entryPoint"]
    if not isinstance(entry_point, list) or not entry_point:
        sys.exit(f"ERROR: agent.entryPoint must be a non-empty list in {path}")

    protocols = cfg["agent"]["protocols"]
    if not isinstance(protocols, list) or not protocols:
        sys.exit(f"ERROR: agent.protocols must be a non-empty list in {path}")
    for entry in protocols:
        for key in ("protocol", "version"):
            if not entry.get(key):
                sys.exit(f"ERROR: each agent.protocols entry needs '{key}' in {path}")
    return cfg


def build_client(account_name: str, project_name: str) -> AIProjectClient:
    endpoint = f"https://{account_name}.services.ai.azure.com/api/projects/{project_name}"
    print(f"-> Connecting to Foundry project: {endpoint}")
    return AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential())


def _is_excluded(rel_path: Path, excludes: list[str]) -> bool:
    parts = rel_path.parts
    name = rel_path.name
    for pattern in excludes:
        if any(fnmatch.fnmatch(part, pattern) for part in parts):
            return True
        if fnmatch.fnmatch(name, pattern):
            return True
    return False


def build_code_zip(source_dir: Path, excludes: list[str]) -> tuple[bytes, str]:
    """Zip the source folder and return (zip_bytes, sha256_hex)."""
    if not source_dir.is_dir():
        sys.exit(f"ERROR: source directory not found: {source_dir}")

    files = sorted(
        p for p in source_dir.rglob("*")
        if p.is_file() and not _is_excluded(p.relative_to(source_dir), excludes)
    )
    if not files:
        sys.exit(f"ERROR: no files to package in {source_dir}")

    buffer = io.BytesIO()
    # Deterministic zip (fixed timestamps) so an unchanged folder yields a
    # stable sha256 and Foundry can dedup identical uploads.
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as zf:
        for file_path in files:
            arcname = file_path.relative_to(source_dir).as_posix()
            info = zipfile.ZipInfo(arcname, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (file_path.stat().st_mode & 0xFFFF) << 16
            zf.writestr(info, file_path.read_bytes())

    data = buffer.getvalue()
    digest = hashlib.sha256(data).hexdigest()
    print(f"-> Packaged {len(files)} file(s) from {source_dir} "
          f"({len(data)} bytes, sha256={digest[:12]}...)")
    return data, digest


def deploy(client: AIProjectClient, agent_cfg: dict, config_dir: Path):
    name = agent_cfg["name"]
    source_dir = (config_dir / agent_cfg["sourceDir"]).resolve()
    excludes = DEFAULT_EXCLUDES + list(agent_cfg.get("exclude") or [])
    zip_bytes, sha256 = build_code_zip(source_dir, excludes)

    definition = HostedAgentDefinition(
        cpu=str(agent_cfg["cpu"]),
        memory=str(agent_cfg["memory"]),
        code_configuration=CodeConfiguration(
            runtime=agent_cfg["runtime"],
            entry_point=list(agent_cfg["entryPoint"]),
            dependency_resolution=agent_cfg.get("dependencyResolution", "remote_build"),
        ),
        protocol_versions=[
            ProtocolVersionRecord(protocol=p["protocol"], version=p["version"])
            for p in agent_cfg["protocols"]
        ],
        environment_variables=agent_cfg.get("environment_variables") or {},
    )

    print(f"-> Creating/updating code-based hosted agent: name={name}, "
          f"runtime={agent_cfg['runtime']}")
    agent = client.beta.agents.create_version_from_code(
        agent_name=name,
        content=CreateAgentVersionFromCodeContent(
            metadata=CreateAgentVersionFromCodeMetadata(
                description=agent_cfg.get("description"),
                definition=definition,
            ),
            code=(f"{name}.zip", zip_bytes, "application/zip"),
        ),
        code_zip_sha256=sha256,
    )
    print(f"OK  Agent version created: id={agent.id}, name={agent.name}, version={agent.version}")
    return agent


def invoke(client: AIProjectClient, agent, message: str):
    print(f"-> Invoking agent with: {message!r}")
    with client.get_openai_client() as openai_client:
        conversation = openai_client.conversations.create(
            items=[{"type": "message", "role": "user", "content": message}],
        )
        response = openai_client.responses.create(
            conversation=conversation.id,
            extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
        )
        text = getattr(response, "output_text", None) or str(response)
    print(f"OK  Agent response: {text}")
    return text


def delete_latest(client: AIProjectClient, name: str):
    versions = list(client.agents.list_versions(agent_name=name))
    if not versions:
        print(f"-> No versions found for agent '{name}'")
        return
    latest = versions[0]
    client.agents.delete_version(agent_name=name, agent_version=latest.version)
    print(f"OK  Deleted agent version: name={name}, version={latest.version}")


def main():
    parser = argparse.ArgumentParser(
        description="Deploy a code-based Foundry Hosted Agent (no Docker) from agent.yaml")
    parser.add_argument("agent_file",
                        help="Path to the agent.yaml file describing the agent to deploy")
    parser.add_argument("--invoke", metavar="MESSAGE", nargs="?", const="Reply with one word: READY",
                        help="Smoke-test the agent after deploy (optional custom message)")
    parser.add_argument("--delete", action="store_true",
                        help="Delete the latest version of the agent instead of deploying")
    args = parser.parse_args()

    config_path = Path(args.agent_file)
    cfg = load_config(config_path)
    client = build_client(cfg["foundry"]["accountName"], cfg["foundry"]["projectName"])

    if args.delete:
        delete_latest(client, cfg["agent"]["name"])
        return

    agent = deploy(client, cfg["agent"], config_path.parent)
    if args.invoke is not None:
        invoke(client, agent, args.invoke)


if __name__ == "__main__":
    main()
