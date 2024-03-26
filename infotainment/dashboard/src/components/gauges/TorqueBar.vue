<script setup>
import { ref } from 'vue'

const props = defineProps(["torque"])

const item = ref({power: 0, charge: 100})


const updateTorque = function(torque){
  computeCharge(torque)
  computePower(torque)
}

const computePower = function(torque){
  if(torque >= 0){
    item.value.power = (torque/220)*100
  } else {
    item.value.power =  0
  }
}

const computeCharge = function(torque){
  if(torque < 0 ){
    item.value.charge = 100-((-torque/50)*100)
  } else {
    item.value.charge = 100
  }
}

defineExpose({
  updateTorque
})

</script>

<template>
  <div class="w-full p-16">
    <div class="mb-8">
      <div class="bg-stroke bg-green-400 relative h-6 w-3/12 inline-block">
        <div
          class="bg-gray-700 absolute top-0 left-0 h-full"
          :style="{ width: `${item.charge}%` }"
        ></div>

      </div>
      <div class="bg-stroke bg-gray-700 relative h-6 w-8/12 inline-block ml-1">
        <div
          class="bg-cyan-400 absolute top-0 left-0 h-full"
          :style="{ width: `${item.power}%` }"
        ></div>

      </div>
      <span class="text-gray-400 mt-20 text-lg">Charge</span>
      <span class="text-gray-400 ml-7 text-lg">Power</span>
    </div>
  </div>
</template>