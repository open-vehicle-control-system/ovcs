import { useConnection } from '../stores/connection.js'

/** Live values, dimmed under a notice while the dashboard is disconnected, as they are then the last ones received. */
export default function LiveContent({ children }) {
  const disconnected = useConnection((state) => state.state === 'disconnected')

  return (
    <>
      {disconnected ? (
        <p role="status" className="ovcs-status ovcs-status--error text-sm text-ovcs-error-text">
          Disconnected from the VMS: these are the last values received.
        </p>
      ) : null}
      <div className={`flex flex-col gap-4 transition-opacity ${disconnected ? 'opacity-50' : ''}`}>{children}</div>
    </>
  )
}
