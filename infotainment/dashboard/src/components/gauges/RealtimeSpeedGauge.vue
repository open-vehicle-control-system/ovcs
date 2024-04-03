<template>
  <div class="relative h-full w-full">
    <v-chart ref="gauge" class="chart absolute" :option="option" :id="props.id" />
    <div class="absolute bottom-8 left-44 text-gray-500 text-4xl">{{ unit }}</div>
  </div>
</template>

<script setup>
  import { use } from 'echarts/core'
  import { GaugeChart } from 'echarts/charts'
  import VChart, { THEME_KEY } from "vue-echarts";
  import { CanvasRenderer } from 'echarts/renderers'
  import { ref, provide, } from "vue"
  import { infotainmentSocket } from '../../services/socket_service.js'

  const props = defineProps(["id"])
  const refreshIntervalms = 1000

  const gauge = ref("gauge")
  const torqueBar = ref("torqueBar")
  let speed = ref(0)
  let unit = ref("km/h");

  let speedChannel = infotainmentSocket.channel("speed", {interval: refreshIntervalms})

  speedChannel.on("updated", payload => {
    speed.value = payload["speed"]
    unit.value  = payload["unit"]
    serie = {
      ...serie,
      data: [
        { value: speed.value }
      ]
    }
    option.value.series = [serie]
  })

  speedChannel.join()
    .receive("ok", () => {})

  use([
    GaugeChart,
    CanvasRenderer
  ])

  provide(THEME_KEY, "light");

  let serie = {
      type: 'gauge',
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
        roundCap: false,
        width: 24
      },
      pointer: {
        show: true,
      },
      axisLine: {
        show: true,
        roundCap: false,
        color: "#eee",
        lineStyle: {
          width: 24,
          color: [
            [1, 'rgb(55,65,81)']
          ]
        }
      },
      axisTick: {
        show: true
      },
      splitLine: {
        show: true
      },
      axisLabel: {
        show: false
      },
      title: {
        show: false
      },
      detail: {
        width: '60%',
        lineHeight: 40,
        height: 40,
        borderRadius: 8,
        offsetCenter: [0, '-50%'],
        valueAnimation: true,
        formatter: function (value) {
          return '{value|' + value.toFixed(0) + '}';
        },
        rich: {
          value: {
            fontSize: 100,
            fontWeight: 'bolder',
            color: '#eee',
            padding: [440, 0, 0, 0]
          }
        }
      },
      data: [
        {
          value: 0
        }
      ]
    }


  const option = ref({
    series: [serie]});

</script>

<style scoped>
  .chart {
    height: 400px;
  }
</style>