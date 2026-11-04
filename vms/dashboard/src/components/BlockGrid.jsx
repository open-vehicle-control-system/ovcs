import { useSyncExternalStore } from 'react'
import Block, { isRendered } from './Block.jsx'
import { blockLayout } from '../layout.js'

// Tailwind's `lg` breakpoint, where the page frame puts the menu beside the content.
const WIDE = '(min-width: 1024px)'

function subscribe(callback) {
  const query = window.matchMedia?.(WIDE)
  query?.addEventListener('change', callback)
  return () => query?.removeEventListener('change', callback)
}

const isWide = () => window.matchMedia?.(WIDE).matches ?? false

/** Three columns on a laptop, one on a narrow screen. */
const useColumnCount = () => (useSyncExternalStore(subscribe, isWide) ? 3 : 1)

/** A page's blocks in columns, a full-width block across them. */
export default function BlockGrid({ blocks, refreshInterval }) {
  const count = useColumnCount()
  const sections = blockLayout(blocks.filter(isRendered), count)

  return (
    <div className="flex flex-col gap-4">
      {sections.map((section) =>
        section.block ? (
          <Block key={section.block.id} block={section.block} refreshInterval={refreshInterval} />
        ) : (
          <div key={section.columns.flat()[0].id} className="grid grid-cols-1 items-start gap-4 lg:grid-cols-3">
            {section.columns.map((column, index) => (
              <div key={index} className="flex min-w-0 flex-col gap-4">
                {column.map((block) => (
                  <Block key={block.id} block={block} refreshInterval={refreshInterval} />
                ))}
              </div>
            ))}
          </div>
        )
      )}
    </div>
  )
}
