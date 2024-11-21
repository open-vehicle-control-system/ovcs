<template>
  <div class="lg:fixed lg:inset-y-0 lg:flex lg:w-60">
    <!-- Sidebar component, swap this element with another sidebar if you like -->
    <div class="flex grow flex-col gap-y-5 overflow-y-auto bg-indigo-600 px-6 pb-4">
      <div class="flex h-16 shrink-0 items-center">
        <p class="text-xl text-white">{{ vehicleName }} VMS</p>
      </div>
      <nav class="flex flex-1 flex-col">
        <ul role="list" class="flex flex-1 flex-col gap-y-7">
          <li>
            <nav>
            <ul role="list" class="-mx-2 space-y-1">
              <li v-for="item in navigation" :key="item.name">
                <RouterLink :to="item.href" active-class="bg-indigo-700 text-white" class="text-indigo-200 hover:text-white hover:bg-indigo-700 group flex gap-x-3 rounded-md p-2 text-sm leading-6 font-semibold">
                  <component :is="item.icon" active-class="text-white" class="text-indigo-200 group-hover:text-white h-6 w-6 shrink-0" aria-hidden="true" />
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
        <RouterView :key="$route.path"/>
      </div>
    </main>
  </div>
</template>

<script setup>
  import { RouterView, RouterLink } from 'vue-router'
  import { useRouter } from 'vue-router'
  import DynamicView from './views/DynamicView.vue'
  import VehiculeService from "./services/vehicle_service.js"

  import { ref } from 'vue'
  import {
    HomeIcon,
    GlobeAltIcon,
    AdjustmentsVerticalIcon,
  } from '@heroicons/vue/24/outline'

  let router = useRouter()
  let navigation = ref([
    { name: 'Dashboard', href: '/', icon: HomeIcon },
    { name: 'Network', href: '/network', icon: GlobeAltIcon },
    { name: 'Throttle', href: '/throttle', icon: AdjustmentsVerticalIcon },
    { name: 'Steering', href: '/steering', icon: AdjustmentsVerticalIcon },
  ])

  let vehicleName = ref()
  let refreshInterval = ref()
  let style = ref()

  VehiculeService.getVehicle().then((response) => {
    vehicleName.value = response.data.data.attributes.name
    refreshInterval.value = response.data.data.attributes.refreshInterval
    style.value = "background-color: " + response.data.data.attributes.mainColor
  });

  VehiculeService.getVehiclePages().then((response) => {
    response.data.data.forEach((page) => {
      let href = "/" + page.id;
      let icon = eval(page.attributes.icon) || GlobeAltIcon
      navigation.value.push(
        {name: page.attributes.name, href: href, icon: icon}
      );
      router.addRoute({
        component: DynamicView,
        name: page.id,
        path: href,
        props: {
          title: page.attributes.name,
          id: page.id,
          refreshInterval: refreshInterval
        }
      })
    });
  });

</script>