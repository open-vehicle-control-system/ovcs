# @ovcs/ui

Design tokens, shared components and a Tailwind preset for OVCS web UIs. Plain CSS and JavaScript, no dependencies, usable with or without a framework.

- `tokens.css`: `--ovcs-*` custom properties, light by default, dark under `prefers-color-scheme: dark` or `[data-theme="dark"]` (`[data-theme="light"]` forces light). `--ovcs-ok-text`, `--ovcs-warn-text`, `--ovcs-error-text` and `--ovcs-accent-text` are the status and accent colours for text: darker in the light theme, where the plain ones fall below WCAG AA's contrast for text, and the plain ones in the dark theme.
- `components.css`: classes built on the tokens:

  | Class | Use |
  |---|---|
  | `ovcs-card` | bordered block on the surface colour; an `a.ovcs-card` highlights on hover |
  | `ovcs-header` | sticky top bar |
  | `ovcs-status` + `--ok` / `--warn` / `--error` | coloured dot followed by its label, muted without a modifier |
  | `ovcs-badge` + `--warn` / `--error` | short uppercase label |
  | `ovcs-dot` + `--on` | small accent dot marking a row |
  | `ovcs-row` + `--live` | row that lights up while `--live` is set and fades back after |

- `tailwind-preset.js`: maps the tokens to `ovcs-*` colors (`bg-ovcs-surface`, `text-ovcs-muted`, `text-ovcs-ok-text`, ...) and the sans and mono font families.
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

- `react`: React 19 components over the same classes, with the same names and props, `className` adding to the component's own classes and `children` as the content, and `ref` a plain prop. Importing it loads `tokens.css` and `components.css`. React is an optional peer dependency.

  | Component | Props |
  |---|---|
  | `OvcsCard`, `OvcsHeader`, `OvcsStatus`, `OvcsBadge`, `OvcsDot`, `OvcsRow` | as the Vue ones |
  | `OvcsParameterControl` | `parameter`, `bounds`, `controllerName`, `onChange`, `onReset`, `onEditStart`, `onEditEnd`: one parameter with its control, badge, description, allowed values, saved state and default |
  | `OvcsSaveBar` | `unsaved`, `error`, `onSave`, `onDiscard`, `onResetAll`, `onDismissError`, `className`, `ref`: the unsaved count with Save, Discard and Reset all |
  | `OvcsThemeSwitch` | the light / dark switch; the browser keeps the choice under `ovcs-theme` |

  The page frame the OVCS dashboards share: on a laptop the page is the screen and only the main content scrolls; on a narrow screen the menu stacks above it.

  | Component | Props |
  |---|---|
  | `OvcsShell` | holds an `OvcsTopBar` and an `OvcsShellBody` |
  | `OvcsTopBar` | the sticky top bar, holding an `OvcsTopBarTitle` and an `OvcsTopBarEnd` |
  | `OvcsTopBarTitle` | `product`: "OVCS" and the product's name, then its `children` |
  | `OvcsTopBarEnd` | the status and controls at the bar's end |
  | `OvcsShellBody` | holds an `OvcsMenu` and an `OvcsMain` |
  | `OvcsMenu` | `label`: the navigation, holding `OvcsMenuSection`s |
  | `OvcsMenuSection` | `title`, which names it |
  | `OvcsMenuList` | `label`: a list of `OvcsMenuItem`s, each in its `li` |
  | `OvcsMenuItem` | `selected`: a menu button, with the selection bar and `aria-current="page"` when selected |
  | `OvcsMain` | the main content |
  | `OvcsPageFrame` | `title`, `summary`: a page's heading over its content, which scrolls on its own on a laptop |

  It also exports `focusClass` (the focus ring utilities), `useOvcsTheme` (the current theme, `light` or `dark`) and the helpers `formatValue`, `rangeStep` and `tidy`. Most components use Tailwind utilities: add `../../libraries/ovcs_ui/react/**/*.{js,jsx}` (relative to the app) to its `content`. An app with `OvcsThemeSwitch` applies the stored choice before the first paint with an inline script in its `index.html`, as `vision/dashboard/index.html` does.

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

Or, in a React app (import `@ovcs/ui/react` once in the entry script, before the app's own styles, for the same reason):

```jsx
import { OvcsBadge, OvcsStatus } from "@ovcs/ui/react";

export const Health = () => (
  <>
    <OvcsStatus tone="ok">Connected</OvcsStatus>
    <OvcsBadge tone="warn">stale</OvcsBadge>
  </>
);
```

A Vite app linking the package by path adds `resolve: { dedupe: ["vue"] }` (`["react", "react-dom"]` for React), so the components use the app's copy rather than the copy installed for this package's tests.

## Develop

```sh
npm install
npm run test:unit
```

Vitest runs both halves in one jsdom environment with the Vue and React plugins; each transforms only its own file types.

In `tailwind.config.js`:

```js
import ovcsPreset from "@ovcs/ui/tailwind-preset";

export default { presets: [ovcsPreset] };
```
