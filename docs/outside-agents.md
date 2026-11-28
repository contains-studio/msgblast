# Outside agents

Agents on this Mac, such as Claude Code and Codex, can use msgblast through the
`msgblast` command and its stdio MCP server (`msgblast mcp`). Grok Bot can use the
same tools over Tailscale; see [Grok Bot over Tailscale](grok-bot.md). Everything
is off until Settings → Outside agents → "Allow agents on this Mac" is on.
Switching it off again ends every open session at once: nothing new runs, even
if an approval prompt is answered afterwards, and a request that was running gets
no reply. A send already under way finishes, because stopping it halfway could
leave a message half sent.

## Connect your agents

The paths below are the installed app. Settings → Outside agents → Copy Setup
copies the command for the build you are running, which for a test build is that build's own path.

- **Claude Code and Codex:** Settings → Outside agents → **Add** next to each runs the command
  below for you, replacing any older msgblast entry. Restart the agent afterwards. By hand:
  `claude mcp add --scope user msgblast -- /Applications/msgblast.app/Contents/MacOS/msgblast mcp` or
  `codex mcp add msgblast -- /Applications/msgblast.app/Contents/MacOS/msgblast mcp`
- **Cursor and Gemini CLI:** Settings → Outside agents → Copy Setup → Cursor or Gemini CLI, then
  paste that JSON into the client's MCP config. It names the msgblast command and
  the `mcp` argument.
- **Claude Desktop:** add the same MCP server in Claude Desktop's developer
  settings. The comparison view is an MCP App and renders inline.
- **Grok Bot:** uses Tailscale, not this stdio command. If the macOS firewall is
  on, allow msgblast incoming connections. See [Grok Bot over Tailscale](grok-bot.md).
  The first time you switch on "Allow agents on this Mac" on a Mac signed in to
  Tailscale, "Allow agents on other devices" turns on too. Every agent there still
  needs its own key and your approval, and you can switch it off.

[integrations/agent-plugins/msgblast/](../integrations/agent-plugins/msgblast/README.md)
is a draft plugin for Codex and Claude Code. It is not published. `codex plugin add`
and `claude plugin install` install from a marketplace, not from this folder alone.

## Approval and levels

The first call from each agent name opens a prompt in msgblast. The person picks
one level or chooses Don't Allow, which msgblast remembers until it quits.

- **Read only:** see agents, comparisons and replies, including message text, and
  wait for new events. Nothing can be sent.
- **Full access:** everything above, plus the send tools. That includes Messages
  contacts, so a Full access agent can send iMessages to real people.

Settings lists each approved agent under Agents, with its level and a remove button.

msgblast knows an agent only by the name it gives. Any program running as you on
this Mac can run the `msgblast` command with an approved name, such as "Claude
Code", and get that name's level. Give Full access only if you trust what runs on
this Mac under your account, and remove names you no longer use.

## Tools

| Tool | Level | What it does |
| --- | --- | --- |
| `msgblast_status` | Read only | Version, permissions, busy agents |
| `msgblast_agents_list` | Read only | Agents and their ids |
| `msgblast_comparisons_list`, `msgblast_comparison_read` | Read only | Saved comparisons and their conversations |
| `msgblast_mentions` | Read only | Comparisons as links for @-mentions |
| `msgblast_blast_wait` | Read only | Waits for replies, send results and busy changes |
| `msgblast_request_status` | Read only | The stored result of an earlier send call |
| `msgblast_blast_start` | Full access | One message to several agents, as a new comparison |
| `msgblast_blast_follow_up` | Full access | A follow-up in a comparison |
| `msgblast_agent_message` | Full access | A private message to one agent |
| `msgblast_agent_choose` | Full access | Taps one of an agent's suggestion buttons (Alexa Shopping's choices), listed as `actions` on its newest reply in `msgblast_comparison_read`; `actionsId` names that reply, so a choice is refused once a newer reply replaces it |
| `msgblast_comparison_end` | Full access | Ends a comparison |

## Comparison view and mentions

`msgblast_comparison_read` and `msgblast_blast_wait` open the side-by-side
comparison view in clients that support MCP Apps. The view only shows; it never
sends. In Codex and ChatGPT, @-mention a comparison: `msgblast_mentions` returns
`msgblast://comparison/<id>` links, and reading one runs `msgblast_comparison_read`.

## How sends behave

Send tools use the same command executor and send paths as the iPhone controller
(see [Remote control](remote-control.md)), so every check that guards a send from
the Mac or the phone applies:

- Nothing is retried. A send whose result is unclear stays unclear; check the
  comparison or `msgblast_request_status` before sending again.
- `requestId` makes a call safe to repeat while msgblast is running. The same
  agent name and `requestId` return the first result instead of sending again.
  msgblast remembers its last 1,000 sends and forgets them when it quits, so after
  a restart check the comparison before repeating. Without a `requestId`, each
  call is new. A refusal is remembered too, so use a new `requestId` to try again.
- Sends run one at a time. An agent's send waits for an earlier agent send to
  finish. While the Mac or the phone is sending, it is refused as busy instead.
- A locked Mac, an agent that isn't signed in or ready, or an ended comparison
  refuses the send. The error says why for each agent and names a code, such as
  `macLocked`, `macBusy` or `agentUnavailable`. Nothing is sent.
- Each agent name may call the send tools 6 times a minute and 60 times an hour.
  A repeat of a known `requestId` does not count.
- A result of `done` means msgblast submitted the message to each agent. Replies
  arrive later as `replyArrived` events from `msgblast_blast_wait`. A send tool's
  result has an `after` cursor taken just before the send; pass it to
  `msgblast_blast_wait` so a reply that came before the wait started isn't missed.
  A repeat of a known `requestId` leaves `after` out, because its replies may be
  older; wait with `after` 0 and the `comparisonId` to get what msgblast still holds.

The phone's "Send iMessages from the phone" setting does not apply to outside
agents; Full access is what allows Messages contacts.

## Seeing and stopping agent sends

While an agent's send runs, a banner above the agents says who is sending and
what (for example "Codex · Started a blast · 3 agents") and offers **Stop Agent
Sends**. The send already under way finishes, because stopping it halfway could
leave a message half sent; nothing new goes out after it, including sends that
were waiting their turn.

While sends are stopped, the banner says so and offers **Allow Agent Sends**.
Every new send call is refused, and the error names the code `agentSendsStopped`.
A stopped call isn't stored, so once sends are allowed again the same call, with
the same `requestId`, can be repeated. Agents can still read. The setting is
saved, so quitting msgblast doesn't turn sends back on.
Settings → Outside agents has the same switch, and Recent sends under it lists the last
agent sends since msgblast opened, with each one's result. The list never holds message text and
is not saved.

## The built-in msgblast agent

Ask it from the bar above the agents (✦ Message msgblast agent). Choose its account in
the bar's menu:

- **Claude Code:** the Claude Code installed on this Mac and its own login.
  **Sign in to Claude Code…** opens `claude auth login` in Terminal.
- **ChatGPT · Codex:** Codex with its own `codex login`.
- **ChatGPT plan:** Connect with ChatGPT in Settings. Codex uses that plan
  through msgblast, without `~/.codex/auth.json`.

The other agents answer in the grid. Collapsed, the bar shows what the agent is
doing and its newest reply, and a blast it starts opens its comparison. Expand it
(the arrows, or View → msgblast Agent, ⌘4) for the whole conversation in place of
the grid, like Messages: your messages on the right, the agent's on the left, and
steps such as "Sent to Codex CLI and Claude Code" as quiet lines between them. A
comparison it mentions shows as a card with its agents and reply count; tapping the
card, or an agent's name, collapses the conversation and opens that comparison. **Stop** ends the turn and
its session key; the next question resumes the same conversation with a new key.
Switching account starts a new conversation with that account's CLI. The
conversation is saved in `msgblast-agent.json` in the app support folder.

msgblast's own agent reaches the same tools through `msgblast mcp`, with a
session key instead of an approval. msgblast issues a key when a conversation
with the agent starts and revokes it when the conversation ends; the agent's
`msgblast mcp` reads it from `MSGBLAST_AGENT_SESSION_KEY` and adds it to every
request. msgblast keeps only each key's SHA-256 hash, in memory, so every key
ends when msgblast quits.

- A request with a live key acts as **msgblast agent** with Full access and no
  prompt. A key that isn't live is refused with `notApproved`, and nothing runs.
- No other caller may use the name msgblast agent, in any case or spacing, and
  Tailscale never accepts session keys.
- The agent only messages AI agents. `msgblast_agents_list` leaves out Messages
  contacts, the send tools refuse `messages:` and `featured:` ids, and a
  follow-up must list its agents, since one without them reaches every member.
- It works with Outside agents off. While a key is live the local socket
  listens, but answers only requests with a live key; when the last key is
  revoked it stops again. The Outside agents switch governs every other agent
  exactly as before.
- Its sends are like any agent's: they show in the banner and Recent sends as
  msgblast agent, Stop Agent Sends and the send limits apply, they run one at a
  time, a repeated `requestId` returns its first result, and nothing is retried.

## The built-in msgblast agent on Claude Code

The built-in msgblast agent can think with the Claude Code installed on this Mac
(`ClaudeAgentSession` in `msgblast/Core/ClaudeAgentSession.swift`). It uses Claude
Code's own sign-in and config folder, including `CLAUDE_CONFIG_DIR`; msgblast
never reads or copies Claude credentials. Sign in with `claude auth login`.
msgblast shows the same account status as for personal agents; an API-key
sign-in reads "API key connected · usage billed separately", because that usage
is billed outside a Claude plan.

Each conversation is one long-running `claude --print` process speaking
stream-json:

- **Tools:** only msgblast's MCP tools. `--tools ""` removes the built-in tools,
  `--strict-mcp-config` ignores every other MCP server, and
  `ENABLE_CLAUDEAI_MCP_SERVERS=false` turns off claude.ai connectors. Hooks,
  slash commands and the person's settings files are off. Allowed tools are
  `mcp__msgblast__*`, the permission mode is `dontAsk`, and anything that would
  ask for permission is denied, so nothing waits on a prompt. If Claude Code
  reports any other tool, or msgblast's tools didn't connect, msgblast stops the
  conversation before anything is sent.
- **Session key:** it is only in the `env` of the `msgblast` server in an
  owner-only (0600) temporary MCP config file, never in the command line. The
  file is deleted when the conversation closes.
- **Stop:** Stop uses Claude Code's stream-json interrupt. The turn ends and the
  conversation stays open; a tool call already under way may have finished.
- **Time limit:** a turn has no fixed limit. If Claude Code writes nothing for
  20 minutes, msgblast ends the process. The conversation is saved and resumes
  from its session id.
- **Close:** closing stops Claude Code's whole process group, including the
  `msgblast mcp` server it started.

It needs Claude Code 2.1.259 or later. Older versions get the same update message
as configured CLI conversations.

## The msgblast agent on Codex

The built-in msgblast agent can think with the person's Codex account.
`CodexAgentSession` in `msgblast/Core/CodexAgentSession.swift` runs the installed
`codex app-server` and speaks its JSON-RPC over stdio (protocol from
`codex app-server generate-json-schema`, codex-cli 0.172.0). It uses the existing
`codex login` unless the caller passes a managed `CODEX_HOME` and launch `-c`
overrides; with a managed home, `OPENAI_API_KEY` is removed from Codex's environment.

Each conversation is a Codex thread with:

- msgblast's MCP server as `mcp_servers.msgblast`, with its tools pre-approved.
  The session key goes in the JSON-RPC thread config, never in arguments, so it
  doesn't show in `ps`. Every other MCP server in the person's Codex config is turned off.
- No shell, file, image, web search, browser, computer use, subagent, app, plugin
  or hook tools, a read-only sandbox, and an approval policy that never prompts.
- An empty owner-only working folder, removed when the session closes.

If Codex asks to approve a tool, only tools on the `msgblast` server are approved;
other approvals, input requests and elicitations are declined. Turns have no time
limit, nothing is retried, and Stop uses the protocol's `turn/interrupt`. A
saved thread ID resumes the conversation with `thread/resume`. Closing the
session ends Codex's whole process group. A Codex without `app-server` gets a
message to update Codex.

`CodexAgentSessionTests` runs the real session against
`scripts/fixtures/codex_app_server.py`, a recorded app-server with no account or
network.
