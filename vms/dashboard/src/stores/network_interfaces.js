import { ref, computed } from 'vue'
import { defineStore } from 'pinia'

export const useNetworkInterfaces = defineStore('networkInterfaces', {
    state: () => ({
        data: [],
        statistics: {}
    }),
    getters: {
        previousBytesExchanged(state){
            return (ifindex) => {
                if( state.statistics[ifindex] ){
                    return state.statistics[ifindex]["bytes"]
                } else {
                    setupStatisticsForInterface(ifindex);
                    return 0;
                }
            }
        },
        interfaceLoad(state){
            return (ifindex) => {
                if( state.statistics[ifindex] ){
                    return state.statistics[ifindex]["load"]
                } else {
                    state.setupStatisticsForInterface(ifindex);
                    return 0;
                }
            }
        }
    },
    actions: {
        setupStatisticsForInterface(ifindex){
            this.statistics[ifindex] = {};
            this.statistics[ifindex]["bytes"] = 0;
            this.statistics[ifindex]["load"] = 0;
        },
        computeInterfacesLoad(){
            for(let i = 0; i < this.data.length; i++){
                let networkInterface = this.data[i].attributes.statistics;
                if(networkInterface.linkinfo && networkInterface.linkinfo.info_data && networkInterface.linkinfo.info_data.bittiming){
                    if(this.statistics[networkInterface.ifindex] == undefined){
                        this.setupStatisticsForInterface(networkInterface.ifindex);
                    };
                    let bitrate = networkInterface.linkinfo.info_data.bittiming.bitrate;
                    let bytes_exchanged = networkInterface.stats64.rx.bytes;
                    let previous_bytes_exchanged = this.previousBytesExchanged(networkInterface.ifindex);
                    let load = ((bytes_exchanged - previous_bytes_exchanged)*8*100 / (bitrate));
                    this.statistics[networkInterface.ifindex]["load"] = Math.trunc(load);
                    this.statistics[networkInterface.ifindex]["bytes"] = bytes_exchanged;
                }
            }
        }
    }
})