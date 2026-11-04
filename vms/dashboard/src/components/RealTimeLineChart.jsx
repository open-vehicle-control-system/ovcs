import { useEffect, useRef } from 'react'
import { init, use } from 'echarts/core'
import { LineChart } from 'echarts/charts'
import { GridComponent, LegendComponent, TooltipComponent } from 'echarts/components'
import { CanvasRenderer } from 'echarts/renderers'
import { useOvcsTheme } from '@ovcs/ui/react'
import { chartSeries } from '../blocks.js'
import { appendPoint, chartOption, seedPoints, themeColors } from '../chart.js'
import { useMetrics } from '../stores/metrics.js'

use([LineChart, GridComponent, TooltipComponent, LegendComponent, CanvasRenderer])

/**
 * A line chart block: one point per series on each metrics push, drawn by ECharts outside React's renders.
 */
export default function RealTimeLineChart({ block, refreshInterval }) {
  const container = useRef(null)
  const chart = useRef(null)
  const buffers = useRef([])
  const theme = useOvcsTheme()

  useEffect(() => {
    const series = chartSeries(block)
    const now = Date.now()
    buffers.current = series.map(() => seedPoints(block.serieMaxSize, refreshInterval, now))
    const instance = init(container.current)
    chart.current = instance

    const unsubscribe = useMetrics.subscribe(({ data }) => {
      const time = Date.now()
      let appended = false
      series.forEach(({ metric }, index) => {
        const values = data[metric.module]
        if (values === undefined) return
        appendPoint(buffers.current[index], [time, values[metric.key] ?? null], block.serieMaxSize)
        appended = true
      })
      if (appended) instance.setOption({ series: buffers.current.map((points) => ({ data: points })) })
    })

    const observer = new ResizeObserver(() => instance.resize())
    observer.observe(container.current)

    return () => {
      unsubscribe()
      observer.disconnect()
      instance.dispose()
      chart.current = null
    }
  }, [block, refreshInterval])

  // Runs after the chart is created, and again with the theme's colours whenever it changes.
  useEffect(() => {
    chart.current?.setOption(chartOption(block, buffers.current, themeColors()))
  }, [block, refreshInterval, theme])

  return <div ref={container} className="h-[400px] w-full" />
}
