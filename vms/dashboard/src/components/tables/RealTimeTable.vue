<template>
    <h2 class="text-base">{{ title }}</h2>
    <table class="min-w-full divide-y divide-gray-300">
        <tbody class="divide-y divide-gray-200 bg-white">
            <tr v-for="row in rows">
                <td class="whitespace-nowrap px-3 py-4 text-sm font-bold text-gray-600">{{ row.name }}</td>
                    <td v-if="row.type === 'action' && row.inputType == 'button'"  class="whitespace-nowrap px-3 py-4 text-sm text-gray-500 text-right content-end">
                        <button type="button" @click="triggerAction(row)" :class="[row.actionOngoing ? 'bg-gray-200' : colorTheme.bgColor, colorTheme.onHoverColor + ' inline-flex items-center gap-x-2 rounded-md px-3.5 py-2.5 text-sm font-semibold text-white shadow-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600']" >
                            {{row.inputName}}
                            <CheckCircleIcon class="-mr-0.5 h-5 w-5" aria-hidden="true" />
                        </button>
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
                <td v-if="row.type === 'metric' && store.data[row.module]"  class="text-gray-500 text-wrap break-all whitespace-nowrap px-3 py-4 text-sm text-right ">
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
        } else {
            return value
        }
    }

    const triggerAction = (action) => {
        action.actionOngoing = true
        ActionService.createAction(action).then((response) => {
            action.actionOngoing = false
        })
    }
</script>