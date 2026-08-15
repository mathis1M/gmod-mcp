# @mathis1m/gmod-mcp

Minimal test package containing only the MCP server. The bridge and GMod addon are intentionally not included yet, so tools return an unavailable status until the bridge is connected.

```json
{
  "mcpServers": {
    "gmod": {
      "command": "npx",
      "args": ["-y", "@mathis1m/gmod-mcp"]
    }
  }
}
```

Run locally with:

```bash
npx -y @mathis1m/gmod-mcp
```
