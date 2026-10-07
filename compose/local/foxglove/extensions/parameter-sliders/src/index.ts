import { ExtensionContext } from "@foxglove/extension";

import { initParameterSlidersPanel } from "./ParameterSlidersPanel";

export function activate(extensionContext: ExtensionContext): void {
  extensionContext.registerPanel({ name: "Parameter sliders", initPanel: initParameterSlidersPanel });
}
