<template>
    <div class="table text-3xl text-white p-10">
        <div :class="[store.selectedGear == 'parking' ? 'bg-gray-700 opacity-99' : '', 'table-row']">
            <span class="h-20 w-20 leading-5 align-middle table-cell text-center">P</span>
        </div>
        <div :class="[store.selectedGear == 'reverse' ? 'bg-gray-700 opacity-99 rounded-3xl' : '', 'table-row']">
            <span class="h-20 w-20 leading-5 align-middle table-cell text-center">R</span>
        </div>
        <div :class="[store.selectedGear == 'neutral' ? 'bg-gray-700 opacity-99 rounded-3xl' : '', 'table-row']">
            <span class="h-20 w-20 leading-5 align-middle table-cell text-center">N</span>
        </div>
        <div :class="[store.selectedGear == 'drive' ? 'bg-gray-700 opacity-99 rounded-3xl' : '', 'table-row']">
            <span class="h-20 w-20 leading-5 align-middle table-cell text-center">D</span>
        </div>
    </div>
</template>

<script setup>
const props = defineProps(["store"])
const store = props.store
</script>