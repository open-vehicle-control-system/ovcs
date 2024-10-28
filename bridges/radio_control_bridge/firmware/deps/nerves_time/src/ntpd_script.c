#include <err.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <ei.h>

static void encode_string(ei_x_buff *buff, const char *str)
{
    // Encode strings as binaries so that we get Elixir strings
    // NOTE: the strings that we encounter here are expected to be ASCII to
    //       my knowledge
    ei_x_encode_binary(buff, str, strlen(str));
}

static int32_t getenv_int32(const char *key, int32_t default_value)
{
    const char *result = getenv(key);
    return result != NULL ? strtol(result, NULL, 0) : default_value;
}

static double getenv_double(const char *key, double default_value)
{
    const char *result = getenv(key);
    return result != NULL ? strtod(result, NULL) : default_value;
}

static void send_ntpd_info(int fd, const char *argv1)
{
    // Get the information provided by ntpd
    int32_t freq_drift_ppm = getenv_int32("freq_drift_ppm", 0);
    double offset = getenv_double("offset", 0);
    int32_t stratum = getenv_int32("stratum", 16);
    int32_t poll_interval = getenv_int32("poll_interval", 0);

    // Build an Erlang term
    ei_x_buff buff;
    if (ei_x_new_with_version(&buff) < 0)
        err(EXIT_FAILURE, "ei_x_new_with_version");


    ei_x_encode_tuple_header(&buff, 5);
    encode_string(&buff, argv1);
    ei_x_encode_long(&buff, freq_drift_ppm);
    ei_x_encode_double(&buff, offset);
    ei_x_encode_long(&buff, stratum);
    ei_x_encode_long(&buff, poll_interval);

    // Send it
    ssize_t rc = write(fd, buff.buff, buff.index);
    if (rc < 0)
        err(EXIT_FAILURE, "write");

    if (rc != buff.index)
        errx(EXIT_FAILURE, "write wasn't able to send %d chars all at once!", buff.index);
}

int main(int argc, char *argv[])
{
    if (argc < 2)
        errx(EXIT_FAILURE, "Expecting on argument from ntpd.");

    const char *socket_path = getenv("SOCKET_PATH");
    if (!socket_path)
        errx(EXIT_FAILURE, "SOCKET_PATH needs to be defined");

    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0)
        err(EXIT_FAILURE, "socket");

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == -1)
        err(EXIT_FAILURE, "connect");

    send_ntpd_info(fd, argv[1]);

    close(fd);
    exit(EXIT_SUCCESS);
}
