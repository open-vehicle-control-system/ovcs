<template>
  <RealTimeLineChart ref="speedChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis"></RealTimeLineChart>
</template>

<script setup>
    import RealTimeLineChart from "./RealTimeLineChart.vue"
    import { ref } from "vue"

    const props = defineProps(['vehicleInformation'])

    const chartTitle    = "Speed";
    const chartId       = "realtime-speed-chart";
    const speedChart   = ref();
    const serieMaxSize  = 300;
    const max           = 200;
    const min           = 0;

    const speed = "Speed"
    const vehicleInformation = props.vehicleInformation

    let series = [{name: speed}];

    let yaxis = [
        {serieName: speed, label: "kph", min: min, max: max}
    ];

    function updateSeries(payload){
        speedChart.value.pushSeriesData([
            {name: speed, value: payload.speed},
        ]);
    }

    vehicleInformation.$subscribe((mutation, state) => {
        updateSeries(state);
    })
</script>