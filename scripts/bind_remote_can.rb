#!ruby
remote = ARGV[0]
mappings =  ARGV[1..-1]
if remote.nil?  || mappings.nil? 
    puts "invalid arguments, please use ./bind_remote_can.rb nerves.local can0,vcan0 vcan1,vcan1 vcan2,vcan2"
    exit
end

pids = mappings.each do |mapping|
    puts mapping
    spawn("socketcandcl -v -i #{mapping} -s #{remote}")
end
Process.waitall