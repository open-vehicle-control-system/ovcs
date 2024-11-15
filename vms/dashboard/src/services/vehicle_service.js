import axios from 'axios'

const fetch_vehicle = () => {
    return axios.get(import.meta.env.VITE_BASE_URL + "/api/vehicle", {});
  }

export default {
  fetch_vehicle
}