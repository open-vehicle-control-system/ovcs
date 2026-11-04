import { Component } from 'react'
import { focusClass as FOCUS } from '@ovcs/ui/react'

/** Keeps a block that fails to render inside its own card, with a Retry, rather than blanking the page. */
export default class BlockErrorBoundary extends Component {
  state = { error: null }

  static getDerivedStateFromError(error) {
    return { error }
  }

  render() {
    if (!this.state.error) return this.props.children

    return (
      <div role="alert" className="flex flex-wrap items-center gap-3 text-sm">
        <p className="ovcs-status ovcs-status--error min-w-0 break-words text-ovcs-error-text">
          This block could not be shown: {this.state.error.message}
        </p>
        <button
          type="button"
          onClick={() => this.setState({ error: null })}
          className={`min-h-7 rounded border border-ovcs-border px-2 text-xs hover:border-ovcs-accent ${FOCUS}`}
        >
          Retry
        </button>
      </div>
    )
  }
}
