<template>
    <RealTimeThrottleChart ref="realTimeThrottleChart" :carControls="carControls"></RealTimeThrottleChart>
</template>

<script>
import { vmsDashboardSocket } from '../services/socket_service.js'
import { useCarControls } from "../stores/car_controls.js"
import { onMounted } from 'vue'

import RealTimeThrottleChart from "../components/charts/RealTimeThrottleChart.vue"

export default {
  name: "Home",
  components: {
    RealTimeThrottleChart,
  },
  setup(){
    const carControls = useCarControls();
    const chartInterval = 50;

    onMounted(() => {
      let carControlsChannel = vmsDashboardSocket.channel("car-controls", {interval: chartInterval})
      carControlsChannel.on("updated", payload => {
        carControls.$patch(payload);
      });
      carControlsChannel.join().receive("ok", () => {});
    });

    return {
      carControls
    }
  }
};

</script>