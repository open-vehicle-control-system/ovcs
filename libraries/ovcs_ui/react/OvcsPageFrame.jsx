import { classNames } from './styles.js'

/** A page's title and summary over its content, which scrolls on its own on a laptop. */
export default function OvcsPageFrame({ title, summary, className, children }) {
  return (
    <div className={classNames('flex min-w-0 flex-col gap-4 lg:min-h-0 lg:overflow-y-auto', className)}>
      <header>
        <h2 className="text-xl font-semibold">{title}</h2>
        {summary ? <p className="text-sm text-ovcs-muted">{summary}</p> : null}
      </header>
      {children}
    </div>
  )
}
