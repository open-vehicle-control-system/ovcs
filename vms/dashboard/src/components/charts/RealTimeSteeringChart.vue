<template>
  <RealTimeLineChart ref="steeringChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis"></RealTimeLineChart>
</template>

<script setup>
    import RealTimeLineChart from "./RealTimeLineChart.vue"
    import { ref } from "vue"

    const props = defineProps(['steering'])

    const chartTitle    = "Steering";
    const chartId       = "realtime-steering-chart";
    const steeringChart = ref();
    const serieMaxSize  = 300;

    const angleLabel = "Angle"
    const angularSpeedLabel = "Angular Speed"

    const steering = props.steering

    let series = [
        {name: angleLabel},
        {name: angularSpeedLabel}
    ];

    let yaxis = [
        {serieName: angleLabel, label: "°"},
        {serieName: angularSpeedLabel, position: 'right', max: 1, label: "°/s"}
    ];

    function setMax(max) {
        steeringChart.value.setMax(angleLabel, max);
    }

    function updateSeries(payload){
        steeringChart.value.pushSeriesData([
            {name: angleLabel, value: payload.lwsAngle},
            {name: angularSpeedLabel, value: payload.lwsAngularSpeed}
        ]);
    }

    steering.$subscribe((mutation, state) => {
        setMax(780);
        updateSeries(state);
    })
</script>