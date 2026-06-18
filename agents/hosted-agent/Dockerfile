# =============================================================================
# Container image for the Foundry Hosted Agent (image-based path)
# =============================================================================
# Builds the hosted-agent into a container that speaks the Foundry `responses`
# protocol. ResponsesHostServer listens on port 8088 (see main.py).
#
# Build/push with: scripts/build-deploy-hosted-agent.sh
# =============================================================================
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Install dependencies first to leverage Docker layer caching.
COPY requirements.txt ./
RUN pip install --upgrade pip && pip install -r requirements.txt

# Copy the agent source.
COPY . .

# The hosting adapter (ResponsesHostServer) serves on 8088.
EXPOSE 8088

CMD ["python", "main.py"]
