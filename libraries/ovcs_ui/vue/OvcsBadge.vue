<script setup>
// A short uppercase label (the default slot).
defineProps({
  tone: {
    type: String,
    default: 'neutral',
    validator: (tone) => ['neutral', 'warn', 'error'].includes(tone)
  }
})
</script>

<template>
  <span class="ovcs-badge" :class="tone === 'neutral' ? null : `ovcs-badge--${tone}`"><slot /></span>
</template>
