# Wants (The Want MCP)

Open **View → Show Wants** (⌘3) to read the lists your key can write. On wantmcp.com, open a list's settings, choose **Agents › Add another agent**, then paste the `wk_` key into msgblast.

Shopping lists show offers, task lists show updates, and research lists show answers. Choose an item to see its entries, comments, status, and who claimed it. **Waiting on you** shows the agent's question. Outside suggestions appear as plain text. Prices show when they were checked and carry an **unverified** label unless the retailer's page confirmed them.

New lists start private. Their links open only for writers. **Connect Agents** provides the server URL and setup prompts for each agent that needs to post.

## Connection and storage

msgblast stores one write key per support folder in the data-protection Keychain. It restores the key only for the endpoint where you entered it. Re-enter keys saved by earlier builds without an endpoint. Signing out disables restoration and deletes the saved key.

The default endpoint is `https://mcp.wantmcp.com/mcp`. To use another server, set `defaults write <bundle id> WantMCPURL <url>`. Use HTTPS, or HTTP on localhost. Demo uses a local fixture and adds a comment and an outside suggestion after one minute.

## Protocol

`WantMCPClient` sends stateless MCP 2026-07-28 JSON-RPC requests and accepts JSON or request-scoped SSE replies. It declares the Events extension in `_meta`. `whoami` identifies writable lists. The panel reads list pages, comments, pending suggestions and the opened item's entry pages. It polls `list.activity` and stores its cursor in `wants.json` after refreshing the lists and opened items.
