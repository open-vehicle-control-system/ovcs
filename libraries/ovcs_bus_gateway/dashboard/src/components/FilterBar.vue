<script setup>
import { OvcsBadge, OvcsDot, OvcsHeader, OvcsStatus } from '@ovcs/ui/vue'
import { ref } from 'vue'
import { LIVE_MS } from '../format'

defineProps({
  modelValue: { type: String, required: true },
  status: { type: String, required: true },
  count: { type: Number, required: true }
})
defineEmits(['update:modelValue'])

const input = ref(null)
defineExpose({ focus: () => input.value?.focus() })
</script>

<template>
  <OvcsHeader>
    <div class="mx-auto flex max-w-5xl flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3">
      <h1 class="text-lg font-semibold">OVCS Bus Gateway</h1>
      <OvcsStatus v-if="status === 'live'" tone="ok" class="text-sm">Live · {{ count }} signals</OvcsStatus>
      <OvcsStatus v-else-if="status === 'connecting'" class="text-sm">Connecting…</OvcsStatus>
      <OvcsStatus v-else tone="error" class="text-sm">Disconnected, retrying</OvcsStatus>
      <input
        ref="input"
        :value="modelValue"
        type="search"
        placeholder="Filter by node, source or name  ( / )"
        aria-label="Filter signals"
        class="w-full rounded border border-ovcs-border bg-ovcs-bg px-3 py-1.5 text-sm text-ovcs-text placeholder:text-ovcs-muted focus:border-ovcs-accent focus:outline-none sm:ml-auto sm:w-80"
        @input="$emit('update:modelValue', $event.target.value)"
      />
    </div>
    <p class="mx-auto max-w-5xl px-4 pb-2 text-xs text-ovcs-muted">
      <OvcsDot on class="align-middle" /> value changed in the last {{ LIVE_MS / 1000 }} s ·
      <OvcsBadge tone="warn">stale</OvcsBadge>
      no longer received by the gateway · faint “Published” times are current
    </p>
  </OvcsHeader>
</template>
