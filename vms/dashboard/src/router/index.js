import { createRouter, createWebHistory } from 'vue-router'
import HomeView from '../views/HomeView.vue'
import NetworkView from '../views/NetworkView.vue'
import ThrottleView from '../views/ThrottleView.vue'
import SteeringView from '../views/SteeringView.vue'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/',
      name: 'home',
      component: HomeView
    },
    {
      path: '/network',
      name: 'network',
      component: NetworkView
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
    }
  ]
})

export default router
