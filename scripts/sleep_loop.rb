100.times do |i|
    puts "ON n° #{i}"
    `cansend vcan2 570#8B20FF00`
    sleep 7
    puts "OFF n° #{i}"
    `cansend vcan2 570#0020FF00`
    sleep 2
end

