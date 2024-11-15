import { createRouter, createWebHistory } from 'vue-router'
import HomeView from '../views/HomeView.vue'
import NetworksView from '../views/NetworksView.vue'
import ThrottleView from '../views/ThrottleView.vue'
import SteeringView from '../views/SteeringView.vue'
import BrakingView from '../views/BrakingView.vue'
import GearView from '../views/GearView.vue'
import EnergyView from '../views/EnergyView.vue'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/',
      name: 'home',
      component: HomeView
    },
    {
      path: '/networks',
      name: 'networks',
      component: NetworksView
    },
    {
      path: '/throttle',
      name: 'throttle',
      component: ThrottleView
    },
    {
      path: '/steering',
      name: 'steering',
      component: SteeringView
    },
    {
      path: '/braking',
      name: 'braking',
      component: BrakingView
    },
    {
      path: '/gear',
      name: 'gear',
      component: GearView
    },
    {
      path: '/energy',
      name: 'energy',
      component: EnergyView
    }
  ]
})

export default router
