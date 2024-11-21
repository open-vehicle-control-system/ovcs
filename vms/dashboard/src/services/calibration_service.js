import axios from 'axios'

const post_calibration = (value) => {
    return axios.post(import.meta.env.VITE_BASE_URL + "/api/calibration", value);
  }

export default {
  post_calibration,
}