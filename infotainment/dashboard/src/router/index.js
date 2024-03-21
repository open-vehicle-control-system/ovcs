import { createRouter, createWebHistory } from 'vue-router'
import DebugView from '../views/DebugView.vue'
import LaunchpadView from '../views/LaunchpadView.vue'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/debug',
      name: 'debug',
      component: DebugView
    },
    {
      path: '/',
      name: 'home',
      component: LaunchpadView
    },
  ]
})

export default router
