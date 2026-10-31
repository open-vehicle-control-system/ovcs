import { createContext, use, useEffect, useRef, useState } from 'react'
import { OvcsCard } from '@ovcs/ui/react'

const FrameSize = createContext(null)

/** The shown frame's natural `{ width, height }`, for an overlay drawn over it. */
export const useFrameSize = () => use(FrameSize)

/**
 * A stream's latest frame, with its resolution; `children` sit in the caption, under the stream's name, `onChannel`
 * gets the stream's channel, and `overlay` is drawn over the frame once its size is known (`useFrameSize`).
 */
export default function Preview({ stream, socket, onChannel, overlay, className = '', frameClassName = '', children }) {
  const [frame, setFrame] = useState(null)
  const [size, setSize] = useState(null)
  const frameRef = useRef(null)
  const channelRef = useRef(null)

  // The server sends the next frame only once this one is shown.
  const ack = () => channelRef.current?.push('ack', {})

  useEffect(() => {
    const channel = socket.channel(`preview:${stream}`, {})
    channelRef.current = channel
    // Each frame arrives as its JPEG bytes and is shown through an object URL, released once replaced.
    const show = (source) => {
      if (frameRef.current) URL.revokeObjectURL(frameRef.current)
      frameRef.current = source
      setFrame(source)
    }
    channel.on('frame', (jpeg) => show(URL.createObjectURL(new Blob([jpeg], { type: 'image/jpeg' }))))
    channel.join()
    onChannel?.(channel)
    return () => {
      channelRef.current = null
      onChannel?.(null)
      channel.leave()
      if (frameRef.current) URL.revokeObjectURL(frameRef.current)
      frameRef.current = null
    }
  }, [stream, socket, onChannel])

  return (
    <OvcsCard as="figure" className={`overflow-hidden p-0 ${className}`}>
      <div className={`relative flex aspect-video items-center justify-center bg-black ${frameClassName}`}>
        {frame ? (
          <img
            src={frame}
            alt={`${stream} preview`}
            width={size?.width}
            height={size?.height}
            className="h-full w-full object-contain"
            onLoad={(event) => {
              const { naturalWidth: width, naturalHeight: height } = event.currentTarget
              setSize((last) => (last?.width === width && last?.height === height ? last : { width, height }))
              ack()
            }}
            onError={ack}
          />
        ) : (
          <p className="text-sm text-ovcs-muted">No frame</p>
        )}
        {frame && size && overlay ? <FrameSize value={size}>{overlay}</FrameSize> : null}
      </div>
      <figcaption className="flex flex-col gap-1.5 px-3 py-2 text-sm">
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
    </OvcsCard>
  )
}
