import { useId, useState } from 'react'
import { OvcsCard, OvcsPageFrame, OvcsStatus } from '@ovcs/ui/react'
import Ros2Page from './Ros2Page.jsx'
import ApiPage from './ApiPage.jsx'
import { runExporterAction } from '../services/unit.js'
import { downloadFile } from '../services/download.js'
import { exporterStatus, useExporters } from '../stores/exporters.js'
import { useStatus } from '../stores/status.js'
import { BUTTON } from '../styles.js'

const OWN_PAGES = { ros2: Ros2Page, api: ApiPage }

const TONES = { ok: 'ok', warning: 'error', off: 'error' }

const OUTPUT_NAMES = {
  stereo_pair: 'Stereo pairs',
  'camera_frame:left': 'Left camera frames',
  'camera_frame:right': 'Right camera frames',
  camera_frame: 'Camera frames',
  detections: 'Detections',
  segmentation: 'Segmentation'
}

// `detections:road_signs` is the pipeline road_signs's detections, `camera_frame:center:inference` the camera center's output inference.
const outputName = (name) => {
  const [output, ...parts] = name.split(':')
  return OUTPUT_NAMES[name] ?? (parts.length > 0 && OUTPUT_NAMES[output] ? `${OUTPUT_NAMES[output]}: ${parts.join(', ')}` : name)
}

/** The exporter's actions, one button each; a file result is downloaded, a JSON result and an error are shown. */
function Actions({ exporterId, actions }) {
  const descriptionId = useId()
  const [running, setRunning] = useState(null)
  const [error, setError] = useState(null)
  const [result, setResult] = useState(null)

  const run = async (name) => {
    setRunning(name)
    setError(null)
    setResult(null)
    try {
      const answer = await runExporterAction(exporterId, name)
      if (answer.kind === 'file') downloadFile(answer.blob, answer.filename)
      else setResult(answer.data)
    } catch (failure) {
      setError(failure.message)
    } finally {
      setRunning(null)
    }
  }

  return (
    <OvcsCard className="flex flex-col gap-3">
      <h3 className="font-semibold">Actions</h3>
      <ul className="flex flex-col gap-3">
        {actions.map((action) => (
          <li key={action.name} className="flex flex-wrap items-center gap-x-4 gap-y-1">
            <button
              type="button"
              disabled={running !== null}
              aria-describedby={`${descriptionId}-${action.name}`}
              onClick={() => run(action.name)}
              className={BUTTON}
            >
              {running === action.name ? 'Running…' : action.label}
            </button>
            <p id={`${descriptionId}-${action.name}`} className="min-w-0 flex-1 text-sm text-ovcs-muted">
              {action.description}
            </p>
          </li>
        ))}
      </ul>
      {error ? <p role="alert" className="ovcs-status ovcs-status--error text-sm text-ovcs-error-text">{error}</p> : null}
      {result ? (
        <pre role="status" className="max-h-96 overflow-auto rounded border border-ovcs-border p-2 font-mono text-xs">
          {JSON.stringify(result, null, 2)}
        </pre>
      ) : null}
    </OvcsCard>
  )
}

/** An exporter without a page of its own: its status, its module, the outputs it reads with their rates, and its actions. */
function GenericExporterPage({ id }) {
  const exporter = useExporters((state) => state.exporters.find((listed) => listed.id === id))
  const status = useStatus((state) => (exporter ? exporterStatus(exporter, state.snapshot) : null))

  if (!exporter) {
    return (
      <OvcsPageFrame title="Exporter">
        <p className="text-sm text-ovcs-muted">The unit has not listed an exporter {id}.</p>
      </OvcsPageFrame>
    )
  }

  return (
    <OvcsPageFrame title={exporter.name} summary="What this exporter takes out of the unit.">
      <OvcsCard className="flex flex-wrap items-center gap-x-8 gap-y-2">
        {status ? (
          <div className="flex flex-col">
            <span className="text-xs text-ovcs-muted">status</span>
            <OvcsStatus tone={TONES[status.level]} className="font-semibold">
              {status.detail}
            </OvcsStatus>
          </div>
        ) : null}
        <div className="flex flex-col">
          <span className="text-xs text-ovcs-muted">module</span>
          <code className="font-semibold">{exporter.module}</code>
        </div>
      </OvcsCard>
      <OvcsCard className="flex flex-col gap-3">
        <h3 className="font-semibold">Outputs</h3>
        {exporter.outputs.length === 0 ? (
          <p className="text-sm text-ovcs-muted">It reads none of the unit&apos;s outputs.</p>
        ) : (
          <table className="w-full text-left text-sm">
            <thead className="text-xs text-ovcs-muted">
              <tr>
                <th scope="col" className="pb-2 pr-3 font-medium">output</th>
                <th scope="col" className="pb-2 font-medium">handed over</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-ovcs-border">
              {exporter.outputs.map((output) => (
                <tr key={output.name}>
                  <td className="py-2 pr-3">{outputName(output.name)}</td>
                  <td className="py-2 tabular-nums text-ovcs-muted">
                    {output.maxHz == null ? 'the newest, unbounded' : `at most ${output.maxHz} Hz`}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </OvcsCard>
      {exporter.actions?.length > 0 ? <Actions exporterId={id} actions={exporter.actions} /> : null}
    </OvcsPageFrame>
  )
}

/** The page of the exporter `id`: its own for ROS 2 and the API, the generic one for the others. */
export default function ExporterPage({ id }) {
  const Page = OWN_PAGES[id]
  return Page ? <Page /> : <GenericExporterPage key={id} id={id} />
}
