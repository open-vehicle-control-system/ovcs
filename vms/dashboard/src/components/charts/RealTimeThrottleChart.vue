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
        const chartTitle    = "Throttle";
        const chartId       = "realtime-throttle-chart";
        const throttleChart = ref();
        const serieMaxSize  = 300;

        const throttleALabel = "Throttle A"
        const throttleBLabel = "Throttle B"
        const throttleABLabel = "Throttle A&B"
        const throttleLabel  = "Throttle"

        const carControls = props.carControls

        let series = [
            {name: throttleALabel, data: [], type: 'line', showSymbol: false},
            {name: throttleBLabel, data: [], type: 'line', showSymbol: false},
            {name: throttleLabel, data: [], type: 'line', showSymbol: false, yAxisIndex: 1}
        ];

        let yaxis = [
            { label: throttleABLabel, serieName: throttleALabel, type: 'value' },
            { label: throttleLabel, serieName: throttleLabel, type: 'value', position: 'right', max: 1 }
        ];

        function setMaxRawThrottle(max) {
            throttleChart.value.setMax(throttleALabel, max);
        }

        function updateSeries(payload){
            throttleChart.value.pushSeriesData([
                {name: throttleALabel, value: payload.rawThrottleA},
                {name: throttleBLabel, value: payload.rawThrottleB},
                {name: throttleLabel, value: payload.throttle}
            ]);
        }

        carControls.$subscribe((mutation, state) => {
            setMaxRawThrottle(state.rawMaxThrottle);
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