import { useId, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { focusClass as FOCUS } from '@ovcs/ui/react'

const WIDTH = 288
const GAP = 8

/**
 * An ⓘ that explains `hint` (`{ title, text }`) in a card on hover or focus. The card is drawn in the page's
 * top layer, so a card clipping its content does not cut it.
 */
export default function Hint({ hint }) {
  const id = useId()
  const anchor = useRef(null)
  const [open, setOpen] = useState(false)
  const [place, setPlace] = useState(null)

  useLayoutEffect(() => {
    if (!open || !anchor.current) return
    const box = anchor.current.getBoundingClientRect()
    const left = Math.min(Math.max(GAP, box.left + box.width / 2 - WIDTH / 2), window.innerWidth - WIDTH - GAP)
    const above = box.top > window.innerHeight / 2
    setPlace(above ? { left, bottom: window.innerHeight - box.top + GAP } : { left, top: box.bottom + GAP })
  }, [open])

  if (!hint) return null

  return (
    <>
      <button
        ref={anchor}
        type="button"
        aria-label={`About ${hint.title}`}
        aria-describedby={open ? id : undefined}
        onMouseEnter={() => setOpen(true)}
        onMouseLeave={() => setOpen(false)}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        onKeyDown={(event) => event.key === 'Escape' && setOpen(false)}
        className={`inline-flex size-4 shrink-0 items-center justify-center rounded-full text-ovcs-muted hover:text-ovcs-accent ${FOCUS}`}
      >
        <svg aria-hidden="true" viewBox="0 0 16 16" className="size-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
          <circle cx="8" cy="8" r="6.75" />
          <path d="M8 7.25v4" strokeLinecap="round" />
          <circle cx="8" cy="4.75" r="0.6" fill="currentColor" stroke="none" />
        </svg>
      </button>
      {open && place
        ? createPortal(
            <div
              id={id}
              role="tooltip"
              style={{ ...place, width: WIDTH }}
              className="pointer-events-none fixed z-50 rounded-lg border border-ovcs-border bg-ovcs-surface p-3 text-left shadow-lg"
            >
              <p className="text-sm font-semibold text-ovcs-text">{hint.title}</p>
              <p className="mt-1 text-xs leading-relaxed text-ovcs-muted">{hint.text}</p>
            </div>,
            document.body
          )
        : null}
    </>
  )
}
