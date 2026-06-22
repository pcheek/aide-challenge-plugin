# AIDE Live Challenge plugin

A Claude Code plugin marketplace for [AIDE Live Challenges](https://aide-app-production.up.railway.app).
It installs a small, fire-and-forget activity hook so your Claude usage during a challenge streams to the
live projector, where it is ranked and used to coach you in real time. The hook never blocks Claude and
always exits cleanly.

## Install

In Claude Code (terminal, an IDE extension, or claude.ai/code on the web):

```bash
claude plugin marketplace add pcheek/aide-challenge-plugin
claude plugin install aide-challenge@aide-challenge
```

Or with the slash command inside an interactive session:

```
/plugin marketplace add pcheek/aide-challenge-plugin
/plugin install aide-challenge@aide-challenge
```

On install you are prompted for a few config values. Your challenge webpage pre-fills these for you
(participant token, challenge id, ingest url, and an optional ingest token).

## What it does

One dependency-free bash script (`log-usage.sh`, just bash + curl + base64) is wired to every relevant
Claude Code event (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`,
`SubagentStop`, `PreCompact`, `SessionEnd`). Each event is POSTed to the challenge ingest endpoint. On turn
and session boundaries it also includes the session transcript so the challenge can show your full activity.
It is fire-and-forget (the request is detached and the hook always exits 0), so a slow or unreachable server
never blocks Claude.

## Surfaces

Hooks run only in **Claude Code** environments: the terminal CLI, the VS Code / JetBrains extensions, and
**claude.ai/code** (Claude Code on the web). The Claude Desktop chat app and the claude.ai chat product do
not run hooks; use one of the Claude Code surfaces above (claude.ai/code works entirely in the browser).

## Uninstall

```bash
claude plugin uninstall aide-challenge@aide-challenge
claude plugin marketplace remove aide-challenge
```

## Privacy

The plugin reports your Claude usage for the duration of a challenge you joined. Do not put anything into
Claude that you would not want shown on the challenge screen. Uninstall instructions are presented when the
challenge ends, and the challenge server stops accepting telemetry for an ended challenge.
