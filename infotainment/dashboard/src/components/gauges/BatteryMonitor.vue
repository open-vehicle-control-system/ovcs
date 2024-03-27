<template>
    <div class="h-full w-full p-4 grid grid-cols-2">
        <v-chart ref="gauge" class="chart" :option="option" />
        <div class="grid grid-rows-3">
            <div class="p-2 ml-4">
                <IconBattery class="w-8 h8 inline-block"></IconBattery>
                <span class="text-gray-200 inline-block ml-4">-</span>
            </div>
            <div class="p-2 ml-5">
                <IconElectricity class="w-6 h6 inline-block"></IconElectricity>
                <span class="text-gray-200 inline-block ml-5">-</span>
            </div>
            <div class="p-2 ml-4">
                <IconCharging class="w-8 h8 inline-block"></IconCharging>
                <span class="text-gray-200 inline-block ml-4">-</span>
            </div>
        </div>
    </div>
</template>

<script setup>
  import { use } from 'echarts/core'
  import { GaugeChart } from 'echarts/charts'
  import VChart, { THEME_KEY } from "vue-echarts";
  import { CanvasRenderer } from 'echarts/renderers'
  import IconCharging from '../icons/IconCharging.vue'
  import IconBattery from '../icons/IconBattery.vue'
  import IconElectricity from '../icons/IconElectricity.vue'

  import {provide} from 'vue'

  use([
    GaugeChart,
    CanvasRenderer
  ])

  provide(THEME_KEY, "light");

    const gaugeData = [
        {
            value: 0,
            name: 'Charge',
            detail: {
                valueAnimation: true,
                color: "#fff",
                offsetCenter: ['0%', '0%']
            }
        },
    ];
    let option = {
    series: [
        {
        type: 'gauge',
        startAngle: 0,
        endAngle: 360,
        pointer: {
            show: false
        },
        progress: {
            show: true,
            overlap: false,
            roundCap: false,
            clip: false,

            itemStyle: {
                color: '#4ade80',
                borderWidth: 1,
                borderColor: '#4ade80'
            }
        },
        axisLine: {
            lineStyle: {
                width: 24,
                color: [
                    [1, 'rgb(55,65,81)']
                ]
            }
        },
        splitLine: {
            show: false,
        },
        axisTick: {
            show: false
        },
        axisLabel: {
            show: false,
        },
        data: gaugeData,
        title: {
            show: false,
            fontSize: 14,
        },
        detail: {
            width: 50,
            height: 32,
            fontSize: 32,
            color: 'inherit',
            formatter: '{value}%'
        }
        }
    ]
    };
</script>

<style scoped>
  .chart {
    height: 200px;
  }
</style>