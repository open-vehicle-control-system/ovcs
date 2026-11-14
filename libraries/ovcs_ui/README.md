# @ovcs/ui

Design tokens, shared components and a Tailwind preset for OVCS web UIs. Plain CSS and JavaScript, no dependencies, usable with or without a framework.

- `tokens.css`: `--ovcs-*` custom properties, light by default, dark under `prefers-color-scheme: dark` or `[data-theme="dark"]` (`[data-theme="light"]` forces light). `--ovcs-ok-text`, `--ovcs-warn-text`, `--ovcs-error-text` and `--ovcs-accent-text` are the status and accent colours for text: darker in the light theme, where the plain ones fall below WCAG AA's contrast for text, and the plain ones in the dark theme.
- `components.css`: classes built on the tokens:

  | Class | Use |
  |---|---|
  | `ovcs-card` | bordered block on the surface colour; an `a.ovcs-card` highlights on hover |
  | `ovcs-header` | sticky top bar |
  | `ovcs-footer` | bottom bar |
  | `ovcs-status` + `--ok` / `--warn` / `--error` | coloured dot followed by its label, muted without a modifier |
  | `ovcs-badge` + `--warn` / `--error` | short uppercase label |
  | `ovcs-dot` + `--on` | small accent dot marking a row |
  | `ovcs-row` + `--live` | row that lights up while `--live` is set and fades back after |

- `tailwind-preset.js`: maps the tokens to `ovcs-*` colors (`bg-ovcs-surface`, `text-ovcs-muted`, `text-ovcs-ok-text`, ...) and the sans and mono font families.
- `react`: React 19 components over those classes, `className` adding to the component's own classes (`<OvcsCard className="p-0">`), `children` as the content, and `ref` a plain prop. Importing it loads `tokens.css` and `components.css`. React is an optional peer dependency: the CSS works without it.

  | Component | Props |
  |---|---|
  | `OvcsCard` | `href` (renders a link), `as` (element, default `div`) |
  | `OvcsHeader` | |
  | `OvcsStatus` | `tone`: `ok`, `warn`, `error`, `muted` (default) |
  | `OvcsBadge` | `tone`: `neutral` (default), `warn`, `error` |
  | `OvcsButton` | `variant`: `default` or `primary` (the action a view leads to); an outlined button that never submits a form |
  | `OvcsSwitch` | `checked`, `label`, `onClick`: an on/off switch whose position is `checked` alone |
  | `OvcsDot` | `on` |
  | `OvcsRow` | `live`, `as` (element, default `div`) |
  | `OvcsParameterControl` | `parameter`, `bounds`, `controllerName`, `onChange`, `onReset`, `onEditStart`, `onEditEnd`: one parameter with its control, badge, description, allowed values, saved state and default |
  | `OvcsSaveBar` | `unsaved`, `error`, `onSave`, `onDiscard`, `onResetAll`, `onDismissError`, `className`, `ref`: the unsaved count with Save, Discard and Reset all |
  | `OvcsThemeSwitch` | the light / dark switch; the browser keeps the choice under `ovcs-theme` |

  The page frame the OVCS dashboards share: on a laptop the page is the screen and only the main content scrolls; on a narrow screen the menu stacks above it.

  | Component | Props |
  |---|---|
  | `OvcsShell` | `product`: holds an `OvcsTopBar`, an `OvcsShellBody` and an `OvcsBottomBar`, which name the product |
  | `OvcsTopBar` | `firmware`, `board`: the sticky top bar, the same on every dashboard: "OVCS" and the shell's product, its `children`, then at its end the Vehicle, the board's CPU, its Memory in use and its Clock in UTC, ticking, with `synchronized` or, as a warning, `not synchronized`, then a button that opens the rest, the board's interfaces, each name before its addresses, and its Load, and the firmware's Version (its commit) and System (its Nerves system, or target), and the `OvcsThemeSwitch`, last; it titles the browser tab `OVCS <product> · <vehicle>` |
  | `OvcsShellBody` | holds an `OvcsMenu` and an `OvcsMain` |
  | `OvcsMenu` | `label`: the navigation, holding `OvcsMenuSection`s |
  | `OvcsMenuSection` | `title`, which names it |
  | `OvcsMenuList` | `label`: a list of `OvcsMenuItem`s, each in its `li` |
  | `OvcsMenuItem` | `selected`: a menu button, with the selection bar and `aria-current="page"` when selected |
  | `OvcsMain` | the main content |
  | `OvcsBottomBar` | the list of statuses, each an `OvcsBottomBarItem`, spread evenly over its width and wrapping on a narrow screen; at the screen's foot on a laptop, the page's end on a narrow screen |
  | `OvcsBottomBarItem` | `label`: a status's label, saying what it is about, then its value |
  | `OvcsConnectionStatus` | `state`: `connecting`, `connected` or `disconnected`, as `useOvcsConnection(socket)` answers it for a Phoenix socket; `hint`: an element after the label. The bottom bar item for the live connection, labelled with the shell's product |
  | `OvcsPageFrame` | `title`, `summary`: a page's heading over its content, which scrolls on its own on a laptop |

  It also exports `useOvcsFirmware(fetchFirmware, readWhen)` (the firmware for the top bar, read again each time `readWhen` turns truthy, a failed read tried again on a back-off), `useOvcsBoard(fetchBoard, connected, intervalMs)` (the board for the top bar, as `GET /api/board` answers it, read `intervalMs`, 10 s by default, after the previous read ended, while `connected`, and `null` again once disconnected), `useOvcsRangeEdit` (a range input's edit: the value while it is dragged or a key is held, committed once on release, dropped when the control goes), `boardInterfaces`, `boardLoad` and `boardClock` (its interfaces, load and clock as the top bar shows them), `useOvcsProduct` (the shell's product), `useOvcsConnection` (a Phoenix socket's connection state), `firmwareFacts` (a firmware's labelled facts in the top bar), `focusClass` (the focus ring utilities), `useOvcsTheme` (the current theme, `light` or `dark`) and the helpers `formatValue`, `rangeStep` and `tidy`. Most components use Tailwind utilities: add this package's `react/**/*.{js,jsx}`, relative to the app, to its `content`. An app with `OvcsThemeSwitch` applies the stored choice before the first paint with an inline script in its `index.html`, as `vision/dashboard/index.html` does.

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

Or, in a React app (import `@ovcs/ui/react` once in the entry script, before the app's own styles, so Tailwind utilities override the components):

```jsx
import { OvcsBadge, OvcsStatus } from "@ovcs/ui/react";

export const Health = () => (
  <>
    <OvcsStatus tone="ok">Connected</OvcsStatus>
    <OvcsBadge tone="warn">stale</OvcsBadge>
  </>
);
```

A Vite app linking the package by path adds `resolve: { dedupe: ["react", "react-dom"] }`, so the components use the app's React rather than the copy installed for this package's tests.

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
