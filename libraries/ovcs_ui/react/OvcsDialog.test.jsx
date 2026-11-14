import { useRef, useState } from 'react'
import { act, fireEvent, render, screen, within } from '@testing-library/react'
import { describe, expect, test, vi } from 'vitest'
import { OvcsDialog, useOvcsConfirm } from './index.js'

// A page with a button that opens a dialog of two fields, closed by Escape when `closable`.
function Page({ closable = true, returnToOther = false }) {
  const [open, setOpen] = useState(false)
  const other = useRef(null)
  return (
    <>
      <button type="button" onClick={() => setOpen(true)}>
        Open
      </button>
      <button ref={other} type="button">
        Other
      </button>
      {open ? (
        <OvcsDialog aria-labelledby="title" onClose={closable ? () => setOpen(false) : null} returnFocus={returnToOther ? other : undefined}>
          <h2 id="title">Settings</h2>
          <input aria-label="First" />
          <input aria-label="Last" />
          <button type="button" onClick={() => setOpen(false)}>
            Done
          </button>
        </OvcsDialog>
      ) : null}
    </>
  )
}

const open = () => {
  const opener = screen.getByRole('button', { name: 'Open' })
  opener.focus()
  fireEvent.click(opener)
  return screen.getByRole('dialog', { name: 'Settings' })
}

describe('OvcsDialog', () => {
  test('is a modal dialog labelled by its heading, which takes the focus when it opens', () => {
    render(<Page />)
    const dialog = open()

    expect(dialog.getAttribute('aria-modal')).toBe('true')
    expect(dialog.contains(document.activeElement)).toBe(true)
  })

  test('keeps Tab inside: from the last control to the first, back from the first to the last, and in from outside', () => {
    render(<Page />)
    const dialog = open()
    const first = within(dialog).getByLabelText('First')
    const done = within(dialog).getByRole('button', { name: 'Done' })

    done.focus()
    fireEvent.keyDown(done, { key: 'Tab' })
    expect(document.activeElement).toBe(first)

    fireEvent.keyDown(first, { key: 'Tab', shiftKey: true })
    expect(document.activeElement).toBe(done)

    screen.getByRole('button', { name: 'Other' }).focus()
    fireEvent.keyDown(document.activeElement, { key: 'Tab' })
    expect(document.activeElement).toBe(first)
  })

  test('closes on Escape from any of its controls, unless it cannot be closed', () => {
    const { unmount } = render(<Page />)
    within(open()).getByLabelText('Last').focus()
    fireEvent.keyDown(document.activeElement, { key: 'Escape' })
    expect(screen.queryByRole('dialog')).toBeNull()
    unmount()

    render(<Page closable={false} />)
    fireEvent.keyDown(open(), { key: 'Escape' })
    expect(screen.getByRole('dialog')).toBeTruthy()
  })

  test('gives the focus back to the control that opened it, or to the one named', () => {
    const { unmount } = render(<Page />)
    fireEvent.click(within(open()).getByRole('button', { name: 'Done' }))
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Open' }))
    unmount()

    render(<Page returnToOther />)
    fireEvent.keyDown(open(), { key: 'Escape' })
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Other' }))
  })

  test('stops the page behind from scrolling while open', () => {
    document.body.style.overflow = 'scroll'
    render(<Page />)

    open()
    expect(document.body.style.overflow).toBe('hidden')

    fireEvent.keyDown(document.activeElement, { key: 'Escape' })
    expect(document.body.style.overflow).toBe('scroll')
    document.body.style.overflow = ''
  })
})

// A button that asks before deleting, and says the answer.
function Asker({ question = { title: 'Delete "Bench"?', message: 'It cannot be undone.', confirmLabel: 'Delete', danger: true } }) {
  const [confirm, confirmation] = useOvcsConfirm()
  const [answer, setAnswer] = useState('none')
  return (
    <>
      <button type="button" onClick={async () => setAnswer(String(await confirm(question)))}>
        Ask
      </button>
      <p data-answer>{answer}</p>
      {confirmation}
    </>
  )
}

const ask = () => {
  const button = screen.getByRole('button', { name: 'Ask' })
  button.focus()
  fireEvent.click(button)
  return screen.getByRole('alertdialog', { name: 'Delete "Bench"?' })
}

const answer = () => document.querySelector('[data-answer]').textContent

describe('useOvcsConfirm', () => {
  test('shows nothing until it asks, then the question with Cancel and its own label, Cancel focused', () => {
    render(<Asker />)
    expect(screen.queryByRole('alertdialog')).toBeNull()

    const dialog = ask()
    expect(dialog.getAttribute('aria-modal')).toBe('true')
    expect(within(dialog).getByText('It cannot be undone.').id).toBe(dialog.getAttribute('aria-describedby'))
    expect(within(dialog).getAllByRole('button').map((button) => button.textContent)).toEqual(['Cancel', 'Delete'])
    expect(document.activeElement).toBe(within(dialog).getByRole('button', { name: 'Cancel' }))
  })

  test('draws a destructive action in the error colour, and another as the primary one', () => {
    const { unmount } = render(<Asker />)
    expect(within(ask()).getByRole('button', { name: 'Delete' }).className).toContain('text-ovcs-error-text')
    unmount()

    render(<Asker question={{ title: 'Delete "Bench"?', confirmLabel: 'Keep going' }} />)
    const keep = within(ask()).getByRole('button', { name: 'Keep going' })
    expect(keep.className).not.toContain('ovcs-error')
    expect(keep.className).toContain('font-semibold')
  })

  test.each([
    ['confirmed', (dialog) => fireEvent.click(within(dialog).getByRole('button', { name: 'Delete' })), 'true'],
    ['cancelled', (dialog) => fireEvent.click(within(dialog).getByRole('button', { name: 'Cancel' })), 'false'],
    ['left with Escape', (dialog) => fireEvent.keyDown(dialog, { key: 'Escape' }), 'false']
  ])('answers whether it was confirmed once %s, closes and gives the focus back', async (_how, respond, expected) => {
    render(<Asker />)
    const dialog = ask()

    await act(async () => respond(dialog))

    expect(answer()).toBe(expected)
    expect(screen.queryByRole('alertdialog')).toBeNull()
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Ask' }))
  })

  test('answers no when its component goes while it asks', async () => {
    let asked
    function Leaving() {
      const [confirm, confirmation] = useOvcsConfirm()
      return (
        <>
          <button type="button" onClick={() => (asked = confirm({ title: 'Delete "Bench"?', confirmLabel: 'Delete' }))}>
            Ask
          </button>
          {confirmation}
        </>
      )
    }
    const { unmount } = render(<Leaving />)
    fireEvent.click(screen.getByRole('button', { name: 'Ask' }))

    unmount()

    await expect(asked).resolves.toBe(false)
  })

  test('answers no to an earlier question when asked another', async () => {
    const answers = vi.fn()
    function Twice() {
      const [confirm, confirmation] = useOvcsConfirm()
      return (
        <>
          <button type="button" onClick={() => confirm({ title: 'First?', confirmLabel: 'Yes' }).then(answers)}>
            First
          </button>
          <button type="button" onClick={() => confirm({ title: 'Second?', confirmLabel: 'Yes' }).then(answers)}>
            Second
          </button>
          {confirmation}
        </>
      )
    }
    render(<Twice />)

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'First' })))
    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Second' })))

    expect(answers).toHaveBeenCalledWith(false)
    expect(screen.getByRole('alertdialog', { name: 'Second?' })).toBeTruthy()
  })
})
