/* yvy-server.c — Robust single-threaded HTTP frontend server for Yvy
 *
 * Serves static files (React build) + proxies /api paths to Lua backend.
 * Nginx handles SSL termination in front of this server.
 *
 * Improvements over original:
 *   - sendfile() on Linux for zero-copy static file serving
 *   - Client socket timeouts (recv/send) to prevent hung connections
 *   - /health endpoint for systemd watchdog auto-restart
 *   - Buffer overflow protection with snprintf bounds
 *   - Proper signal handling with socket cleanup
 *   - Connection: close enforced (single-threaded, no keep-alive)
 *   - Path traversal protection
 *   - SIGPIPE ignored on Linux
 *
 * Linux:  gcc -o yvy-server yvy-server.c
 * Windows (MinGW): gcc -o yvy-server.exe yvy-server.c -lws2_32
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE  /* for memmem() on Linux */
#endif

#ifdef _WIN32
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #include <io.h>
    #include <fcntl.h>
    typedef int socklen_t;
    #define CLOSESOCK closesocket
    /* Windows open flags */
    #ifndef O_RDONLY
    #define O_RDONLY _O_RDONLY
    #endif
    #ifndef O_BINARY
    #define O_BINARY _O_BINARY
    #endif
#else
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <unistd.h>
    #include <sys/sendfile.h>
    #include <fcntl.h>
    #define CLOSESOCK close
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/stat.h>
#include <stdint.h>
#include <errno.h>

/* ── Configuration ──────────────────────────────────────────────────────── */

#define PORT_DEFAULT    5001
#define BACKEND_PORT    5000
#define BUFFER_SIZE     65536
#define MAX_HEADERS     50
#define MAX_PATH_LEN    512
#define MAX_METHOD_LEN  16
#define MAX_HEADER_NAME 128
#define MAX_HEADER_VAL  512
#define CLIENT_TIMEOUT  5       /* seconds for recv/send timeouts */
#define BACKEND_TIMEOUT 30      /* seconds for backend proxy timeout */
#define MAX_REQUEST_SIZE 65536  /* max bytes to read from a client */
#define LISTEN_BACKLOG  128

static const char *STATIC_DIR  = "../frontend/build";
static const char *BACKEND_HOST = "127.0.0.1";
static const char *API_KEY     = "";
static int PORT                = PORT_DEFAULT;

/* ── Portable memmem (not available on Windows) ─────────────────────────── */

#ifdef _WIN32
/* Portable memmem implementation for Windows */
static const void *memmem(const void *haystack, size_t haystack_len,
                           const void *needle, size_t needle_len) {
    if (needle_len == 0) return haystack;
    if (needle_len > haystack_len) return NULL;
    const char *hs = (const char *)haystack;
    const char *ne = (const char *)needle;
    for (size_t i = 0; i <= haystack_len - needle_len; i++) {
        if (hs[i] == ne[0] && memcmp(hs + i, ne, needle_len) == 0) {
            return hs + i;
        }
    }
    return NULL;
}
#endif

/* ── Global state ───────────────────────────────────────────────────────── */

static volatile sig_atomic_t g_running = 1;
static int g_server_fd = -1;

/* ── MIME types ─────────────────────────────────────────────────────────── */

static const char *get_mime_type(const char *path) {
    const char *ext = strrchr(path, '.');
    if (!ext) return "application/octet-stream";

    if (strcmp(ext, ".html") == 0 || strcmp(ext, ".htm") == 0) return "text/html";
    if (strcmp(ext, ".css") == 0)  return "text/css";
    if (strcmp(ext, ".js") == 0)   return "application/javascript";
    if (strcmp(ext, ".json") == 0)  return "application/json";
    if (strcmp(ext, ".png") == 0)   return "image/png";
    if (strcmp(ext, ".jpg") == 0 || strcmp(ext, ".jpeg") == 0) return "image/jpeg";
    if (strcmp(ext, ".gif") == 0)   return "image/gif";
    if (strcmp(ext, ".svg") == 0)   return "image/svg+xml";
    if (strcmp(ext, ".ico") == 0)   return "image/x-icon";
    if (strcmp(ext, ".woff") == 0)  return "font/woff";
    if (strcmp(ext, ".woff2") == 0)  return "font/woff2";
    if (strcmp(ext, ".txt") == 0)   return "text/plain";
    if (strcmp(ext, ".map") == 0)   return "application/json";
    if (strcmp(ext, ".webp") == 0)  return "image/webp";
    return "application/octet-stream";
}

/* ── Utility: set socket recv/send timeout ──────────────────────────────── */

static void set_socket_timeout(int fd, int seconds) {
#ifdef _WIN32
    DWORD tv = (DWORD)(seconds * 1000);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv, sizeof(tv));
#else
    struct timeval tv = { .tv_sec = seconds, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#endif
}

/* ── Send HTTP response ─────────────────────────────────────────────────── */

static void send_response(int client, int status, const char *status_text,
                          const char *content_type, const char *body, size_t body_len) {
    char header[2048];
    int header_len = snprintf(header, sizeof(header),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "X-Content-Type-Options: nosniff\r\n"
        "X-Frame-Options: DENY\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "\r\n",
        status, status_text, content_type, body_len);

    send(client, header, (size_t)header_len, 0);
    if (body && body_len > 0) {
        /* Send body in chunks to handle partial sends */
        size_t sent = 0;
        while (sent < body_len) {
            ssize_t n = send(client, body + sent, body_len - sent, 0);
            if (n <= 0) break;
            sent += (size_t)n;
        }
    }
}

/* ── Send static file using sendfile() on Linux ─────────────────────────── */

static void serve_static(int client, const char *path) {
    char file_path[MAX_PATH_LEN + 256];

    /* Default to index.html for root or SPA routes */
    if (strcmp(path, "/") == 0 || strchr(path, '.') == NULL) {
        snprintf(file_path, sizeof(file_path), "%s/index.html", STATIC_DIR);
    } else {
        /* Prevent path traversal: reject any .. in path */
        if (strstr(path, "..") != NULL) {
            const char *err = "{\"error\":\"Forbidden\"}";
            send_response(client, 403, "Forbidden", "application/json", err, strlen(err));
            return;
        }
        snprintf(file_path, sizeof(file_path), "%s%s", STATIC_DIR, path);
    }

    /* Open file and get size */
    int file_fd = open(file_path, O_RDONLY
#ifdef _WIN32
        | O_BINARY
#endif
    );
    if (file_fd < 0) {
        /* Try index.html as fallback for SPA */
        if (strcmp(path, "/") != 0 && strchr(path, '.') != NULL) {
            snprintf(file_path, sizeof(file_path), "%s/index.html", STATIC_DIR);
            file_fd = open(file_path, O_RDONLY
#ifdef _WIN32
                | O_BINARY
#endif
            );
        }

        if (file_fd < 0) {
            const char *err = "{\"error\":\"Not found\"}";
            send_response(client, 404, "Not Found", "application/json", err, strlen(err));
            return;
        }
    }

    /* Get file size */
    struct stat st;
    if (fstat(file_fd, &st) < 0) {
        close(file_fd);
        const char *err = "{\"error\":\"Internal server error\"}";
        send_response(client, 500, "Internal Server Error", "application/json", err, strlen(err));
        return;
    }
    size_t file_size = (size_t)st.st_size;
    const char *mime = get_mime_type(file_path);

    /* Send header */
    char header[1024];
    int header_len = snprintf(header, sizeof(header),
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "X-Content-Type-Options: nosniff\r\n"
        "Cache-Control: public, max-age=3600\r\n"
        "\r\n",
        mime, file_size);

    send(client, header, (size_t)header_len, 0);

    /* Send file body — use sendfile() on Linux for zero-copy */
#ifdef __linux__
    off_t offset = 0;
    ssize_t sent = sendfile(client, file_fd, &offset, file_size);
    /* sendfile may not send everything in one call on large files */
    while (sent > 0 && (size_t)offset < file_size) {
        sent = sendfile(client, file_fd, &offset, file_size - (size_t)offset);
    }
#else
    /* Fallback: read + send in chunks */
    {
        char buf[32768];
        ssize_t n;
        while ((n = read(file_fd, buf, sizeof(buf))) > 0) {
            size_t to_send = (size_t)n;
            size_t total_sent = 0;
            while (total_sent < to_send) {
                ssize_t s = send(client, buf + total_sent, to_send - total_sent, 0);
                if (s <= 0) break;
                total_sent += (size_t)s;
            }
        }
    }
#endif

    close(file_fd);
}

/* ── Proxy request to Lua backend ───────────────────────────────────────── */

static void proxy_to_backend(int client, const char *method, const char *path,
                              char headers[][2][MAX_HEADER_VAL], int num_headers,
                              const char *body, size_t body_len) {
    /* Connect to backend */
    int backend_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (backend_fd < 0) {
        const char *err = "{\"error\":\"Backend unavailable\"}";
        send_response(client, 502, "Bad Gateway", "application/json", err, strlen(err));
        return;
    }

    set_socket_timeout(backend_fd, BACKEND_TIMEOUT);

    struct sockaddr_in backend_addr;
    memset(&backend_addr, 0, sizeof(backend_addr));
    backend_addr.sin_family = AF_INET;
    backend_addr.sin_port = htons(BACKEND_PORT);
    backend_addr.sin_addr.s_addr = inet_addr(BACKEND_HOST);

    if (connect(backend_fd, (struct sockaddr*)&backend_addr, sizeof(backend_addr)) < 0) {
        CLOSESOCK(backend_fd);
        const char *err = "{\"error\":\"Backend connection failed\"}";
        send_response(client, 502, "Bad Gateway", "application/json", err, strlen(err));
        return;
    }

    /* Build backend request */
    char request[BUFFER_SIZE];
    int req_len = snprintf(request, sizeof(request),
        "%s %s HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "Connection: close\r\n",
        method, path, BACKEND_HOST, BACKEND_PORT);

    /* Copy relevant headers and add API key */
    for (int i = 0; i < num_headers; i++) {
        const char *name = headers[i][0];
        const char *value = headers[i][1];

        /* Skip hop-by-hop headers */
        if (strcasecmp(name, "host") == 0 ||
            strcasecmp(name, "connection") == 0 ||
            strcasecmp(name, "proxy-connection") == 0) {
            continue;
        }

        req_len += snprintf(request + req_len, sizeof(request) - (size_t)req_len,
                           "%s: %s\r\n", name, value);
        if ((size_t)req_len >= sizeof(request) - 1) break;
    }

    /* Add API key */
    req_len += snprintf(request + req_len, sizeof(request) - (size_t)req_len,
                       "X-API-Key: %s\r\n", API_KEY);

    if (body_len > 0) {
        req_len += snprintf(request + req_len, sizeof(request) - (size_t)req_len,
                           "Content-Length: %zu\r\n\r\n", body_len);
    } else {
        req_len += snprintf(request + req_len, sizeof(request) - (size_t)req_len, "\r\n");
    }

    /* Send request to backend */
    {
        size_t to_send = (size_t)req_len;
        size_t total_sent = 0;
        while (total_sent < to_send) {
            ssize_t s = send(backend_fd, request + total_sent, to_send - total_sent, 0);
            if (s <= 0) {
                CLOSESOCK(backend_fd);
                const char *err = "{\"error\":\"Backend write failed\"}";
                send_response(client, 502, "Bad Gateway", "application/json", err, strlen(err));
                return;
            }
            total_sent += (size_t)s;
        }
    }

    if (body_len > 0) {
        size_t total_sent = 0;
        while (total_sent < body_len) {
            ssize_t s = send(backend_fd, body + total_sent, body_len - total_sent, 0);
            if (s <= 0) break;
            total_sent += (size_t)s;
        }
    }

    /* Read and forward response in chunks */
    char response[BUFFER_SIZE];
    ssize_t n;
    while ((n = recv(backend_fd, response, sizeof(response), 0)) > 0) {
        size_t to_send = (size_t)n;
        size_t total_sent = 0;
        while (total_sent < to_send) {
            ssize_t s = send(client, response + total_sent, to_send - total_sent, 0);
            if (s <= 0) goto proxy_done;
            total_sent += (size_t)s;
        }
    }

proxy_done:
    CLOSESOCK(backend_fd);
}

/* ── Parse HTTP request ─────────────────────────────────────────────────── */

static int parse_request(const char *request, size_t request_len,
                          char *method, char *path,
                          char headers[][2][MAX_HEADER_VAL], int *num_headers) {
    const char *p = request;
    const char *end = request + request_len;

    /* Request line */
    const char *line_end = memchr(p, '\n', (size_t)(end - p));
    if (!line_end) return -1;

    size_t line_len = (size_t)(line_end - p);
    if (line_len > MAX_PATH_LEN + MAX_METHOD_LEN) return -1;

    /* Parse method and path from request line */
    const char *sp1 = memchr(p, ' ', (size_t)(line_end - p));
    if (!sp1) return -1;
    size_t method_len = (size_t)(sp1 - p);
    if (method_len >= MAX_METHOD_LEN) return -1;
    memcpy(method, p, method_len);
    method[method_len] = '\0';

    const char *sp2 = memchr(sp1 + 1, ' ', (size_t)(line_end - sp1 - 1));
    size_t path_len;
    if (sp2) {
        path_len = (size_t)(sp2 - sp1 - 1);
    } else {
        path_len = (size_t)(line_end - sp1 - 1);
        /* Strip trailing \r */
        if (path_len > 0 && p[path_len + (sp1 - p)] == '\r') path_len--;
    }
    if (path_len >= MAX_PATH_LEN) return -1;
    memcpy(path, sp1 + 1, path_len);
    path[path_len] = '\0';

    /* Advance past request line */
    p = line_end + 1;

    /* Parse headers */
    *num_headers = 0;
    while (*p && *p != '\r' && *p != '\n' && *num_headers < MAX_HEADERS && p < end) {
        line_end = memchr(p, '\n', (size_t)(end - p));
        if (!line_end) break;

        line_len = (size_t)(line_end - p);
        if (line_len == 0 || (line_len == 1 && *p == '\r')) {
            break;  /* End of headers */
        }

        /* Strip trailing \r */
        if (line_len > 0 && p[line_len - 1] == '\r') line_len--;

        const char *colon = memchr(p, ':', line_len);
        if (colon) {
            size_t name_len = (size_t)(colon - p);
            if (name_len >= MAX_HEADER_NAME) name_len = MAX_HEADER_NAME - 1;
            char header_name[MAX_HEADER_NAME];
            memcpy(header_name, p, name_len);
            header_name[name_len] = '\0';

            const char *val_start = colon + 1;
            /* Skip leading whitespace */
            while (val_start < p + line_len && (*val_start == ' ' || *val_start == '\t'))
                val_start++;
            size_t val_len = (size_t)((p + line_len) - val_start);
            if (val_len >= MAX_HEADER_VAL) val_len = MAX_HEADER_VAL - 1;

            strncpy(headers[*num_headers][0], header_name, MAX_HEADER_VAL - 1);
            headers[*num_headers][0][MAX_HEADER_VAL - 1] = '\0';
            memcpy(headers[*num_headers][1], val_start, val_len);
            headers[*num_headers][1][val_len] = '\0';
            (*num_headers)++;
        }

        p = line_end + 1;
    }

    return 0;
}

/* ── Handle a single client connection ──────────────────────────────────── */

static void handle_client(int client) {
    set_socket_timeout(client, CLIENT_TIMEOUT);

    char buffer[BUFFER_SIZE];
    ssize_t total_read = 0;

    /* Read request data — may need multiple recv() calls for slow clients */
    while (total_read < (ssize_t)sizeof(buffer) - 1) {
        ssize_t n = recv(client, buffer + total_read,
                         sizeof(buffer) - 1 - (size_t)total_read, 0);
        if (n <= 0) {
            CLOSESOCK(client);
            return;
        }
        total_read += n;

        /* Check if we have the full headers (look for \r\n\r\n) */
        if (total_read >= 4 && memmem(buffer, (size_t)total_read, "\r\n\r\n", 4)) {
            break;
        }
    }

    if (total_read <= 0) {
        CLOSESOCK(client);
        return;
    }
    buffer[total_read] = '\0';

    char method[MAX_METHOD_LEN] = {0};
    char path[MAX_PATH_LEN] = {0};
    char headers[MAX_HEADERS][2][MAX_HEADER_VAL];
    int num_headers = 0;

    if (parse_request(buffer, (size_t)total_read, method, path, headers, &num_headers) < 0) {
        const char *err = "{\"error\":\"Bad request\"}";
        send_response(client, 400, "Bad Request", "application/json", err, strlen(err));
        CLOSESOCK(client);
        return;
    }

    /* Handle OPTIONS (CORS preflight) */
    if (strcmp(method, "OPTIONS") == 0) {
        send_response(client, 204, "No Content", "text/plain", "", 0);
        CLOSESOCK(client);
        return;
    }

    /* Health check endpoint for systemd watchdog */
    if (strcmp(method, "GET") == 0 && (strcmp(path, "/health") == 0 || strcmp(path, "/health/") == 0)) {
        const char *health = "{\"status\":\"ok\",\"service\":\"yvy-frontend\"}";
        send_response(client, 200, "OK", "application/json", health, strlen(health));
        CLOSESOCK(client);
        return;
    }

    /* Find body start */
    const char *body = NULL;
    size_t body_len = 0;
    const char *body_start = memmem(buffer, (size_t)total_read, "\r\n\r\n", 4);
    if (body_start) {
        body_start += 4;
        body_len = (size_t)(buffer + total_read - body_start);
        body = body_start;
    }

    /* Route: /api paths go to backend */
    if (strncmp(path, "/api", 4) == 0) {
        proxy_to_backend(client, method, path, headers, num_headers,
                        body ? body : "", body_len);
    } else {
        /* Static file */
        serve_static(client, path);
    }

    CLOSESOCK(client);
}

/* ── Signal handler for graceful shutdown ────────────────────────────────── */

static void handle_signal(int sig) {
    (void)sig;
    printf("\nShutting down (signal received)...\n");
    g_running = 0;
    if (g_server_fd >= 0) {
        CLOSESOCK(g_server_fd);
        g_server_fd = -1;
    }
}

/* ── Main ───────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
#ifdef _WIN32
    /* Initialize Winsock */
    WSADATA wsaData;
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
        fprintf(stderr, "WSAStartup failed\n");
        return 1;
    }
#endif

    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            PORT = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--backend") == 0 && i + 1 < argc) {
            BACKEND_HOST = argv[++i];
        } else if (strcmp(argv[i], "--static") == 0 && i + 1 < argc) {
            STATIC_DIR = argv[++i];
        } else if (strcmp(argv[i], "--api-key") == 0 && i + 1 < argc) {
            API_KEY = argv[++i];
        }
    }

    /* Setup signal handlers */
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
#ifndef _WIN32
    signal(SIGPIPE, SIG_IGN);  /* Ignore broken pipe */
#endif

    /* Create server socket */
    g_server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (g_server_fd < 0) {
        perror("socket");
        return 1;
    }

    int opt = 1;
#ifdef _WIN32
    setsockopt(g_server_fd, SOL_SOCKET, SO_REUSEADDR, (const char*)&opt, sizeof(opt));
#else
    setsockopt(g_server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#endif

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)PORT);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(g_server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        CLOSESOCK(g_server_fd);
        return 1;
    }

    if (listen(g_server_fd, LISTEN_BACKLOG) < 0) {
        perror("listen");
        CLOSESOCK(g_server_fd);
        return 1;
    }

    printf("=== Yvy C Frontend Server ===\n");
    printf("Port: %d\n", PORT);
    printf("Backend: %s:%d\n", BACKEND_HOST, BACKEND_PORT);
    printf("Static: %s\n", STATIC_DIR);
    printf("Server running. Press Ctrl+C to stop.\n");

    /* Main accept loop */
    while (g_running) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);

        int client = accept(g_server_fd, (struct sockaddr*)&client_addr, &client_len);
        if (client < 0) {
            if (!g_running) break;
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }

        handle_client(client);
    }

    if (g_server_fd >= 0) {
        CLOSESOCK(g_server_fd);
    }
    printf("Server stopped.\n");

#ifdef _WIN32
    WSACleanup();
#endif
    return 0;
}
