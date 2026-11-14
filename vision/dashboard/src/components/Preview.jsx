import { Children, createContext, use, useEffect, useRef, useState } from 'react'
import { OvcsCard, focusClass as FOCUS } from '@ovcs/ui/react'
import { LiveDecoder, hasVideoDecoder } from '../liveDecoder.js'

const FrameSize = createContext(null)

/** The shown frame's natural `{ width, height }`, for an overlay drawn over it. */
export const useFrameSize = () => use(FrameSize)

const NO_H264 = "This browser cannot decode the camera's H.264 video."
const NO_FRAME = 'No frame'
const NO_VIDEO = 'Waiting for video'

/** Follows a channel's join for `onNote`: why the unit refuses it, and nothing once it accepts it. */
const noteRefusal = (join, onNote) =>
  join.receive('ok', () => onNote(null)).receive('error', (reply) => onNote(`The unit refuses this stream: ${reply?.reason ?? 'no reason given'}`))

/** Why the browser has no video decoder: WebCodecs exists only in a secure context, HTTPS or `localhost`. */
const noVideoDecoder = () =>
  globalThis.isSecureContext === false
    ? 'This page is served over plain HTTP: the browser decodes video (WebCodecs) only over HTTPS.'
    : 'This browser has no video decoder (WebCodecs).'

/** An update of a `{ width, height }` state to `width` × `height`, the state kept when the size is the same. */
const sized = (width, height) => (last) => (last?.width === width && last?.height === height ? last : { width, height })

/**
 * The stream's latest JPEG on `preview:<stream>`, each shown through an object URL released once replaced, and acked
 * once shown: the server sends the next frame only then. `onChannel` gets the channel before it joins. A channel
 * that fails, as when the socket closes, has no frame until its next one.
 */
function JpegFrame({ stream, socket, onChannel, size, onSize, onShown, onNote, alt }) {
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
    channel.onError(() => show(null))
    onChannel?.(channel)
    noteRefusal(channel.join(), onNote)
    return () => {
      channelRef.current = null
      onChannel?.(null)
      // A frame already on its way would otherwise get an object URL nothing releases.
      channel.off('frame')
      channel.leave()
      if (frameRef.current) URL.revokeObjectURL(frameRef.current)
      frameRef.current = null
      onNote(null)
      onSize(null)
    }
  }, [stream, socket, onChannel, onNote, onSize])

  useEffect(() => {
    onShown(frame !== null)
    return () => onShown(false)
  }, [frame, onShown])

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
 * The camera's video on `video:<stream>`, decoded with WebCodecs and drawn on a canvas (`LiveDecoder`). `onDrawn`
 * gets the capture time, in microseconds, of each frame drawn, and `onNote` why none is, where the browser cannot
 * decode the stream. The canvas is hidden until a frame is drawn, and again once the channel fails, as when the
 * socket closes.
 */
function VideoFrame({ stream, socket, onSize, onShown, onDrawn, onNote }) {
  const canvasRef = useRef(null)
  const [drawn, setDrawn] = useState(false)

  useEffect(() => {
    const channel = socket.channel(`video:${stream}`, {})
    let left = false
    const leave = () => {
      if (left) return
      left = true
      channel.off('frame')
      channel.leave()
    }
    // Whether the channel failed and pushed nothing since: a frame decoded before is drawn after, and stays hidden.
    let failed = false
    const live = new LiveDecoder(canvasRef.current, {
      onAck: () => channel.push('ack', {}),
      onDrawn: (captureUs, { width, height }) => {
        if (failed) return
        onSize(sized(width, height))
        setDrawn(true)
        onShown(true)
        onDrawn(captureUs)
      },
      // Nothing takes the frames of a stream the browser cannot decode: the unit sends them no more.
      onUnsupported: () => {
        onNote(NO_H264)
        leave()
      }
    })
    const hide = () => {
      setDrawn(false)
      onShown(false)
      onDrawn(null)
    }
    channel.on('frame', (payload) => {
      failed = false
      live.push(payload)
    })
    channel.onError(() => {
      failed = true
      hide()
    })
    noteRefusal(channel.join(), onNote)
    return () => {
      leave()
      live.close()
      hide()
      onNote(null)
      onSize(null)
    }
  }, [stream, socket, onSize, onShown, onDrawn, onNote])

  return <canvas ref={canvasRef} aria-label={`${stream} video`} className={`h-full w-full object-contain ${drawn ? '' : 'invisible'}`} />
}

const EXPAND = 'M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5'
const SHRINK = 'M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5'

/** Whether `ref`'s element is the one shown full screen, and a toggle of it; `null` where the browser has none. */
function useFullScreen(ref) {
  const [full, setFull] = useState(false)

  useEffect(() => {
    const follow = () => setFull(document.fullscreenElement != null && document.fullscreenElement === ref.current)
    document.addEventListener('fullscreenchange', follow)
    return () => document.removeEventListener('fullscreenchange', follow)
  }, [ref])

  if (typeof Element.prototype.requestFullscreen !== 'function') return null
  return { full, toggle: () => (full ? document.exitFullscreen() : ref.current?.requestFullscreen())?.catch?.(() => {}) }
}

function FullScreenButton({ stream, full, toggle }) {
  const label = full ? 'Leave full screen' : `Show ${stream} full screen`

  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={toggle}
      className={`absolute right-2 top-2 flex size-7 items-center justify-center rounded bg-black/50 text-white opacity-70 hover:opacity-100 focus-visible:opacity-100 ${FOCUS}`}
    >
      <svg aria-hidden="true" viewBox="0 0 24 24" className="size-4" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path d={full ? SHRINK : EXPAND} />
      </svg>
    </button>
  )
}

/**
 * A stream's latest frame, with its resolution; `children` sit in the caption, under the stream's name, and `aside`
 * in a part of its own after the caption, there and empty without one, so previews sharing a row's tracks keep their
 * frames level, or, `asideBeside`, next to the frame in its cell, the two kept together. The frame is 16:9 unless
 * `frameClassName` shapes it, from the image's size it carries once known (`--frame-width`, `--frame-height`), in a
 * cell of its own, `cellClassName`'s. With `video`, the stream is the camera's H.264 video, decoded with WebCodecs;
 * otherwise its JPEG preview, whose channel `onChannel` gets before it joins, to bind its own events. A frame that
 * shows nothing says why: none came yet, or since its channel failed, the unit refuses the stream, or the browser
 * cannot decode the video. `overlay`, elements, none, or a function of the capture time in
 * microseconds of the frame shown (`null` for a JPEG preview, which shows the newest) that gives them, is drawn over
 * the frame once its size is known (`useFrameSize`), `badge` in the frame's corner and, with `alert`, a warning ring
 * around it, frame or not. A button in the frame's other corner shows it full screen, overlays included.
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
  // Why the frame shows nothing, where it is not only that none came yet.
  const [note, setNote] = useState(null)
  const frameRef = useRef(null)
  const fullScreen = useFullScreen(frameRef)
  const decodable = !video || hasVideoDecoder()
  const overlays = typeof overlay === 'function' ? overlay(video ? drawnUs : null) : overlay

  const frame = video ? (
    <VideoFrame stream={stream} socket={socket} onSize={setSize} onShown={setShown} onDrawn={setDrawnUs} onNote={setNote} />
  ) : (
    <JpegFrame stream={stream} socket={socket} onChannel={onChannel} size={size} onSize={setSize} onShown={setShown} onNote={setNote} alt={`${stream} preview`} />
  )

  return (
    <OvcsCard as="figure" className={`overflow-hidden p-0 ${className}`}>
      <div
        className={cellClassName}
        style={size ? { '--frame-width': size.width, '--frame-height': size.height } : undefined}
      >
        <div ref={frameRef} data-frame className={`relative flex items-center justify-center bg-black ${frameClassName}`}>
          {decodable ? frame : <p className="px-4 text-center text-sm text-ovcs-muted">{noVideoDecoder()}</p>}
          {decodable && !shown ? (
            <p className={`px-4 text-center text-sm text-ovcs-muted ${video ? 'absolute' : ''}`}>{note ?? (video ? NO_VIDEO : NO_FRAME)}</p>
          ) : null}
          {shown && size && Children.count(overlays) > 0 ? <FrameSize value={size}>{overlays}</FrameSize> : null}
          {alert ? <div data-alert className="pointer-events-none absolute inset-0 ring-2 ring-inset ring-ovcs-warn" /> : null}
          {badge ? <div className="absolute left-2 top-2 flex flex-wrap gap-1">{badge}</div> : null}
          {fullScreen ? <FullScreenButton stream={stream} {...fullScreen} /> : null}
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
