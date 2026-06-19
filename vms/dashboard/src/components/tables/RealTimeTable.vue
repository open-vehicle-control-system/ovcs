<template>
    <h2 class="text-base">{{ title }}</h2>
    <table class="min-w-full divide-y divide-gray-300">
        <tbody class="divide-y divide-gray-200 bg-white">
            <tr v-for="row in rows">
                <td class="px-3 py-4 text-sm align-middle">
                    <div class="font-bold text-gray-600 whitespace-nowrap">{{ row.name }}</div>
                    <div v-if="row.hint" class="mt-0.5 max-w-xs whitespace-normal text-xs font-normal text-gray-400">{{ row.hint }}</div>
                </td>
                    <td v-if="row.type === 'action' && row.inputType == 'button'"  class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right content-end">
                        <button type="button" @click="triggerAction(row)" :class="[row.actionOngoing ? 'bg-gray-200' : colorTheme.bgColor, colorTheme.onHoverColor + ' inline-flex items-center gap-x-2 rounded-md px-3.5 py-2.5 text-sm font-semibold text-white shadow-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600']" >
                            {{row.inputName}}
                            <CheckCircleIcon class="-mr-0.5 h-5 w-5" aria-hidden="true" />
                        </button>
                    </td>

                    <td v-if="row.type === 'action' && row.inputType === 'number'"  class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right">
                        <div class="flex items-center justify-end gap-x-2">
                            <span v-if="currentValue(store, row) !== ''" class="rounded-md bg-gray-100 px-2 py-1 text-xs font-medium tabular-nums text-gray-500">now {{ currentValue(store, row) }}</span>
                            <input type="number" :step="row.step || '0.01'" v-model="row.inputValue" @keyup.enter="triggerAction(row)"
                                :placeholder="currentValue(store, row)"
                                class="w-20 rounded-md border border-gray-300 px-2 py-1.5 text-sm text-right tabular-nums text-gray-700 focus:border-indigo-500 focus:outline focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600" />
                            <button type="button" @click="triggerAction(row)" :class="[row.actionOngoing ? 'bg-gray-200' : colorTheme.bgColor, colorTheme.onHoverColor + ' inline-flex items-center rounded-md px-3 py-1.5 text-sm font-semibold text-white shadow-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600']">
                                {{ row.inputName }}
                            </button>
                        </div>
                    </td>

                    <td v-if="row.type === 'action' && row.inputType === 'toggle'"  class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right ">
                        <SwitchGroup as="div" class="flex" v-if="store.data[row.module]">
                            <dd class="flex flex-auto items-center justify-end">
                                <Switch @click="triggerAction(row)" :class="[store.data[row.module][row.statusMetricKey] ? 'bg-gray-200' : colorTheme.bgColor , 'flex w-8 cursor-pointer rounded-full p-px ring-1 ring-inset ring-gray-900/5 transition-colors duration-200 ease-in-out focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600']">
                                    <span aria-hidden="true" :class="[store.data[row.module][row.statusMetricKey] ? 'translate-x-0' : 'translate-x-3.5' , 'h-4 w-4 transform rounded-full bg-white shadow-sm ring-1 ring-gray-900/5 transition duration-200 ease-in-out']" />
                                </Switch>
                            </dd>
                        </SwitchGroup>
                    </td>
                <td v-if="row.type === 'metric' && store.data[row.module]"  :class="['text-gray-500 px-3 py-4 text-sm', isMultiline(store, row) ? 'whitespace-pre-wrap break-words text-left font-mono' : 'text-wrap break-all whitespace-nowrap text-right']">
                    <component v-if="valueType(store, row) === 'check'" :is="CheckIcon" class="h-6 w-6 inline-flex"></component>
                    <component v-if="valueType(store, row) === 'xmark'" :is="XMarkIcon" class="h-6 w-6 inline-flex"></component>
                    <span v-if="valueType(store, row) === 'none'">
                        {{ renderValue(store, row) }}
                    </span>
                </td>
            </tr>
        </tbody>
    </table>
</template>

<script setup>
    const props = defineProps(['title', 'rows', 'interval', 'store', 'colorTheme'])
    import { watch } from 'vue'
    import ActionService from "@/services/action_service.js"
    import { CheckIcon, XMarkIcon } from '@heroicons/vue/24/outline'
    import { Switch, SwitchGroup } from '@headlessui/vue'
    import { CheckCircleIcon } from '@heroicons/vue/20/solid'

    const title = props.title
    let rows = props.rows
    let store = props.store
    const colorTheme = props.colorTheme

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
        } else if(Array.isArray(value)){
            return value.join(", ")
        } else {
            return value
        }
    }

    const isMultiline = (store, metric) => {
        let value = store.data[metric.module][metric.key]
        return typeof(value) === "string" && value.indexOf("\n") !== -1
    }

    // Current value of the metric backing a number input, used as a placeholder
    // so the operator can see the live gain before overriding it.
    const currentValue = (store, row) => {
        if (!row.statusMetricKey || !store.data[row.module]) return ""
        let value = store.data[row.module][row.statusMetricKey]
        if (value == null) return ""
        return typeof(value) === "number" ? String(Math.round(value * 10000) / 10000) : String(value)
    }

    const triggerAction = (action) => {
        // Number inputs must carry a value, otherwise the backend action has
        // nothing to set — ignore empty submissions.
        if (action.inputType === 'number' && (action.inputValue === undefined || action.inputValue === null || action.inputValue === '')) {
            return
        }
        action.actionOngoing = true
        ActionService.createAction(action).then((response) => {
            action.actionOngoing = false
        })
    }

    // Seed each number input with the live value once it first arrives, so the
    // spinner steps from the current value rather than from 0. Only done once
    // per row — after that the field belongs to the operator.
    watch(
        () => store.data,
        () => {
            rows.forEach((row) => {
                if (row.type === 'action' && row.inputType === 'number' && !row.inputInitialized) {
                    let current = currentValue(store, row)
                    if (current !== '') {
                        row.inputValue = current
                        row.inputInitialized = true
                    }
                }
            })
        },
        { deep: true, immediate: true }
    )
</script>