#! /bin/sh

# The call to fbv must be backgrounded, otherwise it blocks which means
# the Erlang VM won't boot

start_fb() {
    echo "Waiting for fb0 to be ready" > /dev/kmsg
    until [ -e /dev/fb0 ]
    do
        sleep 1
        echo "Still waiting" > /dev/kmsg
    done
    echo "Starting splash screen" > /dev/kmsg
    fbv /splash.jpeg
}
start_fb &