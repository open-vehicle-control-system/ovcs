<template>
  <div class="px-4 sm:px-6 lg:px-8">
    <h1 class="text-xl">Network</h1>
    <form>
      <div class="space-y-12">
        <div class="border-b border-gray-900/10 pb-12">
          <h2 class="text-base font-semibold leading-7 text-gray-900">Network status</h2>
          <div class="mt-8 flow-root">
            <h3 class="text-base mt-10">Interfaces list</h3>
            <div class="-mx-4 -my-2 overflow-x-auto sm:-mx-6 lg:-mx-8 mt-10">
              <div class="inline-block min-w-full py-2 align-middle sm:px-6 lg:px-8">
                <div class="overflow-hidden shadow ring-1 ring-black ring-opacity-5 sm:rounded-lg">
                  <table class="min-w-full divide-y divide-gray-300">
                    <thead class="bg-gray-50">
                      <tr>
                        <th scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900 sm:pl-6">Name</th>
                        <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Link Type</th>
                        <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">State</th>
                        <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Tx queue length</th>
                        <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Load</th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-gray-200 bg-white">
                      <tr v-for="networkInterface in networkInterfaces.interfaces" :key="networkInterface.ifname">
                        <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6">{{ networkInterface.ifname }}</td>
                        <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.link_type }}</td>
                        <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                          <div class="flex items-center gap-x-3">
                          <div :class="[statuses[networkInterface.operstate], 'flex-none rounded-full']">
                            <div class="h-2 w-2 rounded-full bg-current"></div>
                          </div>
                          <span>{{ networkInterface.operstate }}</span>
                          </div>
                        </td>
                        <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.txqlen }}</td>
                        <td v-if="networkInterfaces.statistics[networkInterface.ifindex]" class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                          <div class="inline-block bg-gray-200 rounded-full h-2.5 dark:bg-gray-100 w-20">
                            <div class="bg-blue-600 h-2.5 rounded-full" :style="{'width': networkInterfaces.interfaceLoad(networkInterface.ifindex) + '%'}"></div>
                          </div>
                          <div class="inline-block px-3">{{ networkInterfaces.interfaceLoad(networkInterface.ifindex) }}%</div>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>

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

<script>
import { onMounted } from 'vue'
import { Socket } from 'phoenix'

import NetworkInterfaceStatistics from "../components/network_interfaces/Statistics.vue"

import { useNetworkInterfaces } from "../stores/network_interfaces.js"

export default {
  name: "Network",
  components: {
    NetworkInterfaceStatistics
  },
  setup(){
    const networkInterfaces = useNetworkInterfaces()

    const statuses = {
      UNKNOWN: 'text-gray-500 bg-gray-100/10',
      UP: 'text-green-400 bg-green-400/10',
      DOWN: 'text-rose-400 bg-rose-400/10',
    }
    onMounted(() => {
      let networkInterfacesStore = useNetworkInterfaces()
      let vmsDashboardSocket = new Socket(import.meta.env.VITE_BASE_WS + "/sockets/dashboard", {})
      vmsDashboardSocket.connect();
      let networkInterfaces = vmsDashboardSocket.channel("network-interfaces", {})

      networkInterfaces.on("updated", payload => {
        networkInterfacesStore.$patch(payload);
        networkInterfacesStore.computeInterfacesLoad();
      })

      networkInterfaces.join().receive("ok", () => {})
    });

    return {
      networkInterfaces,
      statuses
    }
  }
};
</script>../components/network_interfaces/network_interface_statistics.vue