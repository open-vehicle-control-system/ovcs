<template>
  <RealTimeLineChart ref="temperatureChart" :title="chartTitle" :series="series" :id="chartId" :serieMaxSize="serieMaxSize" :yaxis="yaxis"></RealTimeLineChart>
</template>

<script>
import RealTimeLineChart from "./RealTimeLineChart.vue"
import { ref } from "vue"

export default{
    name: "RealTimeTemperatureChart",
    props: ["inverter"],
    components: {
        RealTimeLineChart,
    },
    setup(props){
        const chartTitle    = "Real-time Temperature Chart";
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
            { seriesName: inverterCommunicationBoardTemperature, tickAmount: 5, forceNiceScale: true, min: min },
            { seriesName: insulatedGateBipolarTransistorTemperature, tickAmount: 5, forceNiceScale: true, min: min, show: false },
            { seriesName: insulatedGateBipolarTransistorBoardTemperature, tickAmount: 5, forceNiceScale: true, min: min, show: false },
            { seriesName: motorTemperature, tickAmount: 5, forceNiceScale: true, min: min, show: false },
        ];

        function setMax(max) {
            temperatureChart.value.setYaxisMaxForSerie(inverterCommunicationBoardTemperature, max);
            temperatureChart.value.setYaxisMaxForSerie(insulatedGateBipolarTransistorTemperature, max);
            temperatureChart.value.setYaxisMaxForSerie(insulatedGateBipolarTransistorBoardTemperature, max);
            temperatureChart.value.setYaxisMaxForSerie(motorTemperature, max);
        }

        function updateSeries(payload){
            temperatureChart.value.pushSeriesData([
                {name: inverterCommunicationBoardTemperature, value: payload.inverter_communication_board_temperature},
                {name: insulatedGateBipolarTransistorTemperature, value: payload.insulated_gate_bipolar_transistor_temperature},
                {name: insulatedGateBipolarTransistorBoardTemperature, value: payload.insulated_gate_bipolar_transistor_board_temperature},
                {name: motorTemperature, value: payload.motor_temperature},
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
            temperatureChart,
            serieMaxSize,
            yaxis,
            setMax,
            updateSeries
        }
    }
}
</script>