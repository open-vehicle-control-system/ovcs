/** Cityscapes' own colours, by class name, in class id order (`VisionCore.Segmentation.labels/0`). */
export const CITYSCAPES = Object.freeze({
  road: [128, 64, 128],
  sidewalk: [244, 35, 232],
  building: [70, 70, 70],
  wall: [102, 102, 156],
  fence: [190, 153, 153],
  pole: [153, 153, 153],
  traffic_light: [250, 170, 30],
  traffic_sign: [220, 220, 0],
  vegetation: [107, 142, 35],
  terrain: [152, 251, 152],
  sky: [70, 130, 180],
  person: [220, 20, 60],
  rider: [255, 0, 0],
  car: [0, 0, 142],
  truck: [0, 0, 70],
  bus: [0, 60, 100],
  train: [0, 80, 100],
  motorcycle: [0, 0, 230],
  bicycle: [119, 11, 32]
})
const CITYSCAPES_ORDER = Object.values(CITYSCAPES)

const CLASS_ALPHA = Math.round(0.4 * 255)
const ROAD_ALPHA = Math.round(0.6 * 255)

const HEADER_BYTES = 16

/**
 * A `segmentation` event's binary payload: the camera frame's size, the band of it the grid covers, in its pixels,
 * the grid's size, its class ids row by row, and the ids present, in order. Throws on a payload shorter than its grid.
 */
export function decodeSegmentation(buffer) {
  const view = new DataView(buffer)
  const [frameWidth, frameHeight, x, y, width, height, gridWidth, gridHeight] = Array.from({ length: 8 }, (_, index) =>
    view.getUint16(index * 2, true)
  )
  const data = new Uint8Array(buffer, HEADER_BYTES, gridWidth * gridHeight)
  const inGrid = new Uint8Array(256)
  for (let index = 0; index < data.length; index++) inGrid[data[index]] = 1

  return {
    frame: { width: frameWidth, height: frameHeight },
    band: { x, y, width, height },
    grid: { width: gridWidth, height: gridHeight },
    data,
    present: Array.from(inGrid.keys()).filter((id) => inGrid[id] === 1)
  }
}

/** Class `id`'s name, colour and whether it is road, from the pipeline's `classes`; by its id until they come. */
export function classOf(id, classes) {
  const name = classes?.labels?.[id]
  return {
    id,
    name: name ?? `class ${id}`,
    colour: CITYSCAPES[name] ?? CITYSCAPES_ORDER[id % CITYSCAPES_ORDER.length],
    road: Boolean(name && classes.roadClasses?.includes(name))
  }
}

/** Each present class id's RGBA as one 32-bit word, in the byte order of an ImageData's little-endian view. */
export function paletteWords(present, classes) {
  const words = new Uint32Array(256)
  for (const id of present) {
    const { colour: [red, green, blue], road } = classOf(id, classes)
    words[id] = (((road ? ROAD_ALPHA : CLASS_ALPHA) << 24) | (blue << 16) | (green << 8) | red) >>> 0
  }
  return words
}
