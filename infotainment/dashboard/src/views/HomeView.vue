<template>
    <div class="grid grid-row-4 grid-cols-12 gap-8">
        <div class="row-span-2 col-span-2 bg-gray-800 opacity-90 font-extrabold rounded-3xl">
            <GearSelector :store="store"></GearSelector>
        </div>
        <div class="row-span-2 col-span-5 bg-gray-800 opacity-90 rounded-3xl">
            <RealTimeSpeedGauge :metrics="store"></RealTimeSpeedGauge>
        </div>
        <div class="row-span-2 col-span-5 bg-gray-800 opacity-90 rounded-3xl">
            <CarOverview :metrics="store"></CarOverview>
        </div>
        <div class="bg-gray-800 row-span-1 col-span-6 opacity-90 rounded-3xl">
            <BatteryMonitor></BatteryMonitor>
        </div>
        <div class="bg-gray-800 col-span-6 opacity-90 rounded-3xl text-white">
            <Player></Player>
        </div>
    </div>
</template>

<script setup>
import RealTimeSpeedGauge from "../components/gauges/RealtimeSpeedGauge.vue";
import GearSelector from "../components/controls/GearSelector.vue";
import CarOverview from "../components/car/CarOverview.vue";
import BatteryMonitor from "../components/gauges/BatteryMonitor.vue"
import Player from "../components/multimedia/Player.vue"

import { onMounted } from 'vue'
import { useMetricsStore } from "../stores/metrics.js"
import { Socket } from 'phoenix'

const store = useMetricsStore()

onMounted(() => {
  let dashboardSocket = new Socket(import.meta.env.VITE_BASE_WS+ "/sockets/dashboard", {})
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