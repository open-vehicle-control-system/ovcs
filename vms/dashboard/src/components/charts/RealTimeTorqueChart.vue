<template>
  <RealTimeLineChart ref="torqueChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis"></RealTimeLineChart>
</template>

<script>
import RealTimeLineChart from "./RealTimeLineChart.vue"
import { ref } from "vue"

export default{
    name: "RealTimeTorqueChart",
    props: ["inverter"],
    components: {
        RealTimeLineChart,
    },
    setup(props){
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
            { seriesName: effectiveTorque, tickAmount: 5, forceNiceScale: true, min: min },
            { seriesName: requestedTorque, tickAmount: 5, forceNiceScale: true, min: min, show: false }
        ];

        function setMax(max) {
            torqueChart.value.setYaxisMaxForSerie(effectiveTorque, max);
            torqueChart.value.setYaxisMaxForSerie(requestedTorque, max);
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

        return {
            series,
            chartId,
            chartTitle,
            torqueChart,
            serieMaxSize,
            yaxis,
            setMax,
            updateSeries
        }
    }
}
</script>