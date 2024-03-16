<template>
  <RealTimeLineChart ref="torqueChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis"></RealTimeLineChart>
</template>

<script setup>
    import RealTimeLineChart from "./RealTimeLineChart.vue"
    import { ref } from "vue"

    const props = defineProps(['inverter'])

    const chartTitle    = "Torque";
    const chartId       = "realtime-torque-chart";
    const torqueChart   = ref();
    const serieMaxSize  = 300;
    const max           = 300;
    const min           = -50;

    const effectiveTorque = "Effective Torque"
    const requestedTorque = "Requested Torque"
    const inverter = props.inverter

    let series = [
        {name: effectiveTorque, data: []},
        {name: requestedTorque, data: []}
    ];

    let yaxis = [
        { serieName: effectiveTorque, label: "Nm", min: min, max: max }
    ];

    function setMax(max) {
        torqueChart.value.setMax(effectiveTorque, max);
        torqueChart.value.setMax(requestedTorque, max);
    }

    function updateSeries(payload){
        torqueChart.value.pushSeriesData([
            {name: effectiveTorque, value: payload.effectiveTorque},
            {name: requestedTorque, value: payload.requestedTorque}
        ]);
    }

    inverter.$subscribe((mutation, state) => {
        setMax(max);
        updateSeries(state);
    })
</script>