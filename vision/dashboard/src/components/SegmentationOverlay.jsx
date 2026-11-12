import { useLayoutEffect, useRef } from 'react'
import { useFrameSize } from './Preview.jsx'
import { classOf, paletteWords } from '../segmentation.js'

const shown = (name) => name.replaceAll('_', ' ')
const percent = (part, whole) => `${Math.round((part / whole) * 100_000) / 1000}%`

/** Draws `segmentation`'s grid on the canvas `ref` holds, a pixel a cell, reusing its image while the grid keeps its size. */
function useGridCanvas(segmentation, classes) {
  const canvasRef = useRef(null)
  const imageRef = useRef(null)

  useLayoutEffect(() => {
    const context = canvasRef.current?.getContext('2d')
    if (!context) return

    const { grid, data, present } = segmentation
    if (imageRef.current?.width !== grid.width || imageRef.current?.height !== grid.height) {
      imageRef.current = context.createImageData(grid.width, grid.height)
    }
    const image = imageRef.current
    const pixels = new Uint32Array(image.data.buffer, image.data.byteOffset, grid.width * grid.height)
    const words = paletteWords(present, classes)
    for (let index = 0; index < data.length; index++) pixels[index] = words[data[index]]
    context.putImageData(image, 0, 0)
  }, [segmentation, classes])

  return canvasRef
}

/**
 * A segmentation pipeline's label grid over a preview's frame, stretched over the band of the camera's image it
 * covers, each class in its Cityscapes colour at 40 % opacity and the classes the pipeline counts as road at 60 %.
 * Its box is the frame's own fitted inside the preview as the frame's `object-contain` image is, from the frame's
 * size and the preview's (container query units), and the band is placed in it by its fractions of the frame. It is
 * described by its class names, so hidden from assistive technology until they come.
 */
export default function SegmentationOverlay({ segmentation, classes }) {
  const { width, height } = useFrameSize()
  const canvasRef = useGridCanvas(segmentation, classes)
  const { frame, band, grid, present } = segmentation
  const description = classes ? `Segmented: ${present.map((id) => shown(classOf(id, classes).name)).join(', ')}` : undefined

  return (
    <div className="pointer-events-none absolute inset-0 [container-type:size]">
      <div
        data-segmentation
        role={description ? 'img' : undefined}
        aria-label={description}
        aria-hidden={description ? undefined : 'true'}
        style={{ '--frame-width': width, '--frame-height': height }}
        className="absolute inset-0 m-auto h-[min(100cqh,100cqw*var(--frame-height)/var(--frame-width))] w-[min(100cqw,100cqh*var(--frame-width)/var(--frame-height))]"
      >
        <canvas
          ref={canvasRef}
          width={grid.width}
          height={grid.height}
          className="absolute [image-rendering:pixelated]"
          style={{
            left: percent(band.x, frame.width),
            top: percent(band.y, frame.height),
            width: percent(band.width, frame.width),
            height: percent(band.height, frame.height)
          }}
        />
      </div>
    </div>
  )
}

/**
 * Every class a segmentation pipeline names, in class order, each with its colour, the road's in bold and those not
 * `present` muted, their colour dimmed, in a grid whose rows depend on the number of classes and the width alone, two
 * columns in the aside beside a preview's frame. Assistive technology hears the present classes alone, the road's said
 * so, and a name cut by its column shows in full on hover.
 */
export function SegmentationLegend({ name, classes, present }) {
  return (
    <ul aria-label={`${name} classes`} className="grid grid-cols-[repeat(auto-fill,minmax(5rem,1fr))] gap-x-3 gap-y-0.5 text-xs">
      {classes.labels.map((_, id) => {
        const item = classOf(id, classes)
        const isPresent = present.has(id)
        return (
          <li
            key={id}
            data-class={item.name}
            data-road={item.road ? '' : undefined}
            data-present={isPresent ? '' : undefined}
            aria-hidden={isPresent ? undefined : 'true'}
            className={`flex min-w-0 items-center gap-1 ${isPresent ? 'text-ovcs-text' : 'text-ovcs-muted'}`}
          >
            <span
              aria-hidden="true"
              className={`size-2.5 shrink-0 rounded-sm${isPresent ? '' : ' opacity-40'}`}
              style={{ backgroundColor: `rgb(${item.colour.join(' ')})` }}
            />
            <span data-name title={shown(item.name)} className={`truncate${item.road ? ' font-semibold' : ''}`}>
              {shown(item.name)}
            </span>
            {item.road ? <span className="sr-only"> (road)</span> : null}
          </li>
        )
      })}
    </ul>
  )
}
