import { request } from './parameters.js'

const related = (document, name) => {
  const included = new Map((document.included ?? []).map((resource) => [`${resource.type}/${resource.id}`, resource]))
  return (document.data.relationships?.[name]?.data ?? [])
    .map((ref) => included.get(`${ref.type}/${ref.id}`)?.attributes)
    .filter(Boolean)
}

/** The unit's ROS 2 node: `name`, `zenohEndpoint`, `connected`, its `topics` and its `services`. */
export async function fetchRos2Node() {
  const document = await request('ros2-node?include=topics,services')
  return { ...document.data.attributes, topics: related(document, 'topics'), services: related(document, 'services') }
}
