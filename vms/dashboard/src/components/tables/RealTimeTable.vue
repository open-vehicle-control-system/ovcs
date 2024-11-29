<template>
    <h2 class="text-base">{{ title }}</h2>
    <table class="min-w-full divide-y divide-gray-300">
        <tbody class="divide-y divide-gray-200 bg-white">
            <tr v-for="metric in metrics">
                <td class="text-wrap whitespace-nowrap px-3 py-4 text-sm font-bold text-gray-600">{{ metric.name }}</td>
                <td v-if="store.data[metric.module]" class="text-gray-500 text-wrap break-all whitespace-nowrap px-3 py-4 text-sm text-right ">
                    <component v-if="valueType(store, metric) === 'check'" :is="CheckIcon" class="h-6 w-6 inline-flex"></component>
                    <component v-if="valueType(store, metric) === 'xmark'" :is="XMarkIcon" class="h-6 w-6 inline-flex"></component>
                    <span v-if="valueType(store, metric) === 'none'">
                        {{ renderValue(store, metric) }}
                    </span>

                </td>
            </tr>
        </tbody>
    </table>
</template>

<script setup>
const props = defineProps(['title', 'metrics', 'interval', 'store'])

import { CheckIcon, XMarkIcon } from '@heroicons/vue/24/outline'

const title = props.title
let metrics = props.metrics
let store = props.store

const valueType = (store, metric) => {
    let value = store.data[metric.module][metric.key]
    if(typeof(value) === "boolean"){
        return renderBoolean(value);
    } else{
        return "none"
    }
}

const renderBoolean = (value) => {
    if(value === true){
        return "check"
    } else if(value === false) {
        return "xmark"
    }
}

const renderValue = (store, metric) => {
    let value = store.data[metric.module][metric.key]
    if(typeof(value) === "number"){
        let displayValue = Math.round(value*100)/100
        metric.unit != null? displayValue = displayValue + " " + metric.unit : undefined
        return displayValue
    } else {
        return value
    }
}

</script>