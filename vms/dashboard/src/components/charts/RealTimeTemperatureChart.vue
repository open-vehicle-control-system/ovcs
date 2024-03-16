<template>
  <RealTimeLineChart ref="temperatureChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis"></RealTimeLineChart>
</template>

<script setup>
    import RealTimeLineChart from "./RealTimeLineChart.vue"
    import { ref } from "vue"

    const props = defineProps(['inverter'])

    const chartTitle    = "Temperature";
    const chartId       = "realtime-temperature-chart";
    const temperatureChart   = ref();
    const serieMaxSize  = 300;
    const max           = 200;
    const min           = -50;

    const inverterCommunicationBoardTemperature = "Inverter Board"
    const insulatedGateBipolarTransistorTemperature = "IBGT"
    const insulatedGateBipolarTransistorBoardTemperature = "IGBT Board"
    const motorTemperature = "Motor"
    const inverter = props.inverter

    let series = [
        {name: inverterCommunicationBoardTemperature, data: []},
        {name: insulatedGateBipolarTransistorTemperature, data: []},
        {name: insulatedGateBipolarTransistorBoardTemperature, data: []},
        {name: motorTemperature, data: []}
    ];

    let yaxis = [
        { serieName: inverterCommunicationBoardTemperature, label: "°C", min: min },
    ];

    function setMax(max) {
        temperatureChart.value.setMax(inverterCommunicationBoardTemperature, max);
    }

    function updateSeries(payload){
        temperatureChart.value.pushSeriesData([
            {name: inverterCommunicationBoardTemperature, value: payload.inverterCommunicationBoardTemperature},
            {name: insulatedGateBipolarTransistorTemperature, value: payload.insulatedGateBipolarTransistorTemperature},
            {name: insulatedGateBipolarTransistorBoardTemperature, value: payload.insulatedGateBipolarTransistorBoardTemperature},
            {name: motorTemperature, value: payload.motorTemperature},
        ]);
    }

    inverter.$subscribe((mutation, state) => {
        setMax(max);
        updateSeries(state);
    })
</script>