# syntax=docker/dockerfile:1
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get -y --no-install-recommends install \
        build-essential \
        ca-certificates \
        curl \
        git \
        gnupg \
        libffi-dev \
        libssl-dev \
        mc \
        openssh-client \
        unzip \
        zlib1g-dev \
        && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1001 agent && \
    useradd --create-home --uid 1001 --gid 1001 --shell /bin/bash agent

USER agent:agent

ADD --chown=agent:agent mise.toml mise.toml
ADD --chown=agent:agent --chmod=755 entrypoint.sh /entrypoint.sh

WORKDIR /home/agent

RUN curl https://mise.run | bash && \
    ~/.local/bin/mise trust -ay && \
    echo "eval \"\$(/home/agent/.local/bin/mise activate bash)\"" >> ~/.bashrc

ENV PATH="/home/agent/.local/share/mise/shims:/home/agent/.local/bin:${PATH}"

RUN --mount=type=secret,id=github_token,uid=1001 \
    GITHUB_TOKEN=$(cat /run/secrets/github_token) \
    ~/.local/bin/mise install --verbose

ENTRYPOINT ["/entrypoint.sh"]
