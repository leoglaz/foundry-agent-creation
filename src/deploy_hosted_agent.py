#!/usr/bin/env python3
"""
Deploy (and optionally invoke) a Foundry Hosted Agent from an agent.yaml file.

Creates a versioned Hosted Agent in an Azure AI Foundry project that runs a
custom container image, using the verified pattern:
    project_client.agents.create_version(HostedAgentDefinition(...))

A hosted agent runs your own container image inside the Foundry project and
exposes one or more ingress protocols (responses, invocations, invocations_ws,
mcp). The image must already be built and pushed to an ACR that the Foundry
project's managed identity can pull from.

Usage:
    az login                     # ensure DefaultAzureCredential can reach Foundry
    pip install -r requirements.txt
    python src/deploy_hosted_agent.py configs/hosted-agent.yaml
    python src/deploy_hosted_agent.py configs/hosted-agent.yaml --invoke "Hello"
    python src/deploy_hosted_agent.py configs/hosted-agent.yaml --delete
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    HostedAgentDefinition,
    ContainerConfiguration,
    ProtocolVersionRecord,
)


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
    for key in ("name", "image", "cpu", "memory", "protocols"):
        if not cfg["agent"].get(key):
            sys.exit(f"ERROR: agent.{key} missing in {path}")

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


def deploy(client: AIProjectClient, agent_cfg: dict):
    name = agent_cfg["name"]
    image = agent_cfg["image"]
    print(f"-> Creating/updating hosted agent version: name={name}, image={image}")
    agent = client.agents.create_version(
        agent_name=name,
        definition=HostedAgentDefinition(
            cpu=str(agent_cfg["cpu"]),
            memory=str(agent_cfg["memory"]),
            container_configuration=ContainerConfiguration(image=image),
            protocol_versions=[
                ProtocolVersionRecord(protocol=p["protocol"], version=p["version"])
                for p in agent_cfg["protocols"]
            ],
            environment_variables=agent_cfg.get("environment_variables") or {},
        ),
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
    parser = argparse.ArgumentParser(description="Deploy a Foundry Hosted Agent from agent.yaml")
    parser.add_argument("agent_file",
                        help="Path to the agent.yaml file describing the hosted agent to deploy")
    parser.add_argument("--invoke", metavar="MESSAGE", nargs="?", const="Reply with one word: READY",
                        help="Smoke-test the agent after deploy (optional custom message)")
    parser.add_argument("--delete", action="store_true",
                        help="Delete the latest version of the agent instead of deploying")
    args = parser.parse_args()

    cfg = load_config(Path(args.agent_file))
    client = build_client(cfg["foundry"]["accountName"], cfg["foundry"]["projectName"])

    if args.delete:
        delete_latest(client, cfg["agent"]["name"])
        return

    agent = deploy(client, cfg["agent"])
    if args.invoke is not None:
        invoke(client, agent, args.invoke)


if __name__ == "__main__":
    main()
