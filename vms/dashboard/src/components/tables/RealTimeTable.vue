<template>
    <h2 class="text-base">{{ title }}</h2>
    <table class="min-w-full divide-y divide-gray-300">
        <tbody class="divide-y divide-gray-200 bg-white">
            <tr v-for="metric in metrics">
                <td class="text-wrap whitespace-nowrap px-3 py-4 text-sm font-bold text-gray-600">{{ metric.name }}</td>
                <td v-if="store.data[metric.module]"  class="text-wrap break-all whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right">{{ store.data[metric.module][metric.key] }} {{ metric.unit }}</td>
            </tr>
        </tbody>
    </table>
</template>

<script setup>

const props = defineProps(['title', 'metrics', 'interval', 'store'])

const title = props.title
let metrics = props.metrics
let store = props.store

</script>