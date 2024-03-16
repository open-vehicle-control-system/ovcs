<template>
  <div class="px-4 sm:px-6 lg:px-8">
    <h1 class="text-xl">Network</h1>
    <form>
      <div class="space-y-12">
        <div class="border-b border-gray-900/10 pb-12">
          <h2 class="text-base font-semibold leading-7 text-gray-900">Network status</h2>
          <div class="mt-8 flow-root">
            <NetworkInterfacesList :networkInterfaces="networkInterfaces"></NetworkInterfacesList>

            <h3 class="text-base mt-10">Interfaces traffic</h3>
            <div class="space-y-10 mt-10">
              <NetworkInterfaceStatistics v-for="networkInterface in networkInterfaces.interfaces" :key="networkInterface.ifname" :networkInterface="networkInterface"></NetworkInterfaceStatistics>
            </div>
          </div>
        </div>
      </div>
    </form>
  </div>
</template>

<script setup>
  import { onMounted } from 'vue'
  import { vmsDashboardSocket } from '../services/socket_service.js'

  import NetworkInterfaceStatistics from "../components/network_interfaces/Statistics.vue"
  import NetworkInterfacesList from "../components/network_interfaces/List.vue"

  import { useNetworkInterfaces } from "../stores/network_interfaces.js"

  const networkInterfaces = useNetworkInterfaces()
  const chartInterval = 1000;

  onMounted(() => {
    networkInterfaces.init(vmsDashboardSocket, chartInterval, "network-interfaces", (store) => {
      store.computeInterfacesLoad();
    })
  });
</script>