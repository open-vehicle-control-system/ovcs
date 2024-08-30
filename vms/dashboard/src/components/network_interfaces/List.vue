<template>
    <h3 class="text-base mt-10">Interfaces list</h3>
    <div class="-mx-4 -my-2 overflow-x-auto sm:-mx-6 lg:-mx-8 mt-10">
        <div class="inline-block min-w-full py-2 align-middle sm:px-6 lg:px-8">
        <div class="overflow-hidden shadow ring-1 ring-black ring-opacity-5 sm:rounded-lg">
            <table class="min-w-full divide-y divide-gray-300">
            <thead class="bg-gray-50">
                <tr>
                <th scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900 sm:pl-6">Network</th>
                <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Interface</th>
                <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">SPI Interface</th>
                <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">State</th>
                <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Tx queue length</th>
                <th scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Load</th>
                </tr>
            </thead>
            <tbody class="divide-y divide-gray-200 bg-white">
                <tr v-for="networkInterface in networkInterfaces.data" :key="networkInterface.attributes.interfaceName">
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6">{{ networkInterface.attributes.networkName }}</td>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6">{{ networkInterface.attributes.interfaceName }}</td>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6">{{ networkInterface.attributes.spiInterfaceName }}</td>
                <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                    <div class="flex items-center gap-x-3">
                    <div :class="[statuses[networkInterface.attributes.statistics.operstate], 'flex-none rounded-full']">
                    <div class="h-2 w-2 rounded-full bg-current"></div>
                    </div>
                    <span>{{ networkInterface.attributes.statistics.operstate }}</span>
                    </div>
                </td>
                <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.txqlen }}</td>
                <td v-if="networkInterfaces.statistics[networkInterface.attributes.statistics.ifindex]" class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                    <div class="inline-block bg-gray-200 rounded-full h-2.5 dark:bg-gray-100 w-20">
                    <div class="bg-blue-600 h-2.5 rounded-full" :style="{'width': networkInterfaces.interfaceLoad(networkInterface.attributes.statistics.ifindex) + '%'}"></div>
                    </div>
                    <div class="inline-block px-3">{{ networkInterfaces.interfaceLoad(networkInterface.attributes.statistics.ifindex) }}%</div>
                </td>
                </tr>
            </tbody>
            </table>
        </div>
        </div>
    </div>
</template>

<script setup>
    const props = defineProps(['networkInterfaces'])
    const statuses = {
        UNKNOWN: 'text-gray-500 bg-gray-100/10',
        UP: 'text-green-400 bg-green-400/10',
        DOWN: 'text-rose-400 bg-rose-400/10',
    }
    let networkInterfaces = props.networkInterfaces;
</script>