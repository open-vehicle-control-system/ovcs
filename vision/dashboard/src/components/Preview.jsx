import { useEffect, useRef, useState } from 'react'
import { OvcsCard } from '@ovcs/ui/react'

export default function Preview({ stream, socket }) {
  const [frame, setFrame] = useState(null)
  const frameRef = useRef(null)
  const channelRef = useRef(null)

  // The server sends the next frame only once this one is shown.
  const ack = () => channelRef.current?.push('ack', {})

  useEffect(() => {
    const channel = socket.channel(`preview:${stream}`, {})
    channelRef.current = channel
    channel.on('frame', ({ jpeg }) => {
      const source = `data:image/jpeg;base64,${jpeg}`
      // An unchanged src fires no load event.
      if (source === frameRef.current) ack()
      frameRef.current = source
      setFrame(source)
    })
    channel.join()
    return () => {
      channelRef.current = null
      channel.leave()
    }
  }, [stream, socket])

  return (
    <OvcsCard as="figure" className="overflow-hidden p-0">
      <div className="flex aspect-video items-center justify-center bg-black">
        {frame ? (
          <img
            src={frame}
            alt={`${stream} preview`}
            className="h-full w-full object-contain"
            onLoad={ack}
            onError={ack}
          />
        ) : (
          <p className="text-sm text-ovcs-muted">No frame</p>
        )}
      </div>
      <figcaption className="px-4 py-2 text-sm font-medium capitalize text-ovcs-text">{stream}</figcaption>
    </OvcsCard>
  )
}
