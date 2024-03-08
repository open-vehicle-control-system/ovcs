#!ruby

def cansend(network, id, raw_data) 
    10.times do 
        `cansend #{network} #{id}##{raw_data}`
    end
end
max = "%.2x" % 255

min = "%.2x" % 1

if ARGV[0] == "calibration"
    cansend("vcan0", "200" , max + "00" + min + "00" + min + "00" + "03")   # car_controls_status
    sleep 2
    cansend("vcan0", "200" , max + "00" + max + "00" + max + "00" + "03")   # car_controls_status
elsif ARGV[0] == "start"
    cansend("vcan2", "570" , "8B20FF00") # Start ignition with key
    sleep 2
    cansend("vcan0", "101" , "010100") # contactors_status
    cansend("vcan0", "111" , "01")  # vms_relays_status
    cansend("vcan0", "200" , min + "00" + min + "00" + min + "00" + "00")
elsif ARGV[0] == "throttle"
    if ARGV[1] == "R"
        gear = "02"
    elsif ARGV[1] == "D"
        gear = "00"
    else 
        raise "Invalid gear"
    end
    value = ARGV[2] || 125
    hex = "%.2x" % value
    cansend("vcan0", "200" , max + "00" + hex + "00" + hex + "00" + gear)
elsif ARGV[0] == "stop"
    cansend("vcan2", "570" , "0020FF00") # Start ignition with key
    sleep 2
    cansend("vcan0", "101" , "000000") # contactors_status
    cansend("vcan0", "111" , "00")  # vms_relays_status
    cansend("vcan0", "200" , min + "00" + min + "00" + min + "00" + "03")
end




