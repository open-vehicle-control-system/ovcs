<template>
  <div class="lg:fixed lg:inset-y-0 lg:flex lg:w-60">
    <!-- Sidebar component, swap this element with another sidebar if you like -->
    <div :class="colorTheme.bgColor + ' flex grow flex-col gap-y-5 overflow-y-auto px-6 pb-4'">
      <div class="flex h-16 shrink-0 items-center">
        <p class="text-xl text-white">{{ vehicleName }} VMS</p>
      </div>
      <nav class="flex flex-1 flex-col">
        <ul role="list" class="flex flex-1 flex-col gap-y-7">
          <li>
            <nav>
            <ul role="list" class="-mx-2 space-y-1">
              <li v-for="item in navigation" :key="item.name">
                <RouterLink :to="item.href" :active-class="colorTheme.hoverColor + ' text-white'" :class="colorTheme.onHoverColor+' '+colorTheme.textColor + ' hover:text-white group flex gap-x-3 rounded-md p-2 text-sm leading-6 font-semibold'">
                  <component :is="heroicons[item.icon]" active-class="text-white" :class="colorTheme.textColor + ' group-hover:text-white h-6 w-6 shrink-0'" aria-hidden="true" />
                  {{ item.name }}
                </RouterLink>
              </li>
            </ul>
            </nav>
          </li>
        </ul>
      </nav>
    </div>
  </div>

  <div class="lg:pl-60">
    <main class="py-10">
      <div class="px-4 sm:px-6 lg:px-8">
        <RouterView :key="$route.path" :colorTheme="colorTheme"/>
      </div>
    </main>
  </div>
</template>

<script setup>
  import { RouterView, RouterLink } from 'vue-router'
  import VehiculeService from "./services/vehicle_service.js"

  import { ref } from 'vue'
  import * as heroicons from '@heroicons/vue/24/outline'
  import { color } from 'echarts';

  let navigation = ref([])
  let vehicleName = ref()
  let colorTheme = ref({
    bgColor: "",
    hoverColor: "",
    onHoverColor: "",
    textColor: ""
  })

  VehiculeService.getVehicle().then((response) => {
    vehicleName.value = response.data.data.attributes.name
    colorTheme.value.bgColor = "bg-"+response.data.data.attributes.mainColor+"-600"
    colorTheme.value.hoverColor = "bg-"+response.data.data.attributes.mainColor+"-700"
    colorTheme.value.onHoverColor = "hover:bg-"+response.data.data.attributes.mainColor+"-700"
    colorTheme.value.textColor = "text-"+response.data.data.attributes.mainColor+"-200"
  });

  VehiculeService.getVehiclePages().then((response) => {
    let pages = response.data.data
    pages.forEach((page) => {
      let href = pages.indexOf(page) === 0 ? "/" : "/" + page.id
      let icon = page.attributes.icon || "GlobeAltIcon"
      navigation.value.push(
        {name: page.attributes.name, href: href, icon: icon}
      );
    })
    navigation.value.push({ name: 'Network', href: '/network', icon: "GlobeAltIcon" });
  });

</script>