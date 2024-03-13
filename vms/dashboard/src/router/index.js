import { createRouter, createWebHistory } from 'vue-router'
import HomeView from '../views/HomeView.vue'
import NetworkView from '../views/NetworkView.vue'
import CarControlsView from '../views/CarControlsView.vue'

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
      path: '/car-controls',
      name: 'car controls',
      component: CarControlsView
    }
  ]
})

export default router
