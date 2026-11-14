import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { classNames } from './styles.js'

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

const PLACES = { start: 'items-start', center: 'items-center' }

// Tab and Shift+Tab go round the dialog's controls, and bring back into it a focus that left it.
function trapTab(event, dialog) {
  const controls = [...dialog.querySelectorAll(FOCUSABLE)]
  const first = controls[0] ?? dialog
  const last = controls.at(-1) ?? dialog
  const active = document.activeElement
  const outside = !dialog.contains(active)

  if (event.shiftKey ? outside || active === first || active === dialog : outside || active === last) {
    event.preventDefault()
    ;(event.shiftKey ? last : first).focus()
  }
}

/**
 * A modal dialog over the page, in the page's top layer: it keeps the focus, Tab going round its controls and the focus
 * coming back to it when the control that had it goes, Escape calls `onClose` where one is given, and the page behind
 * does not scroll. Once closed, the focus goes back to `returnFocus`'s element, by default the one focused when it
 * opened. Name it with `aria-labelledby`, its heading's id, or `aria-label`; `role` is `dialog` by default.
 * `align` places it at the `start` of the screen or at its `center`; `className` goes to the dialog itself.
 */
export default function OvcsDialog({ onClose, returnFocus, align = 'start', role = 'dialog', className, children, ...props }) {
  const dialog = useRef(null)
  const [opener] = useState(() => document.activeElement)

  // After each render: a control that went took the focus with it.
  useEffect(() => {
    if (!dialog.current.contains(document.activeElement)) dialog.current.focus()
  })

  useEffect(() => {
    const onKeyDown = (event) => {
      if (event.key === 'Escape' && onClose) onClose()
      else if (event.key === 'Tab') trapTab(event, dialog.current)
    }

    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [onClose])

  useEffect(() => {
    const overflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.body.style.overflow = overflow
    }
  }, [])

  // Read when it closes: the control named may have come back meanwhile.
  const returnFocusRef = useRef(returnFocus)
  returnFocusRef.current = returnFocus
  useEffect(
    () => () => {
      const target = returnFocusRef.current ? returnFocusRef.current.current : opener
      if (target?.isConnected) target.focus()
    },
    [opener]
  )

  return createPortal(
    <div
      className={`fixed inset-0 z-30 flex justify-center overflow-y-auto bg-black/60 p-4 [overscroll-behavior:contain] lg:p-8 ${PLACES[align]}`}
    >
      <div ref={dialog} role={role} aria-modal="true" tabIndex={-1} className={classNames('w-full outline-none', className)} {...props}>
        {children}
      </div>
    </div>,
    document.body
  )
}
