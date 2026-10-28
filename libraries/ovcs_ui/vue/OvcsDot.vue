<script setup>
// A small accent dot, shown while `on`; it keeps its space when off so rows stay aligned.
defineProps({
  on: { type: Boolean, default: false }
})
</script>

<template>
  <span class="ovcs-dot" :class="{ 'ovcs-dot--on': on }" aria-hidden="true" />
</template>
