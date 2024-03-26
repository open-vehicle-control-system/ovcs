<template>
  <div class="relative h-full w-full">
    <v-chart ref="gauge" class="chart absolute" :option="option" :id="props.id" />
    <div class="absolute bottom-52 left-44 text-gray-500 text-4xl">{{ unit }}</div>
    <div class="absolute bottom-0 left-2 w-full">
      <TorqueBar ref="torqueBar" :torque="torque"></TorqueBar>
    </div>
  </div>
</template>

<script setup>
  import { use } from 'echarts/core'
  import { GaugeChart } from 'echarts/charts'
  import VChart, { THEME_KEY } from "vue-echarts";
  import { CanvasRenderer } from 'echarts/renderers'
  import { ref, provide, } from "vue"
  import TorqueBar from "../gauges/TorqueBar.vue"

  const props = defineProps(["metrics", "id"])

  const gauge = ref("gauge")
  const torqueBar = ref("torqueBar")

  const metrics = props.metrics

  use([
    GaugeChart,
    CanvasRenderer
  ])

  provide(THEME_KEY, "light");

  let unit = "km/h";
  let torque = ref(0);

  const getTorque = function(store) {
    torque.value = store.metrics.filter((metric) => {
        return metric.id == "em57_effective_torque"
    })[0].attributes.value
  }

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
        roundCap: false,
        width: 24
      },
      pointer: {
        show: false,
      },
      axisLine: {
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
        show: false
      },
      splitLine: {
        show: false
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
            padding: [70, 0, 0, 0]
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
    if(speed && speed.attributes){
      serie = {
        ...serie,
        data: [
          { value: speed.attributes.value }
        ]
      }
      option.value.series = [serie]
    }

    getTorque(state)
    torqueBar.value.updateTorque(torque.value)
  })

  const option = ref({
    series: [serie]});

</script>

<style scoped>
  .chart {
    height: 400px;
  }
</style>