import { OvcsMenuContext, useMenuState } from './menu.js'
import { OvcsProductContext } from './product.js'
import { classNames } from './styles.js'

/**
 * The page's frame: an `OvcsTopBar`, an `OvcsShellBody` and an `OvcsBottomBar`. Its `product`, such as "Vision", is the
 * name the bars show. On a laptop the page is the screen and only the main content scrolls; on a narrow screen the page
 * scrolls as a whole. It holds the state of the menu the top bar's Menu button shows and hides.
 */
export default function OvcsShell({ product = null, className, children, ...props }) {
  const menu = useMenuState()
  return (
    <OvcsProductContext value={product}>
      <OvcsMenuContext value={menu}>
        <div className={classNames('flex min-h-screen flex-col lg:h-screen lg:overflow-hidden', className)} {...props}>
          {children}
        </div>
      </OvcsMenuContext>
    </OvcsProductContext>
  )
}

/** An `OvcsMenu` beside the `OvcsMain` on a laptop, over its top on a narrow screen. */
export function OvcsShellBody({ className, children, ...props }) {
  return (
    <div className={classNames('flex flex-1 flex-col lg:min-h-0 lg:flex-row', className)} {...props}>
      {children}
    </div>
  )
}

/** The main content, in the room the menu leaves. */
export function OvcsMain({ className, children, ...props }) {
  return (
    <main className={classNames('flex min-w-0 flex-1 flex-col p-4 lg:min-h-0 lg:p-6', className)} {...props}>
      {children}
    </main>
  )
}
