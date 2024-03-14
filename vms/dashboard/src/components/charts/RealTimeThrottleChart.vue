<template>
  <RealTimeLineChart ref="throttleChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis"></RealTimeLineChart>
</template>

<script>
import RealTimeLineChart from "./RealTimeLineChart.vue"
import { ref } from "vue"

export default{
    name: "RealTimeThrottleChart",
    props: ["carControls"],
    components: {
        RealTimeLineChart,
    },
    setup(props){
        const chartTitle    = "Real-time Throttle Chart";
        const chartId       = "realtime-throttle-chart";
        const throttleChart = ref();
        const serieMaxSize  = 300;

        const throttleALabel = "Throttle A"
        const throttleBLabel = "Throttle B"
        const throttleLabel  = "Throttle"

        const carControls = props.carControls

        let series = [
            {name: throttleALabel, data: []},
            {name: throttleBLabel, data: []},
            {name: throttleLabel, data: []}
        ];

        let yaxis = [
            { seriesName: throttleALabel, tickAmount: 5, forceNiceScale: true, min: 0 },
            { seriesName: throttleBLabel, tickAmount: 5, forceNiceScale: true, min: 0, show: false },
            { seriesName: throttleLabel, tickAmount: 10, forceNiceScale: true, opposite: true, max: 1, min: 0 }
        ];

        function setMaxRawThrottle(max) {
            throttleChart.value.setYaxisMaxForSerie(throttleALabel, max);
            throttleChart.value.setYaxisMaxForSerie(throttleBLabel, max);
        }

        function updateSeries(payload){
            throttleChart.value.pushSeriesData([
                {name: throttleALabel, value: payload.raw_throttle_a},
                {name: throttleBLabel, value: payload.raw_throttle_b},
                {name: throttleLabel, value: payload.throttle}
            ]);
        }

        carControls.$subscribe((mutation, state) => {
            setMaxRawThrottle(state.raw_max_throttle);
            updateSeries(state);
        })

        return {
            series,
            chartId,
            chartTitle,
            throttleChart,
            serieMaxSize,
            yaxis,
            setMaxRawThrottle,
            updateSeries
        }
    }
}
</script>