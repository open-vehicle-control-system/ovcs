<template>
<h4 class="text-base font-semibold leading-7 text-gray-900">{{ networkInterface.attributes.interfaceName }}</h4>
<div class="-mx-4 -my-2 overflow-x-auto sm:-mx-6 lg:-mx-8">
    <div class="inline-block min-w-full py-2 align-middle sm:px-6 lg:px-8">
        <div class="overflow-hidden shadow ring-1 ring-black ring-opacity-5 sm:rounded-lg">
            <table class="min-w-full divide-y divide-gray-300">
                <tbody class="divide-y divide-gray-200 bg-white">
                <tr>
                    <td scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900 sm:pl-6">RX</td>
                    <td scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900 sm:pl-6">Bytes</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Dropped</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Errors</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Multicast</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Over Errors</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Packets</td>
                </tr>
                <tr>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6"></td>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6">{{ networkInterface.attributes.statistics.stats64.rx.bytes }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.rx.dropped }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.rx.errors }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.rx.multicast }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.rx.over_errors }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.rx.packets }}</td>
                </tr>
                <tr>
                    <td scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900 sm:pl-6">RX Errors</td>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6"></td>
                    <td scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900 sm:pl-6">Length</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">CRC</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Frame</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Fifo</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Missed</td>
                </tr>
                <tr>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6"></td>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6"></td>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6">{{ networkInterface.attributes.statistics.stats64.rx.length_errors }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.rx.crc_errors }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.rx.frame_errors }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.rx.fifo_errors }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.rx.missed_errors }}</td>
                </tr>
                <tr>
                    <td scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900 sm:pl-6">TX</td>
                    <td scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900 sm:pl-6">Bytes</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Carrier Errors</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Collisions</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Dropped</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Errors</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Packets</td>
                </tr>
                <tr>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6"></td>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6">{{ networkInterface.attributes.statistics.stats64.tx.bytes }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.tx.carrier_errors }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.tx.collisions }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.tx.dropped }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.tx.errors }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.tx.packets }}</td>
                </tr>
                <tr>
                    <td scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900 sm:pl-6">TX Errors</td>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6"></td>
                    <td scope="col" class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900 sm:pl-6">Aborted</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Fifo</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Window</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Heartbeat</td>
                    <td scope="col" class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Carrier changes</td>
                </tr>
                <tr>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6"></td>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6"></td>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900 sm:pl-6">{{ networkInterface.attributes.statistics.stats64.tx.aborted_errors }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.tx.fifo_errors }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.tx.window_errors }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.tx.heartbeat_errors }}</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">{{ networkInterface.attributes.statistics.stats64.tx.carrier_changes }}</td>
                </tr>
                </tbody>
            </table>
        </div>
    </div>
</div>
</template>

<script setup>
    const props = defineProps(['networkInterface'])
    const networkInterface = props.networkInterface;
</script>