# syntax=docker/dockerfile:1.7
#
# sandbot-devshell -- agent sandbox image.
#
# Design goals (see README.md for full rationale):
#   * Normal Debian userland so agents' first reflex (apt/pip/npm/cargo/curl) works.
#   * Rootless-podman-compatible; host is protected via user namespaces, not via
#     restrictions inside the image.
#   * Image contents are fully pinned: base image by digest, agent CLIs by
#     upstream release URL + sha256, apt packages accepted as Debian's choice.
#   * Rootfs is ephemeral per sandbot run; only /workdir and the agent state
#     directories persist. This image therefore bakes in common dev runtimes
#     so agents don't pay "apt install" cost every session.
#
# All ARG values are provided by the build wrapper from agent-versions.env.

ARG DEBIAN_BASE

# ----------------------------------------------------------------------------
# Stage 1: fetch and verify agent CLIs. Every artifact is checked against a
# sha256 declared in agent-versions.env; a mismatch aborts the build.
# ----------------------------------------------------------------------------
FROM ${DEBIAN_BASE} AS fetch

ARG CODEX_URL
ARG CODEX_SHA256
ARG OPENCODE_URL
ARG OPENCODE_SHA256
ARG GEMINI_CLI_URL
ARG GEMINI_CLI_SHA256
ARG CLAUDE_CODE_URL
ARG CLAUDE_CODE_SHA256

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Apt versions are not pinned; the digest-pinned Debian base image constrains
# package versions to that snapshot's archive state.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /out

# codex -- tarball is a single binary named codex-x86_64-unknown-linux-gnu.
RUN mkdir -p /out/codex \
 && curl -fsSL "${CODEX_URL}" -o codex.tgz \
 && echo "${CODEX_SHA256}  codex.tgz" | sha256sum -c - \
 && tar -xzf codex.tgz -C /out/codex \
 && rm codex.tgz \
 && mv /out/codex/codex-x86_64-unknown-linux-gnu /out/codex/codex \
 && chmod +x /out/codex/codex

# opencode -- tarball is a single `opencode` binary.
RUN mkdir -p /out/opencode \
 && curl -fsSL "${OPENCODE_URL}" -o opencode.tgz \
 && echo "${OPENCODE_SHA256}  opencode.tgz" | sha256sum -c - \
 && tar -xzf opencode.tgz -C /out/opencode \
 && rm opencode.tgz \
 && chmod +x /out/opencode/opencode

# gemini-cli -- zip with a top-level gemini.js (#!/usr/bin/env node) plus chunks.
RUN mkdir -p /out/gemini \
 && curl -fsSL "${GEMINI_CLI_URL}" -o gemini.zip \
 && echo "${GEMINI_CLI_SHA256}  gemini.zip" | sha256sum -c - \
 && unzip -q gemini.zip -d /out/gemini \
 && rm gemini.zip \
 && chmod +x /out/gemini/gemini.js

# claude-code -- the platform-native npm package, NOT the wrapper package.
# The tarball contains package/claude (ELF binary) and package/package.json.
RUN mkdir -p /out/claude \
 && curl -fsSL "${CLAUDE_CODE_URL}" -o claude.tgz \
 && echo "${CLAUDE_CODE_SHA256}  claude.tgz" | sha256sum -c - \
 && tar -xzf claude.tgz -C /out/claude --strip-components=1 \
 && rm claude.tgz \
 && chmod +x /out/claude/claude


# ----------------------------------------------------------------------------
# Stage 2: the actual sandbox image. Debian + apt + preinstalled dev runtimes
# + agent CLIs copied from stage 1.
# ----------------------------------------------------------------------------
FROM ${DEBIAN_BASE}

ARG CODEX_VERSION
ARG OPENCODE_VERSION
ARG GEMINI_CLI_VERSION
ARG CLAUDE_CODE_VERSION

# Baseline userland + dev toolchains. Kept in one layer so the apt cache is
# discarded cleanly. If agents frequently need "apt install X" at runtime,
# add X here -- rootfs is ephemeral, so runtime installs are lost on destroy.
# hadolint ignore=DL3008
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        sudo \
        procps \
        less \
        vim-tiny \
        man-db \
        locales \
        tzdata \
        curl \
        wget \
        git \
        jq \
        ripgrep \
        fd-find \
        fzf \
        openssh-client \
        unzip \
        xz-utils \
        zip \
        tar \
        build-essential \
        pkg-config \
        python3 \
        python3-pip \
        python3-venv \
        pipx \
        nodejs \
        npm \
        golang-go \
        rustc \
        cargo \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
 && locale-gen

# Agent CLIs from stage 1. Installed under /opt/agents and either symlinked
# or wrapped in /usr/local/bin. One directory per agent so bumps are atomic.
COPY --from=fetch /out/codex      /opt/agents/codex
COPY --from=fetch /out/opencode   /opt/agents/opencode
COPY --from=fetch /out/gemini     /opt/agents/gemini
COPY --from=fetch /out/claude     /opt/agents/claude

RUN set -eux \
 && ln -s /opt/agents/codex/codex       /usr/local/bin/codex \
 && ln -s /opt/agents/opencode/opencode /usr/local/bin/opencode \
 && ln -s /opt/agents/claude/claude     /usr/local/bin/claude \
 && printf '#!/bin/sh\nexec node /opt/agents/gemini/gemini.js "$@"\n' \
        > /usr/local/bin/gemini \
 && chmod +x /usr/local/bin/gemini

# codex-wrapper / cexec: invoke codex with sandbox-friendly defaults.
COPY scripts/codex-wrapper /usr/local/bin/codex-wrapper
COPY scripts/cexec         /usr/local/bin/cexec
RUN chmod +x /usr/local/bin/codex-wrapper /usr/local/bin/cexec

# IS_SANDBOX=1 keeps claude-code from refusing to run as root.
# See https://github.com/anthropics/claude-code/issues/927.
ENV IS_SANDBOX=1 \
    LANG=en_US.UTF-8 \
    HOME=/root \
    CARGO_TARGET_DIR=/root/cargo-target \
    UV_VENV_DIR=/root/uv-venv \
    PATH=/usr/local/bin:/usr/bin:/bin

LABEL org.opencontainers.image.title="sandbot-devshell" \
      org.opencontainers.image.description="Debian-based agent sandbox for sandbot" \
      sandbot.codex-version="${CODEX_VERSION}" \
      sandbot.opencode-version="${OPENCODE_VERSION}" \
      sandbot.gemini-cli-version="${GEMINI_CLI_VERSION}" \
      sandbot.claude-code-version="${CLAUDE_CODE_VERSION}"

WORKDIR /workdir

# Long-lived pid1. Agents run via `podman exec`, so pid1 stays trivial.
CMD ["sleep", "infinity"]
