<script setup>
// A row that lights up while `live` and fades back after.
defineProps({
  live: { type: Boolean, default: false },
  as: { type: String, default: 'div' }
})
</script>

<template>
  <component :is="as" class="ovcs-row" :class="{ 'ovcs-row--live': live }"><slot /></component>
</template>
