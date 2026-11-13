import Config

# The CLI creates the host's vcan interfaces (`./ovcs can setup`).
config :cantastic, setup_can_interfaces: false, enable_socketcand: false
