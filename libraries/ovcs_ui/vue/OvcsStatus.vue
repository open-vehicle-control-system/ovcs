<script setup>
// A coloured dot followed by its label (the default slot).
defineProps({
  tone: {
    type: String,
    default: 'muted',
    validator: (tone) => ['ok', 'warn', 'error', 'muted'].includes(tone)
  }
})
</script>

<template>
  <span class="ovcs-status" :class="tone === 'muted' ? null : `ovcs-status--${tone}`"><slot /></span>
</template>
