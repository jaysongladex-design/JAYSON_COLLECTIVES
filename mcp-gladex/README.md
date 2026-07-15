# mcp-gladex

An MCP server that connects the **Gladex Supabase database** to Claude (Claude Code / Claude Desktop).
Node.js · [`@modelcontextprotocol/sdk`](https://github.com/modelcontextprotocol/typescript-sdk) · Supabase PostgREST REST API · stdio transport.

## Tools

| Tool | What it does |
| --- | --- |
| `search_bookings` | Search bookings by `gdx`, `lead_name`, or `destination` (partial, case-insensitive) |
| `get_booking` | One booking by GDX **+ its hotel / tour / ticket / transfer details** |
| `list_recent_bookings` | The 50 most recently synced bookings |
| `get_reviews` | List reviews, filterable by `is_hidden` and/or `destination` |
| `check_voucher` | Whether a GDX has an uploaded voucher (file name + URL) |
| `get_stats` | Total bookings, total reviews, pending (hidden) reviews, bookings without a voucher |

## 1. Prerequisites

**Node.js 18 or newer** (the server uses the built-in `fetch`). Check:

```bash
node --version
```

If it's missing or below 18, install the LTS from <https://nodejs.org>.

## 2. Install

```bash
cd "mcp-gladex"
npm install
```

Credentials live in `.env` (already created locally, and **gitignored — never commit it**):

```
SUPABASE_URL=https://YOUR-PROJECT.supabase.co
SUPABASE_ANON_KEY=your-anon-key-here
```

## 3. Add it to Claude Code

**Option A — one command (recommended).** Registers it for all your projects (`-s user`):

```bash
claude mcp add-json gladex -s user "{\"command\":\"node\",\"args\":[\"C:/Users/Windows 11Pro/Desktop/CLAUDE JAYSON PROJECT/mcp-gladex/server.js\"]}"
```

**Option B — edit the config by hand.** MCP servers live under `mcpServers` in your
Claude config (`~/.claude.json` for user scope, or a `.mcp.json` at a project root).
Add:

```json
{
  "mcpServers": {
    "gladex": {
      "command": "node",
      "args": ["C:/Users/Windows 11Pro/Desktop/CLAUDE JAYSON PROJECT/mcp-gladex/server.js"]
    }
  }
}
```

The server reads its credentials from `mcp-gladex/.env`, so **don't paste the URL or anon key
into this config** — that file is committed, `.env` isn't. Use forward slashes in the path
(Node accepts them on Windows and it avoids JSON backslash-escaping).

Then **restart Claude Code** and confirm with `/mcp` (you should see `gladex` connected and its 6 tools).

## 4. Run / test

**Quick connectivity check** (does the anon key reach the DB? — needs `curl`):

```bash
curl "$SUPABASE_URL/rest/v1/reviews?select=*&limit=1" \
  -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $SUPABASE_ANON_KEY"
```
*(substitute the values from your `.env` — don't paste them into anything you commit)*

**Run the server directly** (it speaks JSON-RPC over stdio, so it will print
`[mcp-gladex] ready …` to stderr and then wait for input — Ctrl+C to quit):

```bash
npm start          # = node server.js
```

**Interactive test with the MCP Inspector** (opens a UI to call each tool):

```bash
npm run inspect    # = npx @modelcontextprotocol/inspector node server.js
```

**In Claude Code**, once registered, just ask naturally — e.g.
*"search bookings for Boracay"*, *"get booking GDX-12345 with all details"*,
*"which bookings have no voucher?"*, *"show hidden reviews"*.

## Troubleshooting

- **Empty results / 401 / permission denied** — the anon key is limited by **Row Level
  Security**. Ensure your tables have an RLS policy granting `SELECT` to the `anon` role
  (or the data won't be readable with this key).
- **`gladex` not listed in `/mcp`** — check the `args` path is correct and absolute, and
  that `npm install` was run inside `mcp-gladex/`.
- **`fetch is not defined`** — you're on Node < 18; upgrade Node.
- The server links booking detail tables to a booking by matching `data->>gdx`. If your
  detail tables use a different link field, tell me and I'll adjust `get_booking`.
