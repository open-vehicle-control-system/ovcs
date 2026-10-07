import {
  Immutable,
  PanelExtensionContext,
  ParameterValue,
  SettingsTreeAction,
} from "@foxglove/extension";
import { ReactElement, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";

type Config = { node: string; prefix: string };

// The parameters this panel edits are scalars; anything else is shown
// as text and left alone.
type Scalar = boolean | number | string;

function scalar(value: unknown): Scalar | undefined {
  return typeof value === "boolean" || typeof value === "number" || typeof value === "string"
    ? value
    : undefined;
}

function text(value: Scalar | undefined): string {
  return value == undefined ? "" : String(value);
}

// rcl_interfaces/ParameterType
const BOOL = 1;
const INTEGER = 2;
const DOUBLE = 3;
const STRING = 4;

type Descriptor = {
  type: number;
  description: string;
  readOnly: boolean;
  range?: { low: number; high: number; step: number };
  values?: string[];
};

type RawDescriptor = {
  name: string;
  type: number;
  description: string;
  additional_constraints: string;
  read_only: boolean;
  floating_point_range: { from_value: number; to_value: number; step: number }[];
  integer_range: { from_value: number | bigint; to_value: number | bigint; step: number | bigint }[];
};

// While a slider moves, at most one set per this many milliseconds.
const SET_INTERVAL_MS = 150;

function toDescriptor(raw: RawDescriptor): Descriptor {
  const float = raw.floating_point_range[0];
  const integer = raw.integer_range[0];
  // RosBridge.Parameters lists a string's accepted values as "one of: a, b".
  const oneOf = /one of: (.*)$/.exec(raw.additional_constraints);

  return {
    type: raw.type,
    description: raw.description,
    readOnly: raw.read_only,
    range: float
      ? {
          low: float.from_value,
          high: float.to_value,
          step: float.step > 0 ? float.step : (float.to_value - float.from_value) / 200,
        }
      : integer
        ? {
            low: Number(integer.from_value),
            high: Number(integer.to_value),
            step: Number(integer.step) > 0 ? Number(integer.step) : 1,
          }
        : undefined,
    values: oneOf?.[1]?.split(", "),
  };
}

function parameterValue(type: number, value: Scalar): object {
  return {
    type,
    bool_value: type === BOOL ? Boolean(value) : false,
    integer_value: BigInt(type === INTEGER ? Math.round(Number(value)) : 0),
    double_value: type === DOUBLE ? Number(value) : 0,
    string_value: type === STRING ? text(value) : "",
    byte_array_value: [],
    bool_array_value: [],
    integer_array_value: [],
    double_array_value: [],
    string_array_value: [],
  };
}

function ParameterSlidersPanel({ context }: { context: PanelExtensionContext }): ReactElement {
  const [config, setConfig] = useState<Config>(() => ({
    node: "/ovcs_bridge_perception",
    prefix: "stereo.",
    ...(context.initialState as Partial<Config>),
  }));
  const [parameters, setParameters] = useState<Immutable<Map<string, ParameterValue>>>(new Map());
  const [descriptors, setDescriptors] = useState<Map<string, Descriptor>>(new Map());
  const [local, setLocal] = useState<Map<string, Scalar>>(new Map());
  const [errors, setErrors] = useState<Map<string, string>>(new Map());
  const [dark, setDark] = useState(true);
  const [renderDone, setRenderDone] = useState<(() => void) | undefined>();
  const lastSet = useRef<Map<string, number>>(new Map());
  const trailing = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());

  useLayoutEffect(() => {
    context.onRender = (renderState, done) => {
      setRenderDone(() => done);
      if (renderState.parameters) {setParameters(renderState.parameters);}
      setDark(renderState.colorScheme !== "light");
    };
    context.watch("parameters");
    context.watch("colorScheme");
  }, [context]);

  useEffect(() => {
    renderDone?.();
  }, [renderDone]);

  // Settings: which node, and which of its parameters.
  const settingsAction = useCallback((action: SettingsTreeAction) => {
    if (action.action === "update") {
      const key = action.payload.path[1] as keyof Config;
      setConfig((previous) => ({ ...previous, [key]: String(action.payload.value ?? "") }));
    }
  }, []);

  useEffect(() => {
    context.saveState(config);
    context.setDefaultPanelTitle(`${config.node} ${config.prefix}`);
    context.updatePanelSettingsEditor({
      actionHandler: settingsAction,
      nodes: {
        general: {
          label: "Parameters",
          fields: {
            node: { label: "Node", input: "string", value: config.node },
            prefix: { label: "Name prefix", input: "string", value: config.prefix },
          },
        },
      },
    });
    setDescriptors(new Map());
  }, [context, config, settingsAction]);

  // Names relative to the node, e.g. "stereo.left.lens_position".
  const names = useMemo(() => {
    const head = `${config.node}.`;
    return [...parameters.keys()]
      .filter((full) => full.startsWith(head + config.prefix))
      .map((full) => full.slice(head.length))
      .sort();
  }, [parameters, config]);

  const value = useCallback(
    (name: string): Scalar | undefined =>
      local.get(name) ?? scalar(parameters.get(`${config.node}.${name}`)),
    [local, parameters, config.node],
  );

  // Descriptions, fetched for names not described yet.
  useEffect(() => {
    const missing = names.filter((name) => !descriptors.has(name));
    if (missing.length === 0 || !context.callService) {return;}

    void context
      .callService(`${config.node}/describe_parameters`, { names: missing })
      .then((response) => {
        const raw = (response as { descriptors: RawDescriptor[] }).descriptors;
        setDescriptors((previous) => {
          const next = new Map(previous);
          raw.forEach((d, i) => next.set(missing[i]!, toDescriptor(d)));
          return next;
        });
      })
      .catch((error: unknown) => {
        setErrors((previous) => new Map(previous).set("*", `describe_parameters: ${String(error)}`));
      });
  }, [context, config.node, names, descriptors]);

  const send = useCallback(
    (name: string, type: number, next: Scalar) => {
      if (!context.callService) {return;}
      lastSet.current.set(name, Date.now());

      void context
        .callService(`${config.node}/set_parameters`, {
          parameters: [{ name, value: parameterValue(type, next) }],
        })
        .then((response) => {
          const result = (response as { results: { successful: boolean; reason: string }[] }).results[0];
          setErrors((previous) => {
            const errorsNext = new Map(previous);
            if (result?.successful === true) {errorsNext.delete(name);}
            else {errorsNext.set(name, result?.reason ?? "refused");}
            return errorsNext;
          });
          if (result?.successful !== true) {
            setLocal((previous) => {
              const kept = new Map(previous);
              kept.delete(name);
              return kept;
            });
          }
        })
        .catch((error: unknown) => { setErrors((previous) => new Map(previous).set(name, String(error))); });
    },
    [context, config.node],
  );

  // Shown at once; sent at most every SET_INTERVAL_MS, the last value always.
  const change = useCallback(
    (name: string, type: number, next: Scalar) => {
      setLocal((previous) => new Map(previous).set(name, next));
      clearTimeout(trailing.current.get(name));
      const wait = SET_INTERVAL_MS - (Date.now() - (lastSet.current.get(name) ?? 0));

      if (wait <= 0) {send(name, type, next);}
      else {trailing.current.set(name, setTimeout(() => { send(name, type, next); }, wait));}
    },
    [send],
  );

  const colours = dark
    ? { text: "#e7e7ea", muted: "#9a9aa3", line: "#3a3a42", error: "#ff7373", input: "#2a2a31" }
    : { text: "#1a1a1f", muted: "#6b6b73", line: "#dcdce0", error: "#c62828", input: "#f2f2f4" };

  const groups = new Map<string, string[]>();
  for (const name of names) {
    const rest = name.slice(config.prefix.length);
    const descriptor = descriptors.get(name);
    const group =
      descriptor?.readOnly === true
        ? "fixed at start"
        : rest.includes(".")
          ? rest.split(".")[0]!
          : "settings";
    groups.set(group, [...(groups.get(group) ?? []), name]);
  }
  const order = [...groups.keys()].sort((a, b) =>
    rank(a) !== rank(b) ? rank(a) - rank(b) : a.localeCompare(b),
  );

  return (
    <div style={{ padding: "0.5rem 0.75rem", color: colours.text, fontSize: 12, overflowY: "auto", height: "100%" }}>
      {names.length === 0 && (
        <p style={{ color: colours.muted }}>
          No parameters under {config.node} {config.prefix}. Set the node and prefix in the panel settings.
        </p>
      )}
      {errors.has("*") && <p style={{ color: colours.error }}>{errors.get("*")}</p>}
      {order.map((group) => (
        <section key={group} style={{ marginBottom: "0.75rem" }}>
          <h4 style={{ margin: "0.25rem 0", borderBottom: `1px solid ${colours.line}`, textTransform: "capitalize" }}>
            {group}
          </h4>
          {groups.get(group)!.map((name) => (
            <Control
              key={name}
              label={name.slice(config.prefix.length).replace(`${group}.`, "")}
              descriptor={descriptors.get(name)}
              value={value(name)}
              error={errors.get(name)}
              colours={colours}
              onChange={(type, next) => { change(name, type, next); }}
            />
          ))}
        </section>
      ))}
    </div>
  );
}

function rank(group: string): number {
  return group === "left" ? 0 : group === "right" ? 1 : group === "fixed at start" ? 3 : 2;
}

type Colours = { text: string; muted: string; line: string; error: string; input: string };

function Control(props: {
  label: string;
  descriptor: Descriptor | undefined;
  value: Scalar | undefined;
  error: string | undefined;
  colours: Colours;
  onChange: (type: number, value: Scalar) => void;
}): ReactElement {
  const { label, descriptor, value, error, colours, onChange } = props;
  const inputStyle = {
    background: colours.input,
    color: colours.text,
    border: `1px solid ${colours.line}`,
    borderRadius: 3,
    padding: "1px 4px",
  };

  let control: ReactElement;
  if (!descriptor) {
    control = <span style={{ color: colours.muted }}>{text(value)}</span>;
  } else if (descriptor.readOnly) {
    control = <span style={{ color: colours.muted }}>{text(value)}</span>;
  } else if (descriptor.type === BOOL) {
    control = (
      <input type="checkbox" checked={Boolean(value)} onChange={(e) => { onChange(BOOL, e.target.checked); }} />
    );
  } else if (descriptor.values) {
    control = (
      <select style={inputStyle} value={text(value)} onChange={(e) => { onChange(STRING, e.target.value); }}>
        {!descriptor.values.includes(text(value)) && <option value={text(value)}>{text(value)}</option>}
        {descriptor.values.map((option) => (
          <option key={option} value={option}>
            {option}
          </option>
        ))}
      </select>
    );
  } else if ((descriptor.type === DOUBLE || descriptor.type === INTEGER) && descriptor.range) {
    const { low, high, step } = descriptor.range;
    const number = Number(value ?? low);
    control = (
      <span style={{ display: "flex", gap: "0.5rem", alignItems: "center", flex: 1 }}>
        <input
          type="range"
          min={low}
          max={high}
          step={step}
          value={number}
          style={{ flex: 1 }}
          onChange={(e) => { onChange(descriptor.type, Number(e.target.value)); }}
        />
        <input
          type="number"
          min={low}
          max={high}
          step={step}
          value={descriptor.type === DOUBLE ? Number(number.toFixed(3)) : number}
          style={{ ...inputStyle, width: "5.5rem" }}
          onChange={(e) => {
            if (e.target.value !== "") {
              onChange(descriptor.type, Number(e.target.value));
            }
          }}
        />
      </span>
    );
  } else {
    control = (
      <input
        style={inputStyle}
        defaultValue={text(value)}
        onBlur={(e) => { onChange(descriptor.type, descriptor.type === STRING ? e.target.value : Number(e.target.value)); }
        }
      />
    );
  }

  return (
    <div style={{ margin: "0.3rem 0" }} title={descriptor?.description}>
      <div style={{ display: "flex", alignItems: "center", gap: "0.75rem" }}>
        <span style={{ width: "9.5rem", flexShrink: 0 }}>{label}</span>
        {control}
      </div>
      {error != undefined && <div style={{ color: colours.error, marginLeft: "10.25rem" }}>{error}</div>}
    </div>
  );
}

export function initParameterSlidersPanel(context: PanelExtensionContext): () => void {
  const root = createRoot(context.panelElement);
  root.render(<ParameterSlidersPanel context={context} />);
  return () => {
    root.unmount();
  };
}
