<template>
    <div class="grid grid-row-4 grid-cols-12 gap-8">
        <div class="row-span-2 col-span-2 bg-gray-800 opacity-90 p-6 font-extrabold rounded-md text-3xl text-white table">
            <div class="h-20 w-20 text-center align-middle table-cell bg-gray-700 opacity-99 rounded-md table-row">
                <span class="leading-5 align-middle table-cell">P</span>
            </div>
            <div class="table-row">
                <span class="h-20 w-20 leading-5 align-middle table-cell text-center">R</span>
            </div>
            <div class="table-row">
                <span class="h-20 w-20 leading-5 align-middle table-cell text-center">N</span>
            </div>
            <div class="table-row">
                <span class="h-20 w-20 leading-5 align-middle table-cell text-center">D</span>
            </div>
        </div>
        <div class="row-span-2 col-span-5 bg-gray-800 opacity-90 rounded-md p-0">
            <RealTimeSpeedGauge :metrics="useMetrics" id="speed-gauge"/>
        </div>
        <div class="row-span-2 col-span-5 bg-gray-800 opacity-90 rounded-md p-8">
        </div>
        <div class="bg-gray-800 col-span-6 opacity-90 rounded-md">
            <h2 class="text-white p-4">Battery level</h2>
            <div class="batteryContainer p-4">
                <div class="batteryOuter"><div id="batteryLevel"></div></div>
                <div class="batteryBump"></div>
            </div>
        </div>
        <div class="bg-gray-800 col-span-6 opacity-90 rounded-md text-white">
            <div class="grid grid-rows-2 gap-4 h-full">
                <div class="grid grid-cols-2 gap-4">
                    <div class="inline p-8">
                        Image
                    </div>
                    <div class="inline p-8">
                        <h3>Tippik (DAB+)</h3>
                        <h4>Green Day: Basket Case</h4>
                    </div>
                </div>

                <div class="bg-black p-6">
                    <div class="inline">Back</div>
                    <div class="inline">Play</div>
                    <div class="inline">Pause</div>
                    <div class="inline">Forward</div>
                </div>
            </div>
        </div>
    </div>
</template>

<script setup>
import RealTimeSpeedGauge from "../components/gauges/RealtimeSpeedGauge.vue";

import { onMounted } from 'vue'
import { storeToRefs } from 'pinia'
import { useMetricsStore } from "../stores/metrics.js"
import { Socket } from 'phoenix'
const useMetrics = useMetricsStore()
const { metrics } = storeToRefs(useMetrics)

onMounted(() => {
  let store = useMetricsStore()
  let dashboardSocket = new Socket("ws://localhost:4001/sockets/dashboard", {})
  dashboardSocket.connect()
  let metricsChannel = dashboardSocket.channel("debug-metrics", {})

  metricsChannel.on("updated", payload => {
    store.$patch(payload)
  })

  metricsChannel.join()
    .receive("ok", () => {})
});

</script>

<style scoped>
.batteryContainer {
  display: -webkit-box;
  display: -moz-box;
  display: -ms-flexbox;
  display: -webkit-flex;
  display: flex;
  flex-direction: row;
  align-items: center;
}

.batteryOuter {
  border-radius: 3px;
  border: 3px solid #73AD21;
  padding: 1px;
  width: 250px;
  height: 90px;
}

.batteryBump {
  border-radius: 3px;
  background-color: #73AD21;
  margin: 3px;
  width: 10px;
  height: 30px;
}

#batteryLevel {
  border-radius: 2px;
  background-color: #73AD21;
  width: 0px;
  height: 90px;
}
</style>