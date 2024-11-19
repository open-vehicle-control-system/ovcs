import axios from 'axios'


const getVehicle = () => {
    return axios.get(import.meta.env.VITE_BASE_URL + "/api/vehicle", {});
}

const getVehiclePages = () => {
    return axios.get(import.meta.env.VITE_BASE_URL + "/api/vehicle/pages", {});
}

const getVehiclePageBlocks = (id) => {
    return axios.get(import.meta.env.VITE_BASE_URL + "/api/vehicle/pages/"+id+"/blocks", {});
}

export default {
    getVehicle,
    getVehiclePages,
    getVehiclePageBlocks
}