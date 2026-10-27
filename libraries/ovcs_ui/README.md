# @ovcs/ui

Design tokens and a Tailwind preset shared by OVCS web UIs. No dependencies.

- `tokens.css`: `--ovcs-*` custom properties, light by default, dark under `prefers-color-scheme: dark` or `[data-theme="dark"]` (`[data-theme="light"]` forces light).
- `tailwind-preset.js`: maps the tokens to `ovcs-*` colors (`bg-ovcs-surface`, `text-ovcs-muted`, ...) and the sans and mono font families.

## Use

In the consumer's `package.json`:

```json
"@ovcs/ui": "file:../../ovcs_ui"
```

In its entry script:

```js
import "@ovcs/ui/tokens.css";
```

In `tailwind.config.js`:

```js
import ovcsPreset from "@ovcs/ui/tailwind-preset";

export default { presets: [ovcsPreset] };
```
