<template>
    <h1 class="text-xl">{{ title }}</h1>
    <div class="grid grid-cols-3 gap-10">
        <div v-for="block in blocks">
            <div v-if="block.attributes.subtype === 'lineChart'" class="p-5 border-solid border rounded border-gray-300 shadow-md">
                <RealTimeLineChart :ref="block.id" :title="block.attributes.name" :series="block.attributes.yAxis.map((axis) => axis.series).flat(1)" :id="block.id" :serieMaxSize=300 :yaxis="block.attributes.yAxis" :interval="refreshInterval" :store="metricsStore"></RealTimeLineChart>
            </div>
            <div v-if="block.attributes.subtype === 'table'">
                <RealTimeTable :title="block.attributes.name" :metrics="block.attributes.metrics" :interval="refreshInterval" :store="metricsStore"></RealTimeTable>
            </div>
        </div>
    </div>
</template>

<script setup>
    import { onMounted, onUpdated, ref } from 'vue'
    import { useMetrics } from "../stores/metrics.js"
    import { vmsDashboardSocket } from '../services/socket_service.js'
    import VehiculeService from "../services/vehicle_service.js"
    import RealTimeLineChart from '@/components/charts/RealTimeLineChart.vue';
    import RealTimeTable from '@/components/tables/RealTimeTable.vue';

    const props = defineProps(['title', 'id', 'refreshInterval'])
    const title = props.title
    const id = props.id
    const refreshInterval = props.refreshInterval
    const metricsStore = useMetrics()

    let blocks = ref()

    VehiculeService.getVehiclePageBlocks(id).then((response) => {
        blocks.value = response.data.data
        metricsStore.init(vmsDashboardSocket, refreshInterval.value, "metrics")
        response.data.data.forEach((block) => {
            if(block.attributes.subtype === 'linearChart'){
                block.attributes.yAxis.map((axis) => axis.series).forEach((serie) => {
                    metricsStore.subscribeToMetric({module: serie.metric.module, name: serie.metric.name})
                })
            } else if(block.attributes.subtype === 'table'){
                block.attributes.metrics.forEach((metric) => {
                    metricsStore.subscribeToMetric({module: metric.module, name: metric.name})
                })
            }
        })
    });
</script>