<template>
  <ul class="space-y-1 font-mono text-xs">
    <li v-for="entry in entries" :key="entry.key">
      <template v-if="isNested(entry.value)">
        <span class="text-gray-500">{{ entry.key }}</span>
        <SettingsTree :settings="entry.value" class="ml-4 border-l border-gray-200 pl-3" />
      </template>
      <template v-else>
        <span class="text-gray-500">{{ entry.key }}:</span>
        <span class="ml-1 text-gray-900">{{ format(entry.value) }}</span>
      </template>
    </li>
  </ul>
</template>

<script setup>
import { computed } from 'vue'

defineOptions({ name: 'SettingsTree' })

const props = defineProps({
  settings: { type: [Object, Array], required: true }
})

const isNested = (value) => value !== null && typeof value === 'object' && Object.keys(value).length > 0

const format = (value) => (Array.isArray(value) ? '[]' : JSON.stringify(value))

const entries = computed(() =>
  Array.isArray(props.settings)
    ? props.settings.map((value, index) => ({ key: value?.name ?? String(index), value }))
    : Object.entries(props.settings).map(([key, value]) => ({ key, value }))
)
</script>
