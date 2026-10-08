import { ExtensionContext } from "@foxglove/extension";

// Foxglove's 3D panel does not draw sensor_msgs/Range. Converting each
// reading to a SceneUpdate draws it: the outline of a fan the width of
// the beam, cut at the distance, in the sensor's frame (x along the beam).

type Time = { sec: number; nanosec: number };

type Range = {
  header: { stamp: Time; frame_id: string };
  field_of_view: number;
  min_range: number;
  max_range: number;
  range: number;
};

type Colour = { r: number; g: number; b: number; a: number };

const ARC_SEGMENTS = 12;
// A sensor reports about ten times a second; a fan outlives a few misses.
const LIFETIME = { sec: 0, nsec: 500_000_000 };

// REP 117: +Inf is nothing in range, -Inf something closer than min_range.
function lengthAndColour(range: Range): [number, Colour] {
  if (range.range === Infinity || Number.isNaN(range.range)) {
    return [range.max_range, { r: 0.6, g: 0.6, b: 0.6, a: 0.3 }];
  }
  if (range.range === -Infinity || range.range < range.min_range) {
    return [range.min_range, { r: 1, g: 0, b: 0, a: 1 }];
  }
  // Red at 0 m to green at the maximum range.
  const t = Math.min(range.range / range.max_range, 1);
  return [range.range, { r: 1 - t, g: t, b: 0, a: 1 }];
}

export function fan(range: Range): unknown {
  const [length, color] = lengthAndColour(range);
  const half = range.field_of_view / 2;
  const apex = { x: 0, y: 0, z: 0 };

  const arc = Array.from({ length: ARC_SEGMENTS + 1 }, (_, i) => {
    const angle = -half + (i * range.field_of_view) / ARC_SEGMENTS;
    return { x: length * Math.cos(angle), y: length * Math.sin(angle), z: 0 };
  });

  return {
    deletions: [],
    entities: [
      {
        timestamp: { sec: range.header.stamp.sec, nsec: range.header.stamp.nanosec },
        frame_id: range.header.frame_id,
        id: range.header.frame_id,
        lifetime: LIFETIME,
        frame_locked: true,
        metadata: [],
        arrows: [],
        cubes: [],
        spheres: [],
        cylinders: [],
        lines: [
          {
            // LINE_STRIP
            type: 0,
            pose: { position: apex, orientation: { x: 0, y: 0, z: 0, w: 1 } },
            thickness: 0.008,
            scale_invariant: false,
            points: [apex, ...arc, apex],
            color,
            colors: [],
            indices: [],
          },
        ],
        triangles: [],
        texts: [],
        models: [],
      },
    ],
  };
}

export function activate(extensionContext: ExtensionContext): void {
  for (const schema of ["sensor_msgs/msg/Range", "sensor_msgs/Range"]) {
    extensionContext.registerMessageConverter({
      type: "schema",
      fromSchemaName: schema,
      toSchemaName: "foxglove.SceneUpdate",
      converter: (range: Range) => fan(range),
    });
  }
}
