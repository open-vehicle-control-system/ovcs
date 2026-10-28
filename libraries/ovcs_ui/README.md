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
- `vue`: Vue 3 components over those classes. Importing it loads `tokens.css` and `components.css`. Vue is an optional peer dependency: the CSS works without it.

  | Component | Props | Content |
  |---|---|---|
  | `OvcsCard` | `href` (renders a link), `as` (element, default `div`) | default slot |
  | `OvcsHeader` | | default slot |
  | `OvcsStatus` | `tone`: `ok`, `warn`, `error`, `muted` (default) | label |
  | `OvcsBadge` | `tone`: `neutral` (default), `warn`, `error` | label |
  | `OvcsDot` | `on` | |
  | `OvcsRow` | `live`, `as` (element, default `div`) | default slot |

  Classes on a component (`<OvcsCard class="p-0">`) add to its own.

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

Or, in a Vue app (import `@ovcs/ui/vue` once in the entry script, before the app's own styles, so Tailwind utilities override the components):

```vue
<script setup>
import { OvcsBadge, OvcsStatus } from "@ovcs/ui/vue";
</script>

<template>
  <OvcsStatus tone="ok">Connected</OvcsStatus>
  <OvcsBadge tone="warn">stale</OvcsBadge>
</template>
```

A Vite app linking the package by path adds `resolve: { dedupe: ["vue"] }`, so the components use the app's Vue rather than the copy installed for this package's tests.

## Develop

```sh
npm install
npm run test:unit
```

In `tailwind.config.js`:

```js
import ovcsPreset from "@ovcs/ui/tailwind-preset";

export default { presets: [ovcsPreset] };
```
