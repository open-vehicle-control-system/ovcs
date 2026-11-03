import { OvcsBadge, OvcsCard, OvcsDot, OvcsRow, OvcsStatus, focusClass } from '@ovcs/ui/react'
import { memo, useCallback, useState } from 'react'

import { dateTime, duration, formatValue, isFresh, isLive } from '../format'
import { nodeStatus, splitSource, staleCount } from '../signals'

const VALUE_TONES = { ok: 'text-ovcs-ok-text', muted: 'text-ovcs-muted', plain: '' }

// One grid for the header and every row: the name stacks over value and times on narrow screens.
const COLUMNS = 'grid grid-cols-[minmax(0,1fr)_auto] gap-x-4 sm:grid-cols-[minmax(0,1fr)_13rem_5rem_6.5rem]'

const HEADER = (
  <div
    className={`${COLUMNS} hidden border-b border-ovcs-border px-3 py-1.5 text-xs uppercase tracking-wide text-ovcs-muted sm:grid`}
  >
    <span>Signal</span>
    <span>Value</span>
    <span className="text-right">Changed</span>
    <span className="text-right">Published</span>
  </div>
)

/** The sources folded away, by node and source, so a source stays folded while a filter or a selection hides it. */
export function useCollapsed() {
  const [collapsed, setCollapsed] = useState(() => new Set())
  const toggle = useCallback((key) => {
    setCollapsed((current) => {
      const next = new Set(current)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }, [])
  return [collapsed, toggle]
}

// Memoised: between clock ticks, an update re-renders only the rows whose signal it replaced.
const SignalRow = memo(function SignalRow({ signal, now }) {
  const live = isLive(signal, now)
  const stale = signal.stale === true
  const value = formatValue(signal.value)
  const publishedClass = [stale && 'text-ovcs-warn-text', isFresh(signal, now) && 'opacity-50'].filter(Boolean).join(' ')

  return (
    <OvcsRow
      live={live}
      className={`${COLUMNS} items-baseline border-b border-ovcs-border px-3 py-1.5 text-sm last:border-b-0`}
    >
      <span className="col-span-2 flex min-w-0 items-center gap-2 sm:col-span-1">
        <OvcsDot on={live} />
        <span className="truncate" title={signal.name} translate="no">
          {signal.name}
        </span>
      </span>

      <span className="flex min-w-0 items-baseline gap-1 pl-3.5 sm:pl-0">
        <span
          className={`truncate font-mono ${stale ? 'text-ovcs-muted' : VALUE_TONES[value.tone]}`}
          title={value.text}
        >
          {value.text}
        </span>
        {signal.unit ? <span className="shrink-0 text-xs text-ovcs-muted">{signal.unit}</span> : null}
        {stale ? (
          <OvcsBadge tone="warn" className="shrink-0">
            stale
          </OvcsBadge>
        ) : null}
      </span>

      <span className="flex justify-end gap-3 text-right text-xs tabular-nums text-ovcs-muted sm:contents">
        <span title={`Changed ${dateTime(signal.changedAt)}`}>
          <span className="sm:hidden">changed </span>
          {duration(now - signal.changedAt)}
        </span>
        {signal.publishedAt != null ? (
          <span className={publishedClass} title={`Published ${dateTime(signal.publishedAt)}`}>
            <span className="sm:hidden">published </span>
            {duration(now - signal.publishedAt)}
          </span>
        ) : (
          <span title="This node's firmware does not report publications">—</span>
        )}
      </span>
    </OvcsRow>
  )
})

function SignalRows({ source, now }) {
  return source.signals.map((signal) => <SignalRow key={signal.name} signal={signal} now={now} />)
}

function FoldingSource({ source, open, onToggle, now }) {
  const { namespace, name } = splitSource(source.source)

  return (
    <>
      <button
        type="button"
        className={`flex w-full items-center gap-2 border-b border-ovcs-border bg-ovcs-bg px-3 py-1.5 text-left text-sm hover:bg-ovcs-surface ${focusClass}`}
        title={source.source}
        aria-expanded={open}
        onClick={onToggle}
      >
        <span aria-hidden="true" className="w-3 text-ovcs-muted">
          {open ? '▾' : '▸'}
        </span>
        <span className="min-w-0 truncate" translate="no">
          <span className="text-ovcs-muted">{namespace}</span>
          <span className="font-semibold">{name}</span>
        </span>
        <span className="ml-auto shrink-0 text-xs tabular-nums text-ovcs-muted">{source.signals.length}</span>
      </button>

      {open ? <SignalRows source={source} now={now} /> : null}
    </>
  )
}

/** A node's signals in one table, each source under a header that folds it away. */
export function NodeTable({ node, collapsed, onToggle, now }) {
  return (
    <OvcsCard className="overflow-hidden p-0">
      {HEADER}
      {node.sources.map((source) => {
        const key = `${node.node}/${source.source}`
        return (
          <FoldingSource
            key={source.source}
            source={source}
            open={!collapsed.has(key)}
            onToggle={() => onToggle(key)}
            now={now}
          />
        )
      })}
    </OvcsCard>
  )
}

/** One source's signals in a table of their own. */
export function SourceTable({ source, now }) {
  return (
    <OvcsCard className="overflow-hidden p-0">
      {HEADER}
      <SignalRows source={source} now={now} />
    </OvcsCard>
  )
}

function NodeSection({ node, collapsed, onToggle, now }) {
  const status = nodeStatus(node)
  const stale = staleCount(node)

  return (
    <section className="mb-8 last:mb-0">
      <header className="mb-2 flex flex-wrap items-baseline gap-x-4 gap-y-1">
        <h2 className="text-xl font-semibold" translate="no">
          {node.node}
        </h2>
        <OvcsStatus tone={status.tone} className="text-sm">
          {status.label}
        </OvcsStatus>
        {stale > 0 ? <span className="text-sm text-ovcs-warn-text">{stale} stale</span> : null}
      </header>
      <NodeTable node={node} collapsed={collapsed} onToggle={onToggle} now={now} />
    </section>
  )
}

/** A section per node publishing signals, its signals grouped by source. */
export default function SignalTree({ tree, collapsed, onToggle, now }) {
  return tree
    .filter((node) => node.sources.length > 0)
    .map((node) => <NodeSection key={node.node} node={node} collapsed={collapsed} onToggle={onToggle} now={now} />)
}
