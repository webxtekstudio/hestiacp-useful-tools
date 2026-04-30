# HestiaCP AI Ops & Integrations

This directory contains everything you need to supercharge your HestiaCP server with Large Language Models (LLMs) using modern AI paradigms.

Instead of being locked into a single platform, this architecture is **platform-agnostic**. You can orchestrate these components using n8n, Dify, Flowise, LangChain, or your own custom Node.js/Python Swarm pipelines.

## 🏗️ Architecture & What to Choose

### 1. The Core Blueprints (`/DevOps-AI-Prompts`)
**Goal:** Define the exact identities, constraints, and operational logic for your autonomous agents.
- **How it works:** We recommend a two-agent structure. One agent acts as a **passive system monitor** that collects server telemetry in 3 rounds via SSH and feeds it to an LLM for analysis. The other acts as an **active DevOps responder** that can run CLI commands interactively via SSH.
- **Data collection rounds:** Round 1 (system inventory + resources), Round 2 (services, PHP, backup), Round 3 (security audit: SSL, Fail2Ban, attack vectors, ports, logins, PHP mods). Each round is collected separately to avoid truncation.
- **Go to:** [`/DevOps-AI-Prompts/`](DevOps-AI-Prompts/) to find the modular System Prompts for both agents.

### 2. The Brain Boost (`/knowledge`)
**Goal:** Empower your Agents to be true HestiaCP specialists, not just generic Linux terminals.
- **How it works:** A comprehensive collection of 16 Markdown files covering HestiaCP CLI reference, PHP-FPM tuning, Exim/Dovecot troubleshooting, backup architecture (including `backup-core-patches` and remote B2/rclone backends), Fail2Ban, security auditing, and custom tools.
- **Where to use it:** Upload these files into your AI's "Knowledge Base" (Vector DB) and link them to your DevOps Agent using standard RAG (Retrieval-Augmented Generation) so it can pull documentation during troubleshooting.
- **Go to:** [`/knowledge/`](knowledge/) to explore the 16 reference files.

---

## 🔒 Security Best Practices

Before you connect AI to your production server, enforce these strict rules:

1. **Never share Root SSH Passwords:** Use SSH keys. Generate a unique ED25519 or RSA key pair exclusively for the AI Agent. Never reuse your personal SSH key.
2. **Read-Only / Isolated Users (Optional):** While these prompts are meant to solve problems (which usually requires `root` or `sudo` to run `v-commands`), if you only want the AI to perform benign audits, map it to a user with extremely restricted sudoers privileges. 
3. **Keep an Audit Log:** Use `auth.log` monitoring or bash history tracking combined with system-level fail-safes (Fail2Ban) to monitor what the AI executes.