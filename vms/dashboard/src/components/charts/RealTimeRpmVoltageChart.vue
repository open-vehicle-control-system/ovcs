<template>
    <div class="p-5 border-solid border rounded border-gray-300 shadow-md">
        <RealTimeLineChart ref="rpmVoltageChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis" :interval="interval"></RealTimeLineChart>
    </div>
</template>

<script setup>
    import RealTimeLineChart from "./RealTimeLineChart.vue"
    import { ref } from "vue"

    const props = defineProps(['inverter', 'interval'])

    const chartTitle      = "RPM & Voltage";
    const chartId         = "realtime-rmp-voltage-chart";
    const rpmVoltageChart = ref();
    const serieMaxSize    = 300;
    const voltageMax      = 600;
    const maxRPM          = 7000;
    const interval        = props.interval;

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