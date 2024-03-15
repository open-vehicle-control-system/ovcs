<template>
  <RealTimeLineChart ref="speedChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis"></RealTimeLineChart>
</template>

<script>
import RealTimeLineChart from "./RealTimeLineChart.vue"
import { ref } from "vue"

export default{
    name: "RealTimeSpeedChart",
    props: ["vehicle"],
    components: {
        RealTimeLineChart,
    },
    setup(props){
        const chartTitle    = "Speed";
        const chartId       = "realtime-speed-chart";
        const speedChart   = ref();
        const serieMaxSize  = 300;
        const max           = 200;
        const min           = 0;

        const speed = "SPeed"
        const vehicle = props.vehicle

        let series = [
            {name: speed, data: []}
        ];

        let yaxis = [
            { seriesName: speed, tickAmount: 5, forceNiceScale: true, min: min, max: max}
        ];

        function updateSeries(payload){
            speedChart.value.pushSeriesData([
                {name: speed, value: payload.speed},
            ]);
        }

        vehicle.$subscribe((mutation, state) => {
            updateSeries(state);
        })

        return {
            series,
            chartId,
            chartTitle,
            speedChart,
            serieMaxSize,
            yaxis,
            updateSeries
        }
    }
}
</script>