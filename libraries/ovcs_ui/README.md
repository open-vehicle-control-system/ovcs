# @ovcs/ui

Design tokens, shared components and a Tailwind preset for OVCS web UIs. Plain CSS and JavaScript, no dependencies, usable with or without a framework.

- `tokens.css`: `--ovcs-*` custom properties, light by default, dark under `prefers-color-scheme: dark` or `[data-theme="dark"]` (`[data-theme="light"]` forces light).
- `components.css`: classes built on the tokens:

  | Class | Use |
  |---|---|
  | `ovcs-card` | bordered block on the surface colour; an `a.ovcs-card` highlights on hover |
  | `ovcs-header` | sticky top bar |
  | `ovcs-status` + `--ok` / `--warn` / `--error` | coloured dot followed by its label, muted without a modifier |
  | `ovcs-badge` + `--warn` / `--error` | short uppercase label |
  | `ovcs-dot` + `--on` | small accent dot marking a row |
  | `ovcs-row` + `--live` | row that lights up while `--live` is set and fades back after |

- `tailwind-preset.js`: maps the tokens to `ovcs-*` colors (`bg-ovcs-surface`, `text-ovcs-muted`, ...) and the sans and mono font families.

## Use

In the consumer's `package.json`:

```json
"@ovcs/ui": "file:../../ovcs_ui"
```

In its entry script:

```js
import "@ovcs/ui/tokens.css";
import "@ovcs/ui/components.css";
```

```html
<span class="ovcs-status ovcs-status--ok">Connected</span>
<span class="ovcs-badge ovcs-badge--warn">stale</span>
```

In `tailwind.config.js`:

```js
import ovcsPreset from "@ovcs/ui/tailwind-preset";

export default { presets: [ovcsPreset] };
```
