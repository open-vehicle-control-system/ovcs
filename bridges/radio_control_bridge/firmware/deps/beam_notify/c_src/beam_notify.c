#include <ctype.h>
#include <err.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <ei.h>

#define MIN_SEND_SIZE 8192

extern char **environ;

struct beam_notify_options {
    char *path;
    int encode_environment;
};

static void encode_string(ei_x_buff *buff, const char *str)
{
    // Encode strings as binaries so that we get Elixir strings
    // NOTE: the strings that we encounter here are expected to be ASCII to
    //       my knowledge
    ei_x_encode_binary(buff, str, strlen(str));
}

static int should_encode(const char *kv, const struct beam_notify_options *bn)
{
    if (!bn->encode_environment ||
        strncmp(kv, "BEAM_NOTIFY=", 12) == 0 ||
        strncmp(kv, "BEAM_NOTIFY_OPTIONS=", 20) == 0)
        return 0;
    else
        return 1;
}

static int count_environ_to_encode(const struct beam_notify_options *bn)
{
    char **p = environ;
    int n = 0;

    while (*p != NULL) {
        if (should_encode(*p, bn))
            n++;

        p++;
    }

    return n;
}

static void encode_env_kv(ei_x_buff *buff, const char *kv)
{
    char key[32];

    const char *equal = strchr(kv, '=');
    if (equal == NULL)
        return;

    size_t keylen = equal - kv;
    if (keylen >= sizeof(key))
        keylen = sizeof(key) - 1;
    memcpy(key, kv, keylen);
    key[keylen] = '\0';

    const char *value = equal + 1;

    encode_string(buff, key);
    encode_string(buff, value);
}

static void encode_environ(ei_x_buff *buff, const struct beam_notify_options *bn)
{
    int kv_to_encode = count_environ_to_encode(bn);
    ei_x_encode_map_header(buff, kv_to_encode);

    char **p = environ;
    while (*p != NULL && kv_to_encode > 0) {
        const char *kv = *p;

        if (should_encode(kv, bn)) {
            encode_env_kv(buff, kv);
            kv_to_encode--;
        }

        p++;
    }
}

static void encode_args(ei_x_buff *buff, int argc, char *argv[])
{
    ei_x_encode_list_header(buff, argc - 1);

    if (argc > 1) {
        int i;
        for (i = 1; i < argc; i++)
            encode_string(buff, argv[i]);

        ei_x_encode_empty_list(buff);
    }
}

static int inplace_string_to_argv(char *str, char **argv, int max_args)
{
    int argc = 0;
    char *c = str;
#define STATE_SPACE 0
#define STATE_TOKEN 1
#define STATE_QUOTED_TOKEN 2
    int state = STATE_SPACE;
    max_args--; // leave room for final null
    while (*c != '\0') {
        switch (state) {
        case STATE_SPACE:
            if (isspace(*c))
                break;
            else if (*c == '"') {
                *argv = c + 1;
                state = STATE_QUOTED_TOKEN;
            } else {
                *argv = c;
                state = STATE_TOKEN;
            }
            break;
        case STATE_TOKEN:
            if (isspace(*c)) {
                *c = '\0';
                argv++;
                argc++;
                state = STATE_SPACE;

                if (argc == max_args)
                    break;
            }
            break;
        case STATE_QUOTED_TOKEN:
            if (*c == '"') {
                *c = '\0';
                argv++;
                argc++;
                state = STATE_SPACE;

                if (argc == max_args)
                    break;
            }
            break;
        }
        c++;
    }

    if (state != STATE_SPACE)
        argc++;
    argv = NULL;

    return argc;
}

static int parse_arguments(int argc, char *argv[], struct beam_notify_options *bn)
{
    int opt;

    while ((opt = getopt(argc, argv, "ep:")) != -1) {
        switch (opt) {
        case 'e':
            bn->encode_environment = 1;
            break;
        case 'p':
            bn->path = optarg;
            break;
        default:
            return -1;
        }
    }

    return optind;
}

int main(int argc, char *argv[])
{
    struct beam_notify_options bn;
    memset(&bn, 0, sizeof(bn));

    // Parse options from $BEAM_NOTIFY_OPTIONS. If insufficient, check the commandline
    char *options = getenv("BEAM_NOTIFY_OPTIONS");
    if (options) {
        #define MAX_OPTIONS 3
        char *options_argv[MAX_OPTIONS + 1];
        options_argv[0] = ""; // "Program name"
        int option_argc = inplace_string_to_argv(options, &options_argv[1], MAX_OPTIONS);
        if (parse_arguments(option_argc + 1, options_argv, &bn) < 0)
            errx(EXIT_FAILURE, "$BEAM_NOTIFY_OPTIONS is corrupt or invalid");
    }
    if (bn.path == NULL) {
        int processed_argc = parse_arguments(argc, argv, &bn);
        if (processed_argc < 0)
            errx(EXIT_FAILURE, "Invalid arguments or $BEAM_NOTIFY_OPTIONS's value was lost");

        if (bn.path == NULL)
            errx(EXIT_FAILURE, "Missing socket path. Either use $BEAM_NOTIFY_OPTIONS or pass -p <path>");

        // Adjust argc, argv so that they start after our arguments
        argc = argc - processed_argc + 1;
        argv += processed_argc - 1;
        *argv[0] = '\0'; // new program name

    }

    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0)
        err(EXIT_FAILURE, "socket");

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, bn.path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == -1)
        err(EXIT_FAILURE, "connect");

    // Increase the send buffer if it's really small
    int send_size;
    socklen_t optlen = sizeof(send_size);
    int res = getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send_size, &optlen);
    if (res >= 0 && send_size < MIN_SEND_SIZE) {
        // Set buffer size
        send_size = MIN_SEND_SIZE;

        res = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send_size, sizeof(send_size));
        if (res < 0)
            warn("Couldn't increase buffer size to %d", send_size);
    }

    ei_x_buff buff;
    if (ei_x_new_with_version(&buff) < 0)
        err(EXIT_FAILURE, "ei_x_new_with_version");

    ei_x_encode_tuple_header(&buff, 2);

    encode_args(&buff, argc, argv);
    encode_environ(&buff, &bn);

    ssize_t rc = write(fd, buff.buff, buff.index);
    if (rc < 0)
        err(EXIT_FAILURE, "write");

    if (rc != buff.index)
        errx(EXIT_FAILURE, "write wasn't able to send %d chars all at once!", buff.index);

    close(fd);
    return 0;
}
