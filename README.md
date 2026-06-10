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
