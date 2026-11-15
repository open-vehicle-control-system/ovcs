import { useEffect, useId } from 'react'
import { OvcsPageFrame } from '@ovcs/ui/react'
import Recorder from '../components/recordings/Recorder.jsx'
import RecordingList from '../components/recordings/RecordingList.jsx'
import { useRecordings } from '../stores/recordings.js'

const POLL_MS = 1000
// Reading every recording reads each one's metadata from the disks: the list is read less often than the disks.
const LIST_EVERY_POLLS = 10

/** The bag exporter's page: the recorder beside the disks it records on, then the recordings. */
export default function Ros2BagPage() {
  const recordingsId = useId()
  const loadError = useRecordings((state) => state.loadError)
  const error = useRecordings((state) => state.error)

  // The next poll waits for the previous answer, so a slow one never overlaps it.
  useEffect(() => {
    let live = true
    let timer = null
    let polls = 0
    const poll = async () => {
      const { load, refresh } = useRecordings.getState()
      await (polls % LIST_EVERY_POLLS === 0 ? load() : refresh())
      polls += 1
      if (live) timer = setTimeout(poll, POLL_MS)
    }
    poll()
    return () => {
      live = false
      clearTimeout(timer)
    }
  }, [])

  return (
    <OvcsPageFrame title="ROS 2 · Bag" summary="Records what this unit publishes to ROS 2 as bags on its disks.">
      {loadError ? <p role="alert" className="ovcs-status ovcs-status--error text-sm text-ovcs-error-text">{loadError}</p> : null}
      {error ? <p role="alert" className="ovcs-status ovcs-status--error text-sm text-ovcs-error-text">{error}</p> : null}
      <Recorder />
      <RecordingList headingId={recordingsId} />
    </OvcsPageFrame>
  )
}
