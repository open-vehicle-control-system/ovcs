<template>
  <figure class="overflow-hidden rounded-lg bg-white shadow">
    <div class="flex aspect-video items-center justify-center bg-gray-900">
      <img
        v-if="frame"
        :src="frame"
        :alt="`${stream} preview`"
        class="h-full w-full object-contain"
        @load="ack"
        @error="ack"
      />
      <p v-else class="text-sm text-gray-400">No frame</p>
    </div>
    <figcaption class="px-4 py-2 text-sm font-medium capitalize text-gray-700">{{ stream }}</figcaption>
  </figure>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue'

const props = defineProps({
  stream: { type: String, required: true },
  socket: { type: Object, required: true }
})

const frame = ref(null)
let channel = null

// The server sends the next frame only once this one is shown.
const ack = () => channel.push('ack', {})

onMounted(() => {
  channel = props.socket.channel(`preview:${props.stream}`, {})
  channel.on('frame', ({ jpeg }) => {
    const source = `data:image/jpeg;base64,${jpeg}`
    // An unchanged src fires no load event.
    if (source === frame.value) ack()
    frame.value = source
  })
  channel.join()
})

onUnmounted(() => {
  if (channel) channel.leave()
})
</script>
