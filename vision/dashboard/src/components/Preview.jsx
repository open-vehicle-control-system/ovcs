import { Children, createContext, use, useEffect, useRef, useState } from 'react'
import { OvcsCard } from '@ovcs/ui/react'
import { LiveDecoder, hasVideoDecoder } from '../liveDecoder.js'

const FrameSize = createContext(null)

/** The shown frame's natural `{ width, height }`, for an overlay drawn over it. */
export const useFrameSize = () => use(FrameSize)

const NO_H264 = "This browser cannot decode the camera's H.264 video."

/** Why the browser has no video decoder: WebCodecs exists only in a secure context, HTTPS or `localhost`. */
const noVideoDecoder = () =>
  globalThis.isSecureContext === false
    ? 'This page is served over plain HTTP: the browser decodes video (WebCodecs) only over HTTPS.'
    : 'This browser has no video decoder (WebCodecs).'

/** An update of a `{ width, height }` state to `width` × `height`, the state kept when the size is the same. */
const sized = (width, height) => (last) => (last?.width === width && last?.height === height ? last : { width, height })

/**
 * The stream's latest JPEG on `preview:<stream>`, each shown through an object URL released once replaced, and acked
 * once shown: the server sends the next frame only then. `onChannel` gets the channel before it joins.
 */
function JpegFrame({ stream, socket, onChannel, size, onSize, onShown, alt }) {
  const [frame, setFrame] = useState(null)
  const frameRef = useRef(null)
  const channelRef = useRef(null)
  const ack = () => channelRef.current?.push('ack', {})

  useEffect(() => {
    const channel = socket.channel(`preview:${stream}`, {})
    channelRef.current = channel
    const show = (source) => {
      if (frameRef.current) URL.revokeObjectURL(frameRef.current)
      frameRef.current = source
      setFrame(source)
    }
    channel.on('frame', (jpeg) => show(URL.createObjectURL(new Blob([jpeg], { type: 'image/jpeg' }))))
    onChannel?.(channel)
    channel.join()
    return () => {
      channelRef.current = null
      onChannel?.(null)
      // A frame already on its way would otherwise get an object URL nothing releases.
      channel.off('frame')
      channel.leave()
      if (frameRef.current) URL.revokeObjectURL(frameRef.current)
      frameRef.current = null
    }
  }, [stream, socket, onChannel])

  useEffect(() => onShown(frame !== null), [frame, onShown])

  return frame ? (
    <img
      src={frame}
      alt={alt}
      width={size?.width}
      height={size?.height}
      className="h-full w-full object-contain"
      onLoad={(event) => {
        const { naturalWidth, naturalHeight } = event.currentTarget
        onSize(sized(naturalWidth, naturalHeight))
        ack()
      }}
      onError={ack}
    />
  ) : null
}

/**
 * The camera's video on `video:<stream>`, decoded with WebCodecs and drawn on a canvas (`LiveDecoder`), or a message
 * where the browser cannot decode it. `onDrawn` gets the capture time, in microseconds, of each frame drawn.
 */
function VideoFrame({ stream, socket, onSize, onShown, onDrawn }) {
  const canvasRef = useRef(null)
  const [unsupported, setUnsupported] = useState(false)

  useEffect(() => {
    const channel = socket.channel(`video:${stream}`, {})
    const live = new LiveDecoder(canvasRef.current, {
      onAck: () => channel.push('ack', {}),
      onDrawn: (captureUs, { width, height }) => {
        onSize(sized(width, height))
        onShown(true)
        onDrawn(captureUs)
      },
      onUnsupported: () => setUnsupported(true)
    })
    channel.on('frame', (payload) => live.push(payload))
    channel.join()
    return () => {
      channel.off('frame')
      channel.leave()
      live.close()
      onShown(false)
      onDrawn(null)
    }
  }, [stream, socket, onSize, onShown, onDrawn])

  return unsupported ? (
    <p className="px-4 text-center text-sm text-ovcs-muted">{NO_H264}</p>
  ) : (
    <canvas ref={canvasRef} aria-label={`${stream} video`} className="h-full w-full object-contain" />
  )
}

/**
 * A stream's latest frame, with its resolution; `children` sit in the caption, under the stream's name, and `aside`
 * in a part of its own after the caption, there and empty without one, so previews sharing a row's tracks keep their
 * frames level, or, `asideBeside`, next to the frame in its cell, the two kept together. The frame is 16:9 unless
 * `frameClassName` shapes it, from the image's size it carries once known (`--frame-width`, `--frame-height`), in a
 * cell of its own, `cellClassName`'s. With `video`, the stream is the camera's H.264 video, decoded with WebCodecs,
 * or a message where the browser cannot; otherwise its JPEG preview, whose channel `onChannel`
 * gets before it joins, to bind its own events. `overlay`, elements, none, or a function of the capture time in
 * microseconds of the frame shown (`null` for a JPEG preview, which shows the newest) that gives them, is drawn over
 * the frame once its size is known (`useFrameSize`), `badge` in the frame's corner and, with `alert`, a warning ring
 * around it, frame or not.
 */
export default function Preview({
  stream,
  socket,
  video = false,
  onChannel,
  overlay,
  badge,
  aside,
  alert = false,
  className = '',
  cellClassName = '',
  frameClassName = 'aspect-video',
  asideClassName = '',
  asideBeside = false,
  children
}) {
  const [size, setSize] = useState(null)
  const [shown, setShown] = useState(false)
  const [drawnUs, setDrawnUs] = useState(null)
  const decodable = !video || hasVideoDecoder()
  const overlays = typeof overlay === 'function' ? overlay(video ? drawnUs : null) : overlay

  const frame = video ? (
    <VideoFrame stream={stream} socket={socket} onSize={setSize} onShown={setShown} onDrawn={setDrawnUs} />
  ) : (
    <JpegFrame stream={stream} socket={socket} onChannel={onChannel} size={size} onSize={setSize} onShown={setShown} alt={`${stream} preview`} />
  )

  return (
    <OvcsCard as="figure" className={`overflow-hidden p-0 ${className}`}>
      <div
        className={cellClassName}
        style={size ? { '--frame-width': size.width, '--frame-height': size.height } : undefined}
      >
        <div data-frame className={`relative flex items-center justify-center bg-black ${frameClassName}`}>
          {decodable ? frame : <p className="px-4 text-center text-sm text-ovcs-muted">{noVideoDecoder()}</p>}
          {decodable && !shown && !video ? <p className="text-sm text-ovcs-muted">No frame</p> : null}
          {shown && size && Children.count(overlays) > 0 ? <FrameSize value={size}>{overlays}</FrameSize> : null}
          {alert ? <div data-alert className="pointer-events-none absolute inset-0 ring-2 ring-inset ring-ovcs-warn" /> : null}
          {badge ? <div className="absolute left-2 top-2 flex flex-wrap gap-1">{badge}</div> : null}
        </div>
        {asideBeside ? (
          <div data-aside data-beside className={`flex flex-col gap-1.5 text-sm ${asideClassName}`}>
            {aside}
          </div>
        ) : null}
      </div>
      <figcaption className="col-span-full flex flex-col gap-1.5 px-3 py-2 text-sm">
        <div className="flex items-baseline gap-2">
          <span className="font-medium capitalize text-ovcs-text">{stream}</span>
          {size ? (
            <span data-resolution className="text-xs text-ovcs-muted tabular-nums">
              {size.width} × {size.height}
            </span>
          ) : null}
        </div>
        {children}
      </figcaption>
      {asideBeside ? (
        <div data-aside-track aria-hidden="true" />
      ) : (
        <div data-aside className={`flex flex-col gap-1.5 px-3 pb-2 text-sm empty:p-0 ${asideClassName}`}>
          {aside}
        </div>
      )}
    </OvcsCard>
  )
}
