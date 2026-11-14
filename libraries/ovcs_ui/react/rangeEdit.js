import { useEffect, useRef, useState } from 'react'

const KEYS_THAT_STEP = new Set(['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End'])

/**
 * A range input's edit: a drag or a held key moves a `draft`, committed once, with `onCommit`, when the pointer is
 * released, wherever, or taken away, the key released or the focus gone; a value that changes outside one is committed
 * at once. `value` is the value in force, which a commit equal to it (`same`) leaves alone; `onEditStart` and
 * `onEditEnd` wrap a drag or a key press, ended too when the input is removed meanwhile, which commits nothing.
 * Answers the `draft`, `null` outside an edit, `change`, to call with each value the input takes, and the `handlers`
 * to spread on the input.
 */
export function useOvcsRangeEdit({ value, onCommit, onEditStart, onEditEnd, same = Object.is }) {
  const [draft, setDraft] = useState(null)
  const draftRef = useRef(null)
  const editing = useRef(false)
  const endEdit = useRef(onEditEnd)

  useEffect(() => {
    endEdit.current = onEditEnd
  })

  useEffect(
    () => () => {
      if (editing.current) endEdit.current?.()
    },
    []
  )

  const begin = () => {
    if (editing.current) return
    editing.current = true
    onEditStart?.()
  }

  const finish = () => {
    if (!editing.current) return
    editing.current = false
    const chosen = draftRef.current
    draftRef.current = null
    setDraft(null)
    if (chosen !== null && !same(chosen, value)) onCommit(chosen)
    onEditEnd?.()
  }

  const change = (next) => {
    if (!editing.current) {
      if (!same(next, value)) onCommit(next)
      return
    }
    draftRef.current = next
    setDraft(next)
  }

  return {
    draft,
    change,
    handlers: {
      onPointerDown: (event) => {
        event.currentTarget.setPointerCapture?.(event.pointerId)
        begin()
      },
      onPointerUp: finish,
      onPointerCancel: finish,
      onLostPointerCapture: finish,
      onKeyDown: (event) => {
        if (KEYS_THAT_STEP.has(event.key)) begin()
      },
      onKeyUp: finish,
      onBlur: finish
    }
  }
}
