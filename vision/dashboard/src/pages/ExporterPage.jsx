import { OvcsCard, OvcsPageFrame, OvcsStatus } from '@ovcs/ui/react'
import Ros2Page from './Ros2Page.jsx'
import ApiPage from './ApiPage.jsx'
import { exporterStatus, useExporters } from '../stores/exporters.js'
import { useStatus } from '../stores/status.js'

const OWN_PAGES = { ros2: Ros2Page, api: ApiPage }

const TONES = { ok: 'ok', warning: 'error', off: 'error' }

const OUTPUT_NAMES = {
  stereo_pair: 'Stereo pairs',
  'camera_frame:left': 'Left camera frames',
  'camera_frame:right': 'Right camera frames',
  detections: 'Detections'
}

/** An exporter without a page of its own: its status, its module, and the outputs it reads with their rates. */
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
        <div className="flex flex-col">
          <span className="text-xs text-ovcs-muted">status</span>
          <OvcsStatus tone={TONES[status.level]} className="font-semibold">
            {status.detail}
          </OvcsStatus>
        </div>
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
                  <td className="py-2 pr-3">{OUTPUT_NAMES[output.name] ?? output.name}</td>
                  <td className="py-2 tabular-nums text-ovcs-muted">
                    {output.maxHz == null ? 'the newest, unbounded' : `at most ${output.maxHz} Hz`}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </OvcsCard>
    </OvcsPageFrame>
  )
}

/** The page of the exporter `id`: its own for ROS 2 and the API, the generic one for the others. */
export default function ExporterPage({ id }) {
  const Page = OWN_PAGES[id]
  return Page ? <Page /> : <GenericExporterPage id={id} />
}
