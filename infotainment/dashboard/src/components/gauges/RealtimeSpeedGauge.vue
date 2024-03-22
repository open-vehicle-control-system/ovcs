<template>
    <v-chart ref="gauge" class="chart" :option="option" :id="props.id" />
</template>

<script setup>
  import { use } from 'echarts/core'
  import { GaugeChart } from 'echarts/charts'
  import VChart, { THEME_KEY } from "vue-echarts";
  import { CanvasRenderer } from 'echarts/renderers'
  import { ref, defineProps, provide, } from "vue"

  const props = defineProps(["metrics", "id"])

  const gauge = ref("gauge")

  const metrics = props.metrics

  use([
    GaugeChart,
    CanvasRenderer
  ])

  provide(THEME_KEY, "light");

  let serie = {
      type: 'gauge',
      startAngle: 180,
      endAngle: 0,
      min: 0,
      max: 240,
      splitNumber: 6,
      itemStyle: {
        color: '#4b19a7',
        shadowColor: 'rgba(75,25,167,0.45)',
        shadowBlur: 10,
        shadowOffsetX: 2,
        shadowOffsetY: 2
      },
      progress: {
        show: true,
        roundCap: true,
        width: 18
      },
      pointer: {
        icon: 'path://M2090.36389,615.30999 L2090.36389,615.30999 C2091.48372,615.30999 2092.40383,616.194028 2092.44859,617.312956 L2096.90698,728.755929 C2097.05155,732.369577 2094.2393,735.416212 2090.62566,735.56078 C2090.53845,735.564269 2090.45117,735.566014 2090.36389,735.566014 L2090.36389,735.566014 C2086.74736,735.566014 2083.81557,732.63423 2083.81557,729.017692 C2083.81557,728.930412 2083.81732,728.84314 2083.82081,728.755929 L2088.2792,617.312956 C2088.32396,616.194028 2089.24407,615.30999 2090.36389,615.30999 Z',
        length: '75%',
        width: 16,
        offsetCenter: [0, '5%']
      },
      axisLine: {
        roundCap: true,
        lineStyle: {
          width: 18
        }
      },
      axisTick: {
        show: false,
        splitNumber: 2,
        lineStyle: {
          width: 2,
          color: '#999'
        }
      },
      splitLine: {
        length: 2,
        lineStyle: {
          width: 2,
          color: '#999'
        }
      },
      axisLabel: {
        distance: 20,
        color: '#999',
        fontSize: 14
      },
      title: {
        show: false
      },
      detail: {
        width: '60%',
        lineHeight: 60,
        height: 60,
        borderRadius: 8,
        offsetCenter: [0, '35%'],
        valueAnimation: true,
        formatter: function (value) {
          return '{value|' + value.toFixed(0) + '}{unit|km/h}';
        },
        rich: {
          value: {
            fontSize: 80,
            fontWeight: 'bolder',
            color: '#eee',
            padding: [120, 0, 0, 0]
          },
          unit: {
            fontSize: 50,
            color: '#999',
            padding: [120, 0, -10, 10]
          }
        }
      },
      data: [
        {
          value: 0
        }
      ]
    }

  metrics.$subscribe((_mutation, state) => {
    let speed = state.metrics.find((metric) => metric.id === "speed")
    serie = {
      ...serie,
      data: [
        { value: speed.attributes.value }
      ]
    }
    option.value.series = [serie]
  })

  const option = ref({
    series: [serie]});

</script>

<style scoped>
  .chart {
    height: 400px;
  }
</style>