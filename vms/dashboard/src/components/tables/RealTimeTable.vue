<template>
    <h2 class="text-base">{{ title }}</h2>
    <table class="min-w-full divide-y divide-gray-300">
        <tbody class="divide-y divide-gray-200 bg-white">
            <tr v-for="metric in metrics">
                <td class="text-wrap whitespace-nowrap px-3 py-4 text-sm font-bold text-gray-600">{{ metric.name }}</td>
                <td v-if="store.data[metric.module]"  class="text-gray-500 text-wrap break-all whitespace-nowrap px-3 py-4 text-sm text-right">{{ displayValue(store, metric) }}</td>
            </tr>
        </tbody>
    </table>
</template>

<script setup>
import data from 'emoji-mart-vue-fast/data/all.json'
import { EmojiIndex } from 'emoji-mart-vue-fast/src'
let emojiIndex = new EmojiIndex(data)

const props = defineProps(['title', 'metrics', 'interval', 'store'])

const title = props.title
let metrics = props.metrics
let store = props.store

const displayValue = (store, metric) => {
    let value = store.data[metric.module][metric.key]
    if(value === true){
        return emojiIndex.findEmoji(":white_check_mark:").native
    } else if(value === false) {
        return emojiIndex.findEmoji(":x:").native
    } else {
        console.log(metric.unit)
        let displayValue = store.data[metric.module][metric.key]
        metric.unit != null? displayValue = displayValue + " " + metric.unit : undefined
        return displayValue
    }
}

</script>