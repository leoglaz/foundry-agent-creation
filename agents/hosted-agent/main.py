# =============================================================================
# Foundry Hosted Agent (image-based) - Microsoft Agent Framework sample
# =============================================================================
# A hosted agent IS your code. Unlike a prompt agent, the system instructions
# and the tools/MCP servers are NOT declared in the deployment YAML -- they are
# defined right here, in the agent code.
#
#   * SYSTEM INSTRUCTIONS  -> the `instructions=` argument below.
#   * TOOLS / MCP SERVERS  -> the `tools=[...]` argument below. Foundry-managed
#                             tools are reached through a single Foundry Toolbox
#                             MCP endpoint (env var TOOLBOX_ENDPOINT).
#
# Deployed AS A CONTAINER IMAGE: this folder is built into a Docker image,
# pushed to ACR, and run by Foundry (see scripts/build-deploy-hosted-agent.sh
# and src/deploy_hosted_agent.py).
#
# The hosting adapter (ResponsesHostServer) starts an HTTP server on port 8088
# and exposes the OpenAI-compatible `responses` protocol. `server.run()` MUST be
# the default entrypoint.
# =============================================================================

import logging
import os

from agent_framework import Agent, MCPStreamableHTTPTool
from agent_framework_foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

# Let env vars injected by Foundry at runtime win over local .env values.
load_dotenv(override=False)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("hosted-agent")

# -----------------------------------------------------------------------------
# 1) SYSTEM INSTRUCTIONS
#    This is the agent's system prompt. Edit this string to change behavior.
# -----------------------------------------------------------------------------
SYSTEM_INSTRUCTIONS = (
    "You are a helpful assistant for the Azure AI Foundry platform. Answer questions, perform tasks, and use tools as needed to assist the user. "
    "Be concise, accurate, and cite tool results when you use them."
)

# Foundry injects FOUNDRY_PROJECT_ENDPOINT for code-based agents, but NOT for
# image-based hosted agents. Because FOUNDRY_* is reserved and cannot be set in
# the deploy config, fall back to the non-reserved PROJECT_ENDPOINT var.
PROJECT_ENDPOINT = os.environ.get("FOUNDRY_PROJECT_ENDPOINT") or os.environ.get(
    "PROJECT_ENDPOINT"
)

# Model reference, e.g. "Demo-Demo1-STD-LLM/gpt-4o" (same <connection>/<model>
# form the prompt agents use). Passed via the non-reserved MODEL_DEPLOYMENT_NAME
# var because FOUNDRY_* env vars are reserved and cannot be set in the deploy
# config; falls back to FOUNDRY_MODEL_DEPLOYMENT_NAME for local testing.
MODEL_DEPLOYMENT = os.environ.get("MODEL_DEPLOYMENT_NAME") or os.environ.get(
    "FOUNDRY_MODEL_DEPLOYMENT_NAME"
)

# Optional: the Foundry Toolbox MCP endpoint. Set TOOLBOX_ENDPOINT in the
# deployment config's `environment_variables` (NO FOUNDRY_ prefix -- reserved).
TOOLBOX_ENDPOINT = os.environ.get("TOOLBOX_ENDPOINT")

# Optional: a direct MCP server (streamable HTTP). Set MCP_SERVER_URL in the
# deployment config's `environment_variables`. Used here for the MS Learn MCP.
MCP_SERVER_URL = os.environ.get("MCP_SERVER_URL")
MCP_SERVER_LABEL = os.environ.get("MCP_SERVER_LABEL", "mcp-server")


def build_agent() -> Agent:
    """Construct the model-backed agent with instructions and tools."""
    credential = DefaultAzureCredential()

    chat_client = FoundryChatClient(
        project_endpoint=PROJECT_ENDPOINT,
        model=MODEL_DEPLOYMENT,
        credential=credential,
    )

    # -------------------------------------------------------------------------
    # 2) TOOLS / MCP SERVERS
    #    Wire Foundry-managed tools via the Toolbox MCP endpoint, and/or connect
    #    directly to an MCP server via MCP_SERVER_URL. Add more tools as needed.
    # -------------------------------------------------------------------------
    tools = []
    if TOOLBOX_ENDPOINT:
        tools.append(
            MCPStreamableHTTPTool(
                name="foundry-toolbox",
                url=TOOLBOX_ENDPOINT,
            )
        )
    if MCP_SERVER_URL:
        tools.append(
            MCPStreamableHTTPTool(
                name=MCP_SERVER_LABEL,
                url=MCP_SERVER_URL,
            )
        )
    if not tools:
        logger.warning(
            "No MCP endpoints set (TOOLBOX_ENDPOINT / MCP_SERVER_URL); "
            "running without tools."
        )

    return Agent(
        client=chat_client,
        instructions=SYSTEM_INSTRUCTIONS,
        tools=tools,
        name="hosted-agent",
    )


# The hosting adapter translates the Foundry `responses` protocol to/from the
# agent and manages conversation state, serialization, and streaming for you.
server = ResponsesHostServer(build_agent())


if __name__ == "__main__":
    server.run()
