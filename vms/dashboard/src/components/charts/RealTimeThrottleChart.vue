<template>
    <RealTimeLineChart ref="throttleChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis" :interval="interval"></RealTimeLineChart>
  </template>

  <script setup>
      import RealTimeLineChart from "./RealTimeLineChart.vue"
      import { ref } from "vue"

      const props = defineProps(['throttle', 'interval'])

      const chartTitle    = "Throttle";
      const chartId       = "realtime-throttle-chart";
      const throttleChart = ref();
      const serieMaxSize  = 300;
      const interval        = props.interval;

      const throttleALabel = "Throttle A"
      const throttleBLabel = "Throttle B"
      const throttleLabel  = "Computed Throttle"

      const throttle = props.throttle

      let series = [
          {name: throttleALabel},
          {name: throttleBLabel},
          {name: throttleLabel, yAxisIndex: 1}
      ];

      let yaxis = [
          {serieName: throttleALabel, label: "Raw"},
          {serieName: throttleLabel, position: 'right', max: 1, label: "Computed"}
      ];

      function setMax(max) {
          throttleChart.value.setMax(throttleALabel, max);
      }

      function updateSeries(payload){
          throttleChart.value.pushSeriesData([
              {name: throttleALabel, value: payload.rawThrottleA},
              {name: throttleBLabel, value: payload.rawThrottleB},
              {name: throttleLabel, value: payload.throttle}
          ]);
      }

      throttle.$subscribe((mutation, state) => {
          setMax(state.rawMaxThrottle);
          updateSeries(state);
      })
  </script>