<template>
    <h1 class="text-xl">{{ title }}</h1>
    <div class="grid grid-cols-3 gap-10">
        <div v-for="block in blocks">
            <div v-if="block.attributes.subtype === 'calibration'">
                <CalibrationTable :title="block.attributes.name" :values="block.attributes.values" :store="metricsStore"></CalibrationTable>
            </div>
            <div v-if="block.attributes.subtype === 'lineChart'" class="p-5 border-solid border rounded border-gray-300 shadow-md">
                <RealTimeLineChart
                    :ref="block.id"
                    :title="block.attributes.name"
                    :series="block.attributes.yAxis.map((axis, index) => axis.series.map((serie) => {serie.yAxisIndex = index; return serie})).flat(1)"
                    :id="block.id"
                    :serieMaxSize="block.attributes.serieMaxSize"
                    :yaxis="block.attributes.yAxis"
                    :interval="refreshInterval"
                    :store="metricsStore">
                </RealTimeLineChart>
            </div>
            <div v-if="block.attributes.subtype === 'table'">
                <RealTimeTable :title="block.attributes.name" :metrics="block.attributes.metrics" :interval="refreshInterval" :store="metricsStore"></RealTimeTable>
            </div>
        </div>
    </div>
</template>

<script setup>
    import { ref, onMounted, onUnmounted } from 'vue'
    import { useMetrics } from "../stores/metrics.js"
    import { vmsDashboardSocket } from '../services/socket_service.js'
    import VehiculeService from "../services/vehicle_service.js"
    import RealTimeLineChart from '@/components/charts/RealTimeLineChart.vue';
    import RealTimeTable from '@/components/tables/RealTimeTable.vue';
    import CalibrationTable from '@/components/tables/CalibrationTable.vue';

    const props = defineProps(['title', 'id', 'refreshInterval'])
    const title = props.title
    const id = props.id
    const refreshInterval = props.refreshInterval
    const metricsStore = useMetrics()

    let blocks = ref()

    onMounted(() => {
        VehiculeService.getVehiclePageBlocks(id).then((response) => {
            blocks.value = response.data.data
            metricsStore.init(vmsDashboardSocket, refreshInterval.value, "metrics")
            response.data.data.forEach((block) => {
                if(block.attributes.subtype === 'lineChart'){
                    block.attributes.yAxis.map((axis) => axis.series).flat(1).forEach((serie) => {
                        metricsStore.subscribeToMetric(serie.metric)
                    })
                } else if(block.attributes.subtype === 'table'){
                    block.attributes.metrics.forEach((metric) => {
                        metricsStore.subscribeToMetric(metric)
                    })
                } else if(block.attributes.subtype === 'calibration'){
                    block.attributes.values.forEach((value) => {
                        if(value.statusMetricKey){
                            metricsStore.subscribeToMetric({module: value.module, key: value.statusMetricKey})
                        }
                    })
                }
            })
        });
    });

    onUnmounted(() => {
        Object.keys(metricsStore.data).forEach((module) => {
            let metrics = metricsStore.data[module]
            let statusMetricsKeys = Object.keys(metrics)
            statusMetricsKeys.forEach((statusMetricKey) => {
                metricsStore.unsubscribeToMetric({module: module, key: statusMetricKey})
            })
        })
    })

</script>