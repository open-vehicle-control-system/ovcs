<template>
    <h1 class="text-xl">{{ title }}</h1>
    <div  class="grid grid-flow-row grid-cols-3 gap-10">
        <div v-for="block in blocks" :class="[block.attributes.fullWidth ? 'col-span-3' : 'col-span-1', 'p-5 border-solid border rounded border-gray-300 shadow-md']">
            <div v-if="block.attributes.subtype === 'lineChart'">
                <RealTimeLineChart
                    :ref="id + '-' + block.id"
                    :title="block.attributes.name"
                    :series="block.attributes.yAxis.map((axis, index) => axis.series.map((serie) => {serie.yAxisIndex = index; return serie})).flat(1)"
                    :id="id + '-' + block.id"
                    :serieMaxSize="block.attributes.serieMaxSize"
                    :yaxis="block.attributes.yAxis"
                    :interval="refreshInterval"
                    :store="metricsStore">
                </RealTimeLineChart>
            </div>
            <div v-if="block.attributes.subtype === 'table'">
                <RealTimeTable :title="block.attributes.name" :rows="block.attributes.rows" :interval="refreshInterval" :store="metricsStore" :colorTheme="colorTheme"></RealTimeTable>
            </div>
        </div>
    </div>
</template>

<script setup>
    import { ref, onMounted, onUnmounted } from 'vue'
    import { useMetrics } from "@/stores/metrics.js"
    import { vmsDashboardSocket } from '@/services/socket_service.js'
    import VehiculeService from "@/services/vehicle_service.js"
    import RealTimeLineChart from '@/components/charts/RealTimeLineChart.vue';
    import RealTimeTable from '@/components/tables/RealTimeTable.vue';

    const props = defineProps(['title', 'id', 'refreshInterval', 'colorTheme'])
    const title = props.title
    const id = props.id
    const refreshInterval = props.refreshInterval
    const metricsStore = useMetrics()
    const colorTheme = props.colorTheme

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
                    block.attributes.rows.forEach((row) => {
                        if (row.type == "metric") {
                            metricsStore.subscribeToMetric({module: row.module, key: row.key})
                        } else if (row.type == "action" && row.statusMetricKey) {
                            metricsStore.subscribeToMetric({module: row.module, key: row.statusMetricKey})
                        }
                    })
                }
            })
        });
    });

    onUnmounted(() => {
        Object.keys(metricsStore.data).forEach((module) => {
            let metrics = metricsStore.data[module]
            let keys = Object.keys(metrics)
            keys.forEach((key) => {
                metricsStore.unsubscribeToMetric({module: module, key: key})
            })
        })
    })

</script>