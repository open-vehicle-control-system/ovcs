import axios from 'axios'


const postSteeringAngleSensorCalibration = () => {
    return axios.post(import.meta.env.VITE_BASE_URL + "/api/steering-angle-sensor-calibration", {});
  }

export default {
  postSteeringAngleSensorCalibration
}