# DevOps AI Prompts — P1 (Monitor) & P2 (Agent)

This folder contains two System Prompts that together form a complete **autonomous HestiaCP infrastructure management system**. They are the public, platform-agnostic equivalents of a private multi-agent pipeline — designed to work with **any AI platform or model**.

## The Two Prompts

### 📡 P1 — System Monitor (`System-Monitor-Prompt.md`)

**Role:** Passive, scheduled health monitor.

Works by receiving pre-collected SSH diagnostic data from 3 automated rounds and writing a structured health report. No human interaction required.

| Round | What it collects |
|---|---|
| **Round 1** | System inventory, resources (CPU, RAM, disk, swap, services, DB) |
| **Round 2** | Mail queue, PHP-FPM pools, Nginx config, backup status |
| **Round 3** | Security audit: SSL expiry, Fail2Ban, attack vectors, open ports, PHP mods, failed logins |

**Output:** A Markdown health report with `STATUS: HEALTHY` or `STATUS: ALERT` + severity.

**Typical use:** Run via cron (e.g., 2× per day). Collect SSH data with a shell script, feed it to an LLM with this prompt, send the report to Telegram/WhatsApp/Slack.

---

### 🤖 P2 — DevOps Agent (`DevOps-Agent-Prompt.md`)

**Role:** Active, interactive infrastructure controller.

An on-demand agent with root SSH access that can diagnose and fix issues in real time via a `run_ssh_command` tool in a ReAct loop.

**Typical use:** Wire this to a Telegram/WhatsApp/Discord bot or a chat interface. The user sends a request ("the site is down", "check the mail queue") and the agent investigates, acts, and reports back.

---

## Platform-Agnostic Design

These prompts run on any LLM or platform:

| Platform | How to use |
|---|---|
| **n8n** | HTTP node for SSH collection → LLM node with the prompt |
| **Dify / Flowise / LangFlow** | System prompt injection + SSH tool |
| **Node.js / Python** | Feed prompt to any AI SDK + implement `run_ssh_command` as a function tool |
| **Claude / GPT / Gemini** | Paste the prompt directly as the system prompt |

---

## Required Tools

Both agents need one tool wired up in your platform:

```
run_ssh_command(command: string) → string
```

This executes a bash command on the server as root via SSH and returns the output. P1 uses it for deep-dive investigation when anomalies are found. P2 uses it for all active operations.

---

## Setup

1. **Collect SSH data** for P1 using a shell script that runs all 3 rounds and passes the output as context to the LLM.
2. **Wire `run_ssh_command`** as a function tool in your platform for both agents.
3. **Link the `/knowledge` files** to P2 via RAG or static context injection.
4. **Customize** the placeholder values in the prompts (`[YOUR_AGENT_NAME]`, `[YOUR_TARGET_LANGUAGE]`).

> **Note:** Do NOT hardcode server IPs, credentials, or domain names into the prompts. Pass them via environment variables or your platform's secret store.
