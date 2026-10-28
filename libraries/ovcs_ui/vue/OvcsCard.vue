<script setup>
// A bordered block on the surface colour; a link when `href` is set.
defineProps({
  href: { type: String, default: null },
  as: { type: String, default: 'div' }
})
</script>

<template>
  <a v-if="href" :href="href" class="ovcs-card"><slot /></a>
  <component :is="as" v-else class="ovcs-card"><slot /></component>
</template>
