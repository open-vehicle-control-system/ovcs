import { OvcsCard } from '@ovcs/ui/react'
import PageFrame from './PageFrame.jsx'

const RESOURCES = [
  ['GET', 'stages?include=parameters', 'The pipeline stages and components, each with its role and parameters'],
  ['GET', 'parameters', 'Every parameter: value type, value, default, saved value, state and constraint'],
  ['GET', 'parameters/stereo.disparity.p1', 'One parameter'],
  ['PATCH', 'parameters/{id}', 'Changes a parameter, an unsaved change until saved'],
  ['POST', 'parameter-saves', 'Saves every unsaved change, so it outlives a reboot'],
  ['POST', 'parameter-discards', 'Drops every unsaved change'],
  ['POST', 'parameter-resets', 'Sets a parameter, a stage or everything back to its built-in value'],
  ['GET', 'composer-snippet', 'The saved values as a composer snippet'],
  ['GET', 'configuration', 'The active composer configuration'],
  ['GET', 'ros2-node?include=topics,services', 'The ROS 2 node: its Zenoh link, the topics published with their rates, the services answered']
]

const CHANNELS = [
  ['status', 'The unit status every second, as the top bar and the video captions show it'],
  ['preview:left, preview:right', 'Camera frames as binary JPEG messages; the client acks each frame to get the next'],
  ['preview:depth', 'The coloured depth map, as binary JPEG messages; push depth_range to read or set its colour range']
]

const base = () => `${import.meta.env.VITE_BASE_URL || window.location.origin}/api/`

/** How other programs reach the unit: its JSON:API resources and its live channels. */
export default function ApiPage() {
  return (
    <PageFrame title="API" summary="How other programs reach this unit, besides ROS 2.">
      <OvcsCard className="flex flex-col gap-3">
        <h3 className="font-semibold">Resources</h3>
        <p className="text-sm text-ovcs-muted">
          JSON:API at <code className="text-ovcs-text">{base()}</code>, media type{' '}
          <code className="text-ovcs-text">application/vnd.api+json</code>.
        </p>
        <table className="w-full text-left text-sm">
          <tbody className="divide-y divide-ovcs-border">
            {RESOURCES.map(([method, path, summary]) => (
              <tr key={`${method} ${path}`}>
                <td className="w-16 py-2 pr-3 font-mono text-xs font-semibold">{method}</td>
                <td className="py-2 pr-3 font-mono text-xs">
                  {method === 'GET' && !path.includes('{') ? (
                    <a href={base() + path} target="_blank" rel="noreferrer" className="text-ovcs-accent hover:underline">
                      /api/{path}
                    </a>
                  ) : (
                    `/api/${path}`
                  )}
                </td>
                <td className="py-2 text-ovcs-muted">{summary}</td>
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
    </PageFrame>
  )
}
