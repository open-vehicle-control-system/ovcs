/** A chart's series, flattened from its axes, each with the index of its axis. */
export const chartSeries = (block) =>
  block.yAxis.flatMap((axis, yAxisIndex) => axis.series.map(({ name, metric }) => ({ name, metric, yAxisIndex })))

function blockMetrics(block) {
  if (block.subtype === 'lineChart') return chartSeries(block).map(({ metric }) => metric)
  if (block.subtype !== 'table') return []
  return block.rows.flatMap((row) => {
    if (row.type === 'metric') return [{ module: row.module, key: row.key }]
    if (row.type === 'action' && row.statusMetricKey) return [{ module: row.module, key: row.statusMetricKey }]
    return []
  })
}

/** Every metric a page's blocks show, once each, in order of appearance. */
export function pageMetrics(blocks) {
  const metrics = new Map()
  for (const metric of blocks.flatMap(blockMetrics)) {
    const id = `${metric.module}/${metric.key}`
    if (!metrics.has(id)) metrics.set(id, { module: metric.module, key: metric.key })
  }
  return [...metrics.values()]
}
