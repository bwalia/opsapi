# Claude skills for OpsAPI

Skills teach Claude (Claude Code, the Claude apps, the Agent SDK) how to use OpsAPI correctly: the real
endpoints, fields and gotchas, instead of guesses.

| Skill | What it is for |
|---|---|
| [opsapi-content](opsapi-content/SKILL.md) | Use OpsAPI as a headless CMS: show a workspace's blog posts and pages on any website, and write, publish and unpublish content in a workspace through the [MCP server](../mcp/README.md) or the REST API |

## Install

**Claude Code, for all your projects:**

```bash
mkdir -p ~/.claude/skills
curl -sL https://codeload.github.com/bwalia/opsapi/tar.gz/main \
  | tar -xz -C ~/.claude/skills --strip-components=2 opsapi-main/skills/opsapi-content
```

**Claude Code, for one website's repository** (the whole team gets it): run the same command with
`-C .claude/skills` from the repository root (after `mkdir -p .claude/skills`), and commit the folder.

**Claude apps (claude.ai, Desktop):** zip the `opsapi-content` folder and upload it under Settings →
Capabilities → Skills.

To update, run the install command again. Claude picks a skill up from its description, so just ask, e.g.
"show the blog posts from our OpsAPI workspace on this Next.js site" or "draft a post about our new opening hours
in OpsAPI".

## What else you need

- **To show content on a website:** the OpsAPI address and the workspace slug. Nothing secret.
- **To write content:** a key. In the OpsAPI dashboard: avatar menu → **My API keys** → **Create key** →
  **Website content**. For an AI agent, also add the OpsAPI MCP server ([mcp/README.md](../mcp/README.md)).
