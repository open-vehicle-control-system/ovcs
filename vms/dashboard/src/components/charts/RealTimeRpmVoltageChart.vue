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
        const voltageMax      = 500;
        const maxRPM          = 7000;

        const rpm = "RPM"
        const voltage  = "Voltage"

        const inverter = props.inverter

        let series = [
            {name: rpm, data: []},
            {name: voltage, data: []}
        ];

        let yaxis = [
            { seriesName: rpm, tickAmount: 5, forceNiceScale: true, max: maxRPM, min: 0 },
            { seriesName: voltage, tickAmount: 10, forceNiceScale: true, opposite: true, max: voltageMax, min: 0 }
        ];

        function updateSeries(payload){
            rpmVoltageChart.value.pushSeriesData([
                {name: rpm, value: payload.rpm},
                {name: voltage, value: payload.output_voltage}
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