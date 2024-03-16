<template>
  <RealTimeLineChart ref="rpmVoltageChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis"></RealTimeLineChart>
</template>

<script setup>
    import RealTimeLineChart from "./RealTimeLineChart.vue"
    import { ref } from "vue"

    const props = defineProps(['inverter'])

    const chartTitle      = "RPM & Voltage";
    const chartId         = "realtime-rmp-voltage-chart";
    const rpmVoltageChart = ref();
    const serieMaxSize    = 300;
    const voltageMax      = 600;
    const maxRPM          = 7000;

    const rpm = "RPM"
    const voltage  = "Voltage"

    const inverter = props.inverter

    let series = [{name: rpm}, {name: voltage, yAxisIndex: 1}];

    let yaxis = [
        { serieName: rpm, label: "rpm", max: maxRPM, min: 0 },
        { serieName: voltage, label: "V", max: voltageMax, min: 0 }
    ];

    function updateSeries(payload){
        rpmVoltageChart.value.pushSeriesData([
            {name: rpm, value: payload.rotationPerMinute},
            {name: voltage, value: payload.outputVoltage}
        ]);
    }

    inverter.$subscribe((mutation, state) => {
        updateSeries(state);
    })
</script>