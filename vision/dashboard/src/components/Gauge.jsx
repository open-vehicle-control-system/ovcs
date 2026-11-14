/**
 * Where a value stands on a track, as a cursor at `position`, from 0 to 100, none while it is `null`. `zone` is the
 * part of the track, `[from, to]` in percent, where the value is wanted; `start` and `end` label the track's ends,
 * and `centre` marks its middle. The cursor is green, or the warning colour with the tone `error`.
 */
export default function Gauge({ position, zone, tone, start, end, centre = false }) {
  const [from, to] = zone

  return (
    <div data-gauge className="flex items-center gap-1 text-[10px] font-medium text-ovcs-muted">
      {start ? <span aria-hidden="true">{start}</span> : null}
      <div className="relative h-3 flex-1">
        <div className="absolute inset-x-0 top-1/2 h-1 -translate-y-1/2 rounded-full bg-ovcs-border" />
        <div
          style={{ left: `${from}%`, right: `${100 - to}%` }}
          className="absolute top-1/2 h-1 -translate-y-1/2 rounded-full bg-ovcs-ok opacity-40"
        />
        {centre ? <div className="absolute left-1/2 top-0 h-3 w-px bg-ovcs-muted" /> : null}
        {position == null ? null : (
          <div
            data-cursor
            style={{ left: `${position}%` }}
            className={`absolute top-1/2 size-3 -translate-x-1/2 -translate-y-1/2 rounded-full ring-2 ring-ovcs-surface ${
              tone === 'error' ? 'bg-ovcs-warn' : 'bg-ovcs-ok'
            }`}
          />
        )}
      </div>
      {end ? <span aria-hidden="true">{end}</span> : null}
    </div>
  )
}
