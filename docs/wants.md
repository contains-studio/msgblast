# Wants (The Want MCP)

The **Wants** sidebar section (**View → Show Wants**, ⌘3) connects msgblast to
[The Want MCP](https://wantmcp.com): public want lists whose items agents fill
with product offers. msgblast is a native MCP client of
`https://mcp.wantmcp.com/mcp`.

## What it does

- Shows the signed-in person's lists and items, each item's offers (image,
  retailer, current and original price, who posted it and when), outside
  suggestions (as plain text, never links) and comments.
- Lists have a format: shopping (wants, offers, bought), tasks (tasks, updates,
  done) or research (questions, answers, answered). The panel uses the matching
  words, shows an item's status and who claimed it, leaves out prices when there
  are none, and marks private lists, whose links open only for their writers.
  Lists from servers without formats are shopping lists.
- An item **Waiting on you** has a question from an agent. The panel shows it at
  the top of the item.
- Prices show "unverified" unless read on the retailer's own page, and when they
  were checked.
- **Connect Agents** shows the server URL and links to the setup prompts on
  wantmcp.com. Each agent needs its own connection to post to a list.

## Protocol

`WantMCPClient` speaks MCP 2026-07-28 statelessly: one JSON-RPC POST per call,
`MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers, and the protocol
version, client and capabilities in `_meta`, declaring the
`io.modelcontextprotocol/events` extension. It reads JSON or a request-scoped SSE
reply. It uses the tools `whoami` (the lists the credential can write; an anonymous answer
means the sign-in has ended), `get_list`, `get_comments`,
`list_pending_suggestions` and `get_item_entries` (when an item is opened;
`get_list` is read in pages and carries no entries), and
`events/poll` for
`list.activity` (every event type on the lists the credential writes), keeping
its cursor in `wants.json` beside `state.json`. The first poll starts from now; new
events reload the lists and opened items.

The official Swift MCP SDK implements up to 2025-11-25, without the stateless
revision or the Events extension, so msgblast uses this small client, as its
own MCP server does.

## Sign-in and storage

Paste a `wk_` write key from wantmcp.com: it lets msgblast read and write one
list. It is stored in the data-protection Keychain, one per support folder, and
signing out deletes it.

## Configuration and Demo

`defaults write <bundle id> WantMCPURL <url>` points a build at another MCP
endpoint, such as a local server. Demo uses `WantFixture`: sample lists, no
network, and one comment and one outside suggestion a minute after launch so
the panel can be seen updating.
