import { describe, expect, it } from 'vitest'
import { CITYSCAPES, classOf, decodeSegmentation, paletteWords } from '../segmentation.js'

// The 19 Cityscapes training classes, by class id, with their colours in cityscapesScripts' `labels.py`.
const TRAINING_CLASSES = [
  ['road', [128, 64, 128]],
  ['sidewalk', [244, 35, 232]],
  ['building', [70, 70, 70]],
  ['wall', [102, 102, 156]],
  ['fence', [190, 153, 153]],
  ['pole', [153, 153, 153]],
  ['traffic_light', [250, 170, 30]],
  ['traffic_sign', [220, 220, 0]],
  ['vegetation', [107, 142, 35]],
  ['terrain', [152, 251, 152]],
  ['sky', [70, 130, 180]],
  ['person', [220, 20, 60]],
  ['rider', [255, 0, 0]],
  ['car', [0, 0, 142]],
  ['truck', [0, 0, 70]],
  ['bus', [0, 60, 100]],
  ['train', [0, 80, 100]],
  ['motorcycle', [0, 0, 230]],
  ['bicycle', [119, 11, 32]]
]
const labels = TRAINING_CLASSES.map(([name]) => name)

describe('segmentation', () => {
  it('colours each Cityscapes class in its own colour, by name, in class id order', () => {
    expect(Object.entries(CITYSCAPES)).toEqual(TRAINING_CLASSES)
    TRAINING_CLASSES.forEach(([name, colour], id) => expect(classOf(id, { labels, roadClasses: [] })).toEqual({ id, name, colour, road: false }))
  })

  it("colours a class by its id's Cityscapes colour while it has no name the palette knows", () => {
    expect(classOf(13, null).colour).toEqual([0, 0, 142])
    expect(classOf(13, { labels: [...labels.slice(0, 13), 'van'], roadClasses: [] })).toMatchObject({ name: 'van', colour: [0, 0, 142] })
  })

  it('packs each present class as RGBA, the road classes at 60 % opacity and the others at 40 %', () => {
    const words = paletteWords([0, 13], { labels, roadClasses: ['road'] })

    expect([...new Uint8Array(words.buffer, 0, 4)]).toEqual([128, 64, 128, 153])
    expect([...new Uint8Array(words.buffer, 13 * 4, 4)]).toEqual([0, 0, 142, 102])
    expect(words[1]).toBe(0)
  })

  it("reads the frame's size, the band, the capture time and the grid", () => {
    const buffer = new ArrayBuffer(24 + 2)
    const view = new DataView(buffer)
    ;[4, 2, 0, 1, 4, 1, 2, 1].forEach((value, index) => view.setUint16(index * 2, value, true))
    view.setBigInt64(16, -1234567n, true)
    new Uint8Array(buffer, 24).set([0, 13])

    expect(decodeSegmentation(buffer)).toMatchObject({
      frame: { width: 4, height: 2 },
      band: { x: 0, y: 1, width: 4, height: 1 },
      grid: { width: 2, height: 1 },
      captureUs: -1234567,
      present: [0, 13]
    })
  })

  it('refuses a payload shorter than its grid', () => {
    expect(() => decodeSegmentation(new Uint8Array([4, 0, 2, 0]).buffer)).toThrow(RangeError)
  })
})
