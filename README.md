# foundry-agent-creation

Deploy (and optionally smoke-test) an [Azure AI Foundry](https://learn.microsoft.com/azure/ai-foundry/)
**Prompt Agent** from a declarative `agent.yaml` file.

The agent references a model exposed through a BYO-gateway (APIM) connection and
is created with the verified pattern:
`project_client.agents.create_version(PromptAgentDefinition(model=...))`.

## Repository layout

```
.
├── configs/                 # Declarative agent definitions (one YAML per agent)
│   ├── test-agent.yaml.yaml
├── scripts/                 # Cross-platform wrappers (venv bootstrap + run)
│   ├── deploy-agent.sh      # Bash / Linux / macOS
│   └── deploy-agent.ps1     # PowerShell / Windows
├── src/
│   └── deploy_agent.py      # Entry point
├── requirements.txt
├── LICENSE
└── README.md
```

## Prerequisites

- Python 3.9+
- Azure CLI, authenticated so `DefaultAzureCredential` can reach Foundry:

  ```bash
  az login
  ```

## Usage

### Option 1 — wrapper scripts (recommended)

The wrappers create a local `.venv`, install `requirements.txt` on first run,
then forward all arguments to the Python entry point.

**Bash (Linux/macOS):**

```bash
scripts/deploy-agent.sh configs/test-agent.yaml
scripts/deploy-agent.sh configs/test-agent.yaml --invoke "Are you ready?"
scripts/deploy-agent.sh configs/test-agent.yaml --delete
```

**PowerShell (Windows/macOS/Linux):**

```powershell
./scripts/deploy-agent.ps1 configs/test-agent.yaml
./scripts/deploy-agent.ps1 configs/test-agent.yaml --invoke "Are you ready?"
./scripts/deploy-agent.ps1 configs/test-agent.yaml --delete
```

Wrapper environment variables:

| Variable    | Default       | Description                                    |
| ----------- | ------------- | ---------------------------------------------- |
| `PYTHON`    | `python3`/`python` | Interpreter used to bootstrap the venv    |
| `VENV_DIR`  | `<repo>/.venv` | Virtualenv location                           |
| `SKIP_VENV` | unset         | Set to `1` to run with the current interpreter |

### Option 2 — run the Python script directly

```bash
python -m venv .venv && source .venv/bin/activate   # or .venv\Scripts\activate on Windows
pip install -r requirements.txt

python src/deploy_agent.py configs/test-agent.yaml
python src/deploy_agent.py configs/test-agent.yaml --invoke "Are you ready?"
python src/deploy_agent.py configs/test-agent.yaml --delete
```

## Command-line arguments

| Argument           | Description                                                        |
| ------------------ | ----------------------------------------------------------------- |
| `config.yaml`      | Path to the agent definition (required).                          |
| `--invoke [MSG]`   | Smoke-test the agent after deploy. Optional custom message.       |
| `--delete`         | Delete the latest version of the agent instead of deploying.      |

## Agent definition

Each file in `configs/` describes one agent:

```yaml
foundry:
  accountName: {foundry-resource-name}
  projectName: {foundry-project-name}

agent:
  name: test-agent.yaml
  model: Demo-Demo1-DEV-LLM/gpt-4o   # "<connection-name>/<model-name>"
  instructions: |
    You are a connection-test agent ...
```

The `model` is referenced as `<connection-name>/<model-name>`. At runtime
Foundry resolves it through the APIM gateway's dynamic discovery endpoint.

## Hosted agents

A **hosted agent** runs your own container image inside the Foundry project
instead of a model behind a prompt. Build and push the image to an ACR the
Foundry project's managed identity can pull from, then deploy it with
[src/deploy_hosted_agent.py](src/deploy_hosted_agent.py):

```bash
python src/deploy_hosted_agent.py configs/hosted-agent.yaml
python src/deploy_hosted_agent.py configs/hosted-agent.yaml --invoke "Hello"
python src/deploy_hosted_agent.py configs/hosted-agent.yaml --delete
```

Hosted agent definition ([configs/hosted-agent.yaml](configs/hosted-agent.yaml)):

```yaml
foundry:
  accountName: {foundry-resource-name}
  projectName: {foundry-project-name}

agent:
  name: my-hosted-agent
  image: myacr.azurecr.io/my-hosted-agent:20260612   # immutable tag, never "latest"
  cpu: "1"
  memory: "2Gi"
  protocols:
    - protocol: responses   # responses | invocations | invocations_ws | mcp
      version: v1
  environment_variables: {}
```

### Code-based hosted agents (no Docker)

You can deploy a hosted agent **directly from source code — no Docker image and
no container registry**. [src/deploy_code_agent.py](src/deploy_code_agent.py)
zips a local source folder, uploads it, and Foundry builds + runs it for you
(verified pattern: `client.agents.create_version_from_code(...)` with a
`code_configuration`).

A sample agent built with **Microsoft Agent Framework** (OpenAI-compatible
`responses` protocol) lives in [agents/code-agent/](agents/code-agent/):

```bash
python src/deploy_code_agent.py configs/code-agent.yaml
python src/deploy_code_agent.py configs/code-agent.yaml --invoke "Hello"
python src/deploy_code_agent.py configs/code-agent.yaml --delete
```

#### Where instructions and tools live

A hosted agent **is your code**, so — unlike a prompt agent — the system
instructions and tools are **not** in the deployment YAML. They live in
[agents/code-agent/main.py](agents/code-agent/main.py):

- **System instructions** — the `SYSTEM_INSTRUCTIONS` string, passed as
  `instructions=` to the `Agent(...)`.
- **Tools / MCP servers** — the `tools=[...]` argument. Foundry-managed tools
  are reached through a single **Foundry Toolbox MCP endpoint**. Create the
  toolbox in the Foundry Portal or Foundry Toolkit (VS Code), then set its
  endpoint as `TOOLBOX_ENDPOINT` in the config's `environment_variables`;
  `main.py` reads it and wires it as an `MCPStreamableHTTPTool`.

Foundry injects `FOUNDRY_PROJECT_ENDPOINT` and `FOUNDRY_MODEL_DEPLOYMENT_NAME`
at runtime (they are reserved — do not put them in the YAML). For **local
testing**, set them in a `.env` file inside `agents/code-agent/` and run
`az login` first:

```bash
cd agents/code-agent
pip install -r requirements.txt
cat > .env <<'ENV'
FOUNDRY_PROJECT_ENDPOINT=https://<account>.services.ai.azure.com/api/projects/<project>
FOUNDRY_MODEL_DEPLOYMENT_NAME=<your-model-deployment>
# TOOLBOX_ENDPOINT=https://<your-toolbox-mcp-endpoint>
ENV
python main.py
# in another shell:
curl -X POST http://localhost:8088/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"none","input":"are you ready?"}'
```

Code-based agent definition ([configs/code-agent.yaml](configs/code-agent.yaml)):

```yaml
foundry:
  accountName: {foundry-resource-name}
  projectName: {foundry-project-name}

agent:
  name: code-agent
  sourceDir: ../agents/code-agent   # folder to zip, relative to this config
  runtime: python_3_12              # python_3_11 | python_3_12 | python_3_13
  entryPoint: ["python", "main.py"] # command Foundry runs to start the agent
  dependencyResolution: remote_build # service installs from requirements.txt
  cpu: "1"
  memory: "2Gi"
  protocols:
    - protocol: responses
      version: v1
  environment_variables: {}
```

`dependencyResolution: remote_build` makes Foundry install packages from the
`requirements.txt` inside the uploaded zip — so you do not need to install or
vendor dependencies locally. Use `bundled` instead if you vendor all
dependencies into the source folder yourself.

