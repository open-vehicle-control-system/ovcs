import { Component } from 'react'
import { reloadPage } from '../services/page.js'
import { BUTTON } from '../styles.js'

/**
 * A part of the page, `name`, that fails alone: when what it holds throws while rendering, it says so with the
 * error's message and a button that reloads the page, and the other parts stay. It shows what it holds again once
 * `resetOn` changes, as when another page is opened.
 */
export default class Region extends Component {
  state = { error: null }

  static getDerivedStateFromError(error) {
    return { error }
  }

  componentDidUpdate(previous) {
    if (this.state.error && previous.resetOn !== this.props.resetOn) this.setState({ error: null })
  }

  render() {
    const { error } = this.state
    if (!error) return this.props.children

    return (
      <div role="alert" className="flex flex-wrap items-center gap-2 px-4 py-2 text-sm">
        <p className="ovcs-status ovcs-status--error min-w-0 break-words text-ovcs-error-text">
          {`${this.props.name} cannot be shown: ${error instanceof Error ? error.message : String(error)}`}
        </p>
        <button type="button" onClick={reloadPage} className={BUTTON}>
          Reload
        </button>
      </div>
    )
  }
}
