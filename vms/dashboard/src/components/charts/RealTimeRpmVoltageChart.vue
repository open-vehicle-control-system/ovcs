<template>
  <RealTimeLineChart ref="rpmVoltageChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis"></RealTimeLineChart>
</template>

<script>
import RealTimeLineChart from "./RealTimeLineChart.vue"
import { ref } from "vue"

export default{
    name: "RealTimeThrottleChart",
    props: ["inverter"],
    components: {
        RealTimeLineChart,
    },
    setup(props){
        const chartTitle      = "RPM & Voltage";
        const chartId         = "realtime-rmp-voltage-chart";
        const rpmVoltageChart = ref();
        const serieMaxSize    = 300;
        const voltageMax      = 600;
        const maxRPM          = 7000;

        const rpm = "RPM"
        const voltage  = "Voltage"

        const inverter = props.inverter

        let series = [
            {name: rpm, data: [], type: 'line', showSymbol: false},
            {name: voltage, data: [], type: 'line', showSymbol: false, yAxisIndex: 1}
        ];

        let yaxis = [
            { label: rpm, serieName: rpm, type: 'value', max: maxRPM, min: 0 },
            { label: voltage, serieName: voltage, type: 'value', max: voltageMax, min: 0 }
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

        return {
            series,
            chartId,
            chartTitle,
            rpmVoltageChart,
            serieMaxSize,
            yaxis,
            updateSeries
        }
    }
}
</script>