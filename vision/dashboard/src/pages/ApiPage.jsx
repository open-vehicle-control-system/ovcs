import { OvcsCard, OvcsPageFrame } from '@ovcs/ui/react'
import { orderedGroups, useParameters } from '../stores/parameters.js'

// One parameter's path is shown, and linked, with the first of the unit's parameters once they are loaded.
const resources = (parameterId) => [
  ['GET', 'stages?include=parameters', "The pipelines' steps, each with its pipeline, role, explanation and parameters, and where it runs"],
  ['GET', 'parameters', 'Every parameter: value type, value, default, saved value, state and constraint'],
  ['GET', `parameters/${parameterId ?? '{id}'}`, 'One parameter'],
  ['PATCH', 'parameters/{id}', 'Changes a parameter, an unsaved change until saved'],
  ['POST', 'parameter-saves', 'Saves every unsaved change, so it outlives a reboot'],
  ['POST', 'parameter-discards', 'Drops every unsaved change'],
  ['POST', 'parameter-resets', 'Sets a parameter, a stage or everything back to its built-in value'],
  ['GET', 'depth-preview', "The depth video's colour range, the distance coloured blue"],
  ['PATCH', 'depth-preview', "Sets the depth video's colour range, for every dashboard, until the next boot"],
  ['GET', 'calibrations', 'The calibration in use of the stereo pair and of each camera of its own'],
  ['GET', 'calibrations/{id}', 'One of them'],
  ['POST', 'calibration-sessions', 'Starts calibrating one of them from views of a chessboard; solves, applies, cancels and resets are created the same way'],
  ['GET', 'saved-calibrations?filter[calibration]={id}', 'The calibrations saved on the unit for one of them, the newest first'],
  ['PATCH', 'saved-calibrations/{id}', 'Renames a saved calibration, or puts it back in use'],
  ['DELETE', 'saved-calibrations/{id}', 'Deletes a saved calibration; the one in use once the unit is back on the built-in one'],
  ['GET', 'configuration', 'The active composer configuration'],
  ['GET', 'firmware', 'The firmware: the commit it is built from, its target and its Nerves system'],
  ['GET', 'board', 'The board: its clock, its processor and memory load, and its network interfaces'],
  ['GET', 'exporters', 'What takes the outputs out of the unit: each exporter with the outputs it reads and its actions, this API last'],
  ['POST', 'exporters/{id}/actions/{name}', "Runs an exporter's action: answers the file it makes, or its result"],
  ['GET', 'ros2-node?include=topics,services', 'The ROS 2 node: its Zenoh link, the topics published with their rates, the services answered; 404 without the ROS 2 link'],
  ['GET', 'recordings?include=parts', "The bag exporter's recordings on the disks, each with its parts and the disk each part is on"],
  ['POST', 'recordings', 'Starts a recording of a preset on a clock'],
  ['PATCH', 'recordings/{id}', 'Stops a recording: its state changed to stopped'],
  ['DELETE', 'recordings/{id}', 'Deletes a recording, every part of it'],
  ['GET', 'recordings/{id}/download', 'A recording as one tar, each part a folder'],
  ['GET', 'disks', 'The disks recordings go on, in the order they are filled'],
  ['PATCH', 'disks/{id}', 'Moves a disk in the order, or turns it off'],
  ['POST', 'disk-ejects', 'Unmounts a disk before it is pulled out; disk-formats are created the same way']
]

const CHANNELS = [
  ['status', 'The unit status every second, as the status bar and the video captions show it'],
  ['preview:<prefix>/left, preview:<prefix>/right', "The stereo pair's frames, under the stereo unit's prefix, stereo by default, as binary JPEG messages; the client acks each frame to get the next"],
  ['preview:<name>', "A camera of its own's frames, as the pair's; the exporter listing names each camera"],
  ['preview:<prefix>/depth', 'The coloured depth map, as binary JPEG messages; the depth_range event carries its colour range'],
  ['detections:<name>', "A detection pipeline's objects, with their label, score, distance and outline on the image it reads; the exporter listing names each pipeline, detection for a detector without a name"],
  ['segmentation:<name>', "A segmentation pipeline's class grid over its camera's image, as binary messages the client acks, and its class names"]
]

// On a narrow screen a resource's answer goes under its path, where a third column has no room.
const NARROW_ROW = 'max-sm:grid max-sm:grid-cols-[4rem_minmax(0,1fr)]'

const base = () => `${import.meta.env.VITE_BASE_URL || window.location.origin}/api/`

/** How other programs reach the unit: its JSON:API resources and its live channels. */
export default function ApiPage() {
  const parameterId = useParameters((state) => orderedGroups(state).flatMap((group) => group.parameterIds)[0])

  return (
    <OvcsPageFrame title="API" summary="How other programs reach this unit: its resources and its live channels.">
      <OvcsCard className="flex flex-col gap-3">
        <h3 className="font-semibold">Resources</h3>
        <p className="text-sm text-ovcs-muted">
          JSON:API at <code className="text-ovcs-text">{base()}</code>, media type{' '}
          <code className="text-ovcs-text">application/vnd.api+json</code>.
        </p>
        <table className="w-full text-left text-sm">
          <thead className="text-xs text-ovcs-muted">
            <tr className={NARROW_ROW}>
              <th scope="col" className="pb-2 pr-3 font-medium">method</th>
              <th scope="col" className="pb-2 pr-3 font-medium">path</th>
              <th scope="col" className="pb-2 font-medium max-sm:sr-only">answer</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-ovcs-border">
            {resources(parameterId).map(([method, path, summary]) => (
              <tr key={`${method} ${path}`} className={NARROW_ROW}>
                <td className="w-16 py-2 pr-3 font-mono text-xs font-semibold">{method}</td>
                <td className="py-2 pr-3 font-mono text-xs max-sm:break-all">
                  {method === 'GET' && !path.includes('{') ? (
                    <a href={base() + path} target="_blank" rel="noreferrer" className="text-ovcs-accent-text hover:underline">
                      /api/{path}
                    </a>
                  ) : (
                    `/api/${path}`
                  )}
                </td>
                <td className="py-2 text-ovcs-muted max-sm:col-start-2 max-sm:pt-0">{summary}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </OvcsCard>
      <OvcsCard className="flex flex-col gap-3">
        <h3 className="font-semibold">Live channels</h3>
        <p className="text-sm text-ovcs-muted">
          Phoenix channels on the socket <code className="text-ovcs-text">/sockets/dashboard</code>.
        </p>
        <table className="w-full text-left text-sm">
          <thead className="text-xs text-ovcs-muted">
            <tr>
              <th scope="col" className="pb-2 pr-3 font-medium">topic</th>
              <th scope="col" className="pb-2 font-medium">carries</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-ovcs-border">
            {CHANNELS.map(([topic, summary]) => (
              <tr key={topic}>
                <td className="py-2 pr-3 font-mono text-xs">{topic}</td>
                <td className="py-2 text-ovcs-muted">{summary}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </OvcsCard>
    </OvcsPageFrame>
  )
}
