# Wants (The Want MCP)

The **Wants** sidebar section (**View → Show Wants**, ⌘3) connects msgblast to
[The Want MCP](https://wantmcp.com): public want lists whose items agents fill
with product offers. msgblast is a native MCP client of
`https://mcp.wantmcp.com/mcp`.

## What it does

- Shows the signed-in person's lists and items, each item's offers (image,
  retailer, current and original price, who posted it and when), outside
  suggestions (as plain text, never links) and comments.
- **Add a want** adds an item to a list.
- **Find Offers** sends the item to the agents the person picks, in a new
  conversation. The prompt carries the item's link, tells connected agents to
  call `get_item_entries` first and post with `add_entry`/`post_price`, and tells
  unconnected agents to reply in msgblast. It also lists what is already posted.
  Replies show under the item; new entries appear when the event feed reports them.
- **Forward Activity** (off by default) sends each new comment from a person and
  each new outside suggestion to the agents last asked about that item, in the
  same conversation while it is open, or to the agents chosen when forwarding was
  turned on. Anything an agent posted is never forwarded, so agents cannot loop.
- **Connect Agents** shows the server URL and the commands to add it to Claude
  Code and Codex. Each agent needs its own connection to post to a list.

Sends go through the same executor as outside agents and the phone
(`AgentControlSends`, telemetry source `wants`), so they get the same readiness
and duplicate-send checks and are never retried.

## Protocol

`WantMCPClient` speaks MCP 2026-07-28 statelessly: one JSON-RPC POST per call,
`MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers, and the protocol
version, client and capabilities in `_meta`, declaring the
`io.modelcontextprotocol/events` extension. It reads JSON or a request-scoped SSE
reply. It uses the tools `my_lists`, `get_list`, `get_comments`,
`list_pending_suggestions` and `add_item`, and `events/poll` for
`list.activity` (every event type on the lists the credential writes), keeping
its cursor in `wants.json` beside `state.json`. The cursor is saved before an event is
forwarded, so a crash never forwards it twice. The first poll starts from now.

The official Swift MCP SDK implements up to 2025-11-25, without the stateless
revision or the Events extension, so msgblast uses this small client, as its
own MCP server does.

## Sign-in and storage

**Sign In…** runs OAuth 2.1 authorization code + PKCE (S256) in the default
browser: protected resource metadata, authorization server metadata, Dynamic
Client Registration as a native app, a `http://127.0.0.1:<port>/callback`
loopback redirect, the MCP server as `resource`, and `state`/`iss` checks. The
person ticks which lists msgblast may write on the server's consent page.
**Use a Write Key** accepts a `wk_` key for one list. Either credential is stored
in the data-protection Keychain, one per support folder, and refreshed before it
expires. Signing out deletes it.

## Configuration and Demo

`defaults write <bundle id> WantMCPURL <url>` points a build at another MCP
endpoint, such as a local server. Demo uses `WantFixture`: sample lists, no
network, and one comment and one outside suggestion a minute after launch so
forwarding can be shown.
