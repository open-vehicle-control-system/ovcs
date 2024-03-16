<template>
  <RealTimeLineChart ref="speedChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis"></RealTimeLineChart>
</template>

<script setup>
    import RealTimeLineChart from "./RealTimeLineChart.vue"
    import { ref } from "vue"

    const props = defineProps(['vehicle'])

    const chartTitle    = "Speed";
    const chartId       = "realtime-speed-chart";
    const speedChart   = ref();
    const serieMaxSize  = 300;
    const max           = 200;
    const min           = 0;

    const speed = "Speed"
    const vehicle = props.vehicle

    let series = [
        { name: speed, data: []}
    ];

    let yaxis = [
        {serieName: speed, label: "kph", min: min, max: max}
    ];

    function updateSeries(payload){
        speedChart.value.pushSeriesData([
            {name: speed, value: payload.speed},
        ]);
    }

    vehicle.$subscribe((mutation, state) => {
        updateSeries(state);
    })
</script>