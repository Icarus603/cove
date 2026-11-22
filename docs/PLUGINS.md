# Cove plugins

A plugin is a folder in `~/Library/Application Support/Cove/Plugins/` with a `manifest.json` and an executable.
Cove runs it, reads JSON lines from its stdout and draws them as a tab in the notch. Any language works.
Nothing runs until you switch the plugin on in **Settings → Modules → Plugins**.

```json
{ "id": "app.example.clock", "name": { "default": "Clock", "zh-Hant": "時鐘" },
  "symbol": "clock", "executable": "run.sh", "arguments": [], "order": 300 }
```

## Plugin → Cove (one JSON object per line on stdout)

| `type` | fields | effect |
|---|---|---|
| `render` | `root`: a view (below) | replaces the tab's content |
| `attention` | `level`: `none` / `active` / `needsInput` | `needsInput` opens the notch on this tab |
| `accessory` | `symbol` (SF Symbol), `text`? | badge next to the closed notch (empty `symbol` removes it) |
| `ready` | | optional |

Views: `vstack` / `hstack` (`children`, `spacing`), `text` (`text`, `style`: title/body/caption/mono, `color`),
`symbol` (`name`, `size`, `color`), `button` (`id`, `title`, `symbol`?), `progress` (`value` 0…1, `label`?), `spacer`, `divider`.
Colors: primary, secondary, red, green, yellow, blue, orange, pink.

## Cove → plugin (one JSON object per line on stdin)

`{"type":"hello","protocol":1,"locale":"zh-Hant"}` once at start · `{"type":"activate"}` / `{"type":"deactivate"}` when the tab
is shown / left · `{"type":"action","id":"…"}` when a button is pressed.

Limits: lines up to 256 KB, view trees up to 24 levels deep. A plugin that exits is restarted up to 5 times.
It runs with your user permissions in its own folder and a minimal environment (`NOTCH_PLUGIN_ID`, `NOTCH_PLUGIN_DIR`).
