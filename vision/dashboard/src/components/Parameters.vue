<template>
  <div class="space-y-4">
    <fieldset v-for="group in groups" :key="group.prefix" :data-group="group.prefix" class="space-y-2">
      <legend class="font-mono text-xs text-gray-500">{{ group.prefix }}</legend>
      <label
        v-for="parameter in group.parameters"
        :key="parameter.name"
        :data-parameter="parameter.name"
        :title="parameter.description"
        class="grid grid-cols-[10rem_8rem_1fr] items-center gap-3 text-sm"
      >
        <span class="font-mono text-xs text-gray-700">{{ parameter.name.slice(group.prefix.length + 1) }}</span>
        <input
          v-if="parameter.type === 'bool'"
          type="checkbox"
          :checked="values[parameter.name]"
          class="h-4 w-4"
          @change="commit(parameter, $event.target.checked, $event.target)"
        />
        <select
          v-else-if="parameter.values"
          :value="values[parameter.name]"
          class="rounded border-gray-300 text-sm"
          @change="commit(parameter, $event.target.value, $event.target)"
        >
          <option v-for="option in parameter.values" :key="option" :value="option">{{ option }}</option>
        </select>
        <input
          v-else
          type="number"
          :value="values[parameter.name]"
          :min="parameter.range?.[0]"
          :max="parameter.range?.[1]"
          :step="parameter.type === 'integer' ? 1 : 0.01"
          class="rounded border-gray-300 text-sm"
          @change="commit(parameter, $event.target.value, $event.target)"
        />
        <span class="text-xs text-red-700">{{ errors[parameter.name] }}</span>
      </label>
    </fieldset>
  </div>
</template>

<script setup>
import { computed, reactive } from 'vue'

const props = defineProps({
  parameters: { type: Array, required: true },
  // (name, value) => Promise of the value in force, rejected with the reason it was refused
  save: { type: Function, required: true }
})

const values = reactive(Object.fromEntries(props.parameters.map((p) => [p.name, p.value])))
const errors = reactive({})

const groups = computed(() => {
  const byPrefix = new Map()
  for (const parameter of props.parameters.filter((p) => !p.read_only)) {
    const prefix = parameter.name.slice(0, parameter.name.lastIndexOf('.'))
    if (!byPrefix.has(prefix)) byPrefix.set(prefix, [])
    byPrefix.get(prefix).push(parameter)
  }
  return [...byPrefix].map(([prefix, parameters]) => ({ prefix, parameters }))
})

const parse = (type, raw) => {
  if (type === 'integer') return Number.parseInt(raw, 10)
  if (type === 'double') return Number.parseFloat(raw)
  return raw
}

async function commit(parameter, raw, element) {
  const value = parse(parameter.type, raw)
  try {
    values[parameter.name] = await props.save(parameter.name, value)
    delete errors[parameter.name]
  } catch (error) {
    errors[parameter.name] = error.message
    if (element.type === 'checkbox') element.checked = values[parameter.name]
    else element.value = values[parameter.name]
  }
}
</script>
