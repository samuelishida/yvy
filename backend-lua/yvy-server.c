/* yvy-server.c — Single-threaded HTTP frontend server for Yvy
 *
 * Serves static files (React build) + proxies /api paths to Lua backend.
 * Nginx handles everything in production, this is a drop in replacement for development.
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
#include <stdarg.h>
#include <time.h>
#include <sys/wait.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

/* ── Configuration ──────────────────────────────────────────────────────── */

#define PORT_DEFAULT    5001
#define BACKEND_PORT_DEFAULT 5000
#define BACKEND_PORT    g_backend_port
#define BUFFER_SIZE     65536
#define MAX_HEADERS     50
#define MAX_PATH_LEN    512
#define MAX_METHOD_LEN  16
#define MAX_HEADER_NAME 128
#define MAX_HEADER_VAL  512
#define CLIENT_TIMEOUT  5                /* seconds for recv/send timeouts */
#define BACKEND_TIMEOUT 30               /* seconds for backend proxy timeout */
#define MAX_REQUEST_SIZE   (8 * 1024 * 1024) /* 8MB cap for client request (headers+body) — plan: risk-intelligence, Inc 3 (CSV uploads) */
#define MAX_RESPONSE_SIZE  (2 * 1024 * 1024) /* 2MB cap for buffered backend response */
#define DYNBUF_INITIAL_CAP 8192
#define LISTEN_BACKLOG  128

static const char *STATIC_DIR  = "../frontend/build";
static const char *BACKEND_HOST = "127.0.0.1";
static const char *API_KEY     = "";
static int PORT                = PORT_DEFAULT;
static int MAX_CHILDREN        = 64;

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
static int g_backend_port = BACKEND_PORT_DEFAULT;
static volatile sig_atomic_t g_active_children = 0;

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

/* ── Dynamic byte buffer ────────────────────────────────────────────────── */

typedef struct {
    char  *data;
    size_t len;
    size_t cap;
} dynbuf;

static int dynbuf_init(dynbuf *b, size_t initial_cap) {
    b->data = malloc(initial_cap);
    if (!b->data) {
        b->len = 0;
        b->cap = 0;
        return -1;
    }
    b->len = 0;
    b->cap = initial_cap;
    return 0;
}

static int dynbuf_reserve(dynbuf *b, size_t needed, size_t max_cap) {
    if (needed <= b->cap) return 0;
    if (needed > max_cap) return -1;
    size_t new_cap = b->cap > 0 ? b->cap : DYNBUF_INITIAL_CAP;
    while (new_cap < needed) {
        if (new_cap > max_cap / 2) { new_cap = max_cap; break; }
        new_cap *= 2;
    }
    if (new_cap < needed) new_cap = needed;
    char *new_data = realloc(b->data, new_cap);
    if (!new_data) return -1;
    b->data = new_data;
    b->cap = new_cap;
    return 0;
}

static int dynbuf_append(dynbuf *b, const char *src, size_t n, size_t max_cap) {
    if (dynbuf_reserve(b, b->len + n + 1, max_cap) < 0) return -1;
    memcpy(b->data + b->len, src, n);
    b->len += n;
    b->data[b->len] = '\0';
    return 0;
}

static int dynbuf_appendf(dynbuf *b, size_t max_cap, const char *fmt, ...) {
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int needed = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (needed < 0) { va_end(ap2); return -1; }
    if (dynbuf_reserve(b, b->len + (size_t)needed + 1, max_cap) < 0) {
        va_end(ap2);
        return -1;
    }
    vsnprintf(b->data + b->len, b->cap - b->len, fmt, ap2);
    va_end(ap2);
    b->len += (size_t)needed;
    return 0;
}

static void dynbuf_free(dynbuf *b) {
    free(b->data);
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
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

/* ── Send all bytes; returns total sent, or -1 on error/partial ──────────── */

static ssize_t send_all(int fd, const char *buf, size_t len) {
    size_t total = 0;
    while (total < len) {
        ssize_t s = send(fd, buf + total, len - total, 0);
        if (s <= 0) return -1;
        total += (size_t)s;
    }
    return (ssize_t)total;
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
        "\r\n",
        status, status_text, content_type, body_len);

    send_all(client, header, (size_t)header_len);
    if (body && body_len > 0) {
        send_all(client, body, body_len);
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
        if (sent < 0 && errno == EINTR) { sent = 1; continue; }
    }
#else
    /* Fallback: read + send in chunks */
    {
        char buf[32768];
        ssize_t n;
        while ((n = read(file_fd, buf, sizeof(buf))) > 0) {
            if (send_all(client, buf, (size_t)n) < 0) break;
        }
    }
#endif

    close(file_fd);
}

/* ── Proxy request to Lua backend ───────────────────────────────────────── */

static size_t parse_content_length(const char *headers_buf, size_t headers_size);

static void proxy_to_backend(int client, const char *method, const char *path,
                              char headers[][2][MAX_HEADER_VAL], int num_headers,
                              const char *body, size_t body_len, const char *client_ip) {
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

    /* Build backend request in a dynbuf so headers can grow past 64KB */
    dynbuf req_dyn;
    if (dynbuf_init(&req_dyn, DYNBUF_INITIAL_CAP) < 0) {
        CLOSESOCK(backend_fd);
        const char *err = "{\"error\":\"Out of memory\"}";
        send_response(client, 500, "Internal Server Error", "application/json", err, strlen(err));
        return;
    }

    int build_ok =
        dynbuf_appendf(&req_dyn, MAX_REQUEST_SIZE,
            "%s %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\n",
            method, path, BACKEND_HOST, BACKEND_PORT) == 0;

    /* Copy headers, skipping hop-by-hop */
    for (int i = 0; build_ok && i < num_headers; i++) {
        const char *name  = headers[i][0];
        const char *value = headers[i][1];
        if (strcasecmp(name, "host") == 0 ||
            strcasecmp(name, "connection") == 0 ||
            strcasecmp(name, "proxy-connection") == 0 ||
            strcasecmp(name, "content-length") == 0 ||
            strcasecmp(name, "x-api-key") == 0 ||
            strcasecmp(name, "x-real-ip") == 0 ||
            strcasecmp(name, "x-forwarded-for") == 0) {
            continue;
        }
        if (dynbuf_appendf(&req_dyn, MAX_REQUEST_SIZE, "%s: %s\r\n", name, value) < 0) {
            build_ok = 0;
        }
    }

    if (build_ok && dynbuf_appendf(&req_dyn, MAX_REQUEST_SIZE,
                                   "X-API-Key: %s\r\n", API_KEY) < 0) {
        build_ok = 0;
    }
    /* Forward the real client IP like nginx: the Lua middleware (rate limit,
     * logging) keys off X-Real-IP / X-Forwarded-For. Client-supplied values of
     * those headers are skipped above, so what we inject here can't be spoofed. */
    if (build_ok && client_ip && client_ip[0] &&
        dynbuf_appendf(&req_dyn, MAX_REQUEST_SIZE,
                       "X-Real-IP: %s\r\n", client_ip) < 0) {
        build_ok = 0;
    }
    if (build_ok && client_ip && client_ip[0] &&
        dynbuf_appendf(&req_dyn, MAX_REQUEST_SIZE,
                       "X-Forwarded-For: %s\r\n", client_ip) < 0) {
        build_ok = 0;
    }

    if (build_ok) {
        if (body_len > 0) {
            if (dynbuf_appendf(&req_dyn, MAX_REQUEST_SIZE,
                               "Content-Length: %zu\r\n\r\n", body_len) < 0) build_ok = 0;
        } else {
            if (dynbuf_appendf(&req_dyn, MAX_REQUEST_SIZE, "\r\n") < 0) build_ok = 0;
        }
    }

    if (!build_ok) {
        dynbuf_free(&req_dyn);
        CLOSESOCK(backend_fd);
        const char *err = "{\"error\":\"Request headers too large\"}";
        send_response(client, 431, "Request Header Fields Too Large",
                      "application/json", err, strlen(err));
        return;
    }

    /* Send request to backend */
    {
        size_t total_sent = 0;
        while (total_sent < req_dyn.len) {
            ssize_t s = send(backend_fd, req_dyn.data + total_sent,
                             req_dyn.len - total_sent, 0);
            if (s <= 0) {
                dynbuf_free(&req_dyn);
                CLOSESOCK(backend_fd);
                const char *err = "{\"error\":\"Backend write failed\"}";
                send_response(client, 502, "Bad Gateway", "application/json", err, strlen(err));
                return;
            }
            total_sent += (size_t)s;
        }
    }
    dynbuf_free(&req_dyn);

    if (body_len > 0) {
        if (send_all(backend_fd, body, body_len) < 0) {
            const char *err = "{\"error\":\"Backend write failed\"}";
            send_response(client, 502, "Bad Gateway", "application/json", err, strlen(err));
            return;
        }
    }

    /* Read backend response. Buffer up to MAX_RESPONSE_SIZE for atomic flush
     * (gives client headers + body in one go, preserving backend's Content-Length).
     * We honor the backend's Content-Length so we don't have to wait for the
     * connection to close: the Lua backend spawns detached subprocesses (news
     * sync, classification, ti-at-risk) that inherit the client socket fd, so
     * EOF may only arrive when the child exits (tens of seconds later). Once
     * the advertised body is fully buffered we flush and return. If the cap is
     * exceeded mid-stream we flush what we have and stream the rest, also
     * Content-Length-aware. Without a Content-Length we fall back to reading
     * until EOF, as before. */
    dynbuf resp;
    int streaming = 0;
    char chunk[BUFFER_SIZE];
    ssize_t n;
    size_t headers_size = 0;      /* header block size incl. "\r\n\r\n"; 0 = not parsed */
    size_t content_length = 0;    /* backend-advertised body length */
    int have_content_length = 0;  /* parsed from backend headers */
    size_t body_sent = 0;         /* body bytes already forwarded to the client */

    if (dynbuf_init(&resp, DYNBUF_INITIAL_CAP) < 0) {
        streaming = 1;  /* OOM: degrade to streaming (EOF-terminated) */
    }

    while ((n = recv(backend_fd, chunk, sizeof(chunk), 0)) > 0) {
        if (streaming) {
            size_t fwd = (size_t)n;
            if (have_content_length) {
                if (body_sent >= content_length) break;
                if (fwd > content_length - body_sent) fwd = content_length - body_sent;
            }
            if (fwd > 0 && send_all(client, chunk, fwd) < 0) goto proxy_done;
            body_sent += fwd;
            if (have_content_length && body_sent >= content_length) break;
            continue;
        }

        if (dynbuf_append(&resp, chunk, (size_t)n, MAX_RESPONSE_SIZE) < 0) {
            /* Cap hit: parse Content-Length if not yet, flush buffered bytes,
             * then stream the rest as-is (Content-Length-aware). */
            if (headers_size == 0) {
                const char *eoh = memmem(resp.data, resp.len, "\r\n\r\n", 4);
                if (eoh) {
                    headers_size = (size_t)(eoh - resp.data) + 4;
                    size_t cl = parse_content_length(resp.data, headers_size);
                    if (cl > 0) {
                        have_content_length = 1;
                        content_length = cl;
                    }
                }
            }
            if (send_all(client, resp.data, resp.len) < 0) { dynbuf_free(&resp); goto proxy_done; }
            if (headers_size > 0) {
                body_sent = resp.len > headers_size ? resp.len - headers_size : 0;
            } else {
                body_sent = 0;
            }
            dynbuf_free(&resp);
            streaming = 1;
            /* Forward this chunk too */
            size_t fwd = (size_t)n;
            if (have_content_length) {
                if (body_sent >= content_length) break;
                if (fwd > content_length - body_sent) fwd = content_length - body_sent;
            }
            if (fwd > 0 && send_all(client, chunk, fwd) < 0) goto proxy_done;
            body_sent += fwd;
            if (have_content_length && body_sent >= content_length) break;
            continue;
        }

        /* Buffered mode: parse headers once the header block is complete. */
        if (headers_size == 0) {
            const char *eoh = memmem(resp.data, resp.len, "\r\n\r\n", 4);
            if (eoh) {
                headers_size = (size_t)(eoh - resp.data) + 4;
                size_t cl = parse_content_length(resp.data, headers_size);
                if (cl > 0) {
                    have_content_length = 1;
                    content_length = cl;
                }
            }
        }

        /* Once the full advertised body is buffered, we're done — no need to
         * wait for connection close (a detached subprocess may hold the fd). */
        if (have_content_length && headers_size > 0) {
            if (resp.len - headers_size >= content_length) break;
        }
    }

    /* Response complete (Content-Length met) or EOF reached. Flush buffered. */
    if (!streaming && resp.len > 0) {
        send_all(client, resp.data, resp.len);
    }
    dynbuf_free(&resp);

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

            strncpy(headers[*num_headers][0], header_name, MAX_HEADER_NAME - 1);
            headers[*num_headers][0][MAX_HEADER_NAME - 1] = '\0';
            memcpy(headers[*num_headers][1], val_start, val_len);
            headers[*num_headers][1][val_len] = '\0';
            (*num_headers)++;
        }

        p = line_end + 1;
    }

    return 0;
}

/* ── Handle a single client connection ──────────────────────────────────── */

static size_t parse_content_length(const char *headers_buf, size_t headers_size) {
    /* Scan header block for Content-Length (case-insensitive). Returns 0 if absent. */
    const char *p = headers_buf;
    const char *end = headers_buf + headers_size;
    while (p < end) {
        const char *line_end = memchr(p, '\n', (size_t)(end - p));
        if (!line_end) break;
        size_t line_len = (size_t)(line_end - p);
        if (line_len >= 16 && strncasecmp(p, "Content-Length:", 15) == 0) {
            const char *vp = p + 15;
            const char *vend = line_end;
            while (vp < vend && (*vp == ' ' || *vp == '\t')) vp++;
            errno = 0;
            unsigned long v = strtoul(vp, NULL, 10);
            if (errno == ERANGE || v > MAX_REQUEST_SIZE) return 0;
            return (size_t)v;
        }
        p = line_end + 1;
    }
    return 0;
}

static void handle_client(int client, const char *client_ip) {
    set_socket_timeout(client, CLIENT_TIMEOUT);

    dynbuf reqbuf;
    if (dynbuf_init(&reqbuf, DYNBUF_INITIAL_CAP) < 0) {
        CLOSESOCK(client);
        return;
    }

    char chunk[8192];
    int headers_complete = 0;
    size_t headers_size = 0;

    /* Phase 1: read until we see end-of-headers (\r\n\r\n) */
    while (reqbuf.len < MAX_REQUEST_SIZE) {
        ssize_t n = recv(client, chunk, sizeof(chunk), 0);
        if (n <= 0) {
            dynbuf_free(&reqbuf);
            CLOSESOCK(client);
            return;
        }
        if (dynbuf_append(&reqbuf, chunk, (size_t)n, MAX_REQUEST_SIZE) < 0) {
            const char *err = "{\"error\":\"Request too large\"}";
            send_response(client, 413, "Payload Too Large", "application/json", err, strlen(err));
            dynbuf_free(&reqbuf);
            CLOSESOCK(client);
            return;
        }
        const char *eoh = memmem(reqbuf.data, reqbuf.len, "\r\n\r\n", 4);
        if (eoh) {
            headers_complete = 1;
            headers_size = (size_t)(eoh - reqbuf.data) + 4;
            break;
        }
    }

    if (!headers_complete) {
        const char *err = "{\"error\":\"Request headers too large\"}";
        send_response(client, 431, "Request Header Fields Too Large",
                      "application/json", err, strlen(err));
        dynbuf_free(&reqbuf);
        CLOSESOCK(client);
        return;
    }

    /* Phase 2: drain remaining body bytes if Content-Length advertises more
     * than what arrived in phase 1. Required for large POST bodies. */
    size_t content_length = parse_content_length(reqbuf.data, headers_size);
    if (content_length > 0) {
        size_t body_have = reqbuf.len - headers_size;
        size_t total_needed = headers_size + content_length;
        if (total_needed > MAX_REQUEST_SIZE) {
            const char *err = "{\"error\":\"Request too large\"}";
            send_response(client, 413, "Payload Too Large", "application/json", err, strlen(err));
            dynbuf_free(&reqbuf);
            CLOSESOCK(client);
            return;
        }
        while (body_have < content_length) {
            ssize_t n = recv(client, chunk, sizeof(chunk), 0);
            if (n <= 0) break;  /* short body — pass what we have */
            size_t to_take = (size_t)n;
            if (body_have + to_take > content_length) to_take = content_length - body_have;
            if (dynbuf_append(&reqbuf, chunk, to_take, MAX_REQUEST_SIZE) < 0) break;
            body_have += to_take;
        }
    }

    char method[MAX_METHOD_LEN] = {0};
    char path[MAX_PATH_LEN] = {0};
    char headers[MAX_HEADERS][2][MAX_HEADER_VAL];
    int num_headers = 0;

    if (parse_request(reqbuf.data, reqbuf.len, method, path, headers, &num_headers) < 0) {
        const char *err = "{\"error\":\"Bad request\"}";
        send_response(client, 400, "Bad Request", "application/json", err, strlen(err));
        dynbuf_free(&reqbuf);
        CLOSESOCK(client);
        return;
    }

    /* Health check endpoint for systemd watchdog */
    if (strcmp(method, "GET") == 0 && (strcmp(path, "/health") == 0 || strcmp(path, "/health/") == 0)) {
        const char *health = "{\"status\":\"ok\",\"service\":\"yvy-frontend\"}";
        send_response(client, 200, "OK", "application/json", health, strlen(health));
        dynbuf_free(&reqbuf);
        CLOSESOCK(client);
        return;
    }

    /* Rate limiting is done by the Lua backend middleware (same as nginx
     * in prod): the C server is a compact nginx for local static serving and
     * does not enforce its own limits. */

    /* Body span lives inside reqbuf; safe until dynbuf_free below */
    const char *body = reqbuf.data + headers_size;
    size_t body_len = reqbuf.len - headers_size;

    /* Route: /api paths go to backend (including OPTIONS preflight, so the
     * Lua backend can answer CORS with origin-specific headers).
     * OPTIONS on static paths returns 204 with no CORS headers. */
    if (strncmp(path, "/api", 4) == 0) {
        proxy_to_backend(client, method, path, headers, num_headers, body, body_len, client_ip);
    } else if (strcmp(method, "OPTIONS") == 0) {
        send_response(client, 204, "No Content", "text/plain", "", 0);
    } else {
        serve_static(client, path);
    }

    dynbuf_free(&reqbuf);
    CLOSESOCK(client);
}

/* ── Signal handler for SIGCHLD (zombie reaping) ────────────────────────────────── */

static void handle_sigchld(int sig) {
    (void)sig;
    /* Reap inside the handler so SA_RESTART-protected blocking syscalls
     * (e.g. accept) don't have to wake up to clean up children.
     * waitpid() and the volatile sig_atomic_t decrement are async-signal-safe. */
    int saved_errno = errno;
    while (waitpid(-1, NULL, WNOHANG) > 0) {
        if (g_active_children > 0) g_active_children--;
    }
    errno = saved_errno;
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
        } else if (strcmp(argv[i], "--max-children") == 0 && i + 1 < argc) {
            MAX_CHILDREN = atoi(argv[++i]);
            if (MAX_CHILDREN <= 0) {
                fprintf(stderr, "Error: --max-children must be a positive integer\n");
                return 1;
            }
        } else if (strcmp(argv[i], "--backend-port") == 0 && i + 1 < argc) {
            g_backend_port = atoi(argv[++i]);
            if (g_backend_port <= 0 || g_backend_port > 65535) {
                fprintf(stderr, "Error: --backend-port must be 1-65535\n");
                return 1;
            }
        }
    }

    /* Setup signal handlers */
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGCHLD, handle_sigchld);
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
    printf("Max children: %d\n", MAX_CHILDREN);
    printf("Server running. Press Ctrl+C to stop.\n");

    /* Main accept loop with fork-per-connection */
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

        /* Reaping happens in the SIGCHLD handler — no work needed here */

        /* Block SIGCHLD around check-and-fork to prevent race:
         * Without this, a SIGCHLD between the >= check and the ++ would
         * decrement a slot we haven't reserved yet, allowing cap overflow. */
        sigset_t block_chld, old_sig;
        sigemptyset(&block_chld);
        sigaddset(&block_chld, SIGCHLD);

        sigprocmask(SIG_BLOCK, &block_chld, &old_sig);

        /* Check max children limit */
        if (g_active_children >= MAX_CHILDREN) {
            sigprocmask(SIG_SETMASK, &old_sig, NULL);
            /* Send 503 Service Unavailable with Retry-After */
            const char *body503 = "{\"error\":\"Server busy\"}";
            char hdr503[512];
            int hlen = snprintf(hdr503, sizeof(hdr503),
                "HTTP/1.1 503 Service Unavailable\r\n"
                "Content-Type: application/json\r\n"
                "Content-Length: %zu\r\n"
                "Connection: close\r\n"
                "Retry-After: 5\r\n"
                "\r\n", strlen(body503));
            if (hlen > 0) send(client, hdr503, (size_t)hlen, 0);
            send(client, body503, strlen(body503), 0);
            close(client);
            continue;
        }

        /* Reserve the slot before fork so a SIGCHLD that fires immediately
         * after fork (fast child exit) doesn't decrement past our increment.
         * SIGCHLD is already blocked here (see above). */
        g_active_children++;

        pid_t pid = fork();
        if (pid < 0) {
            perror("fork");
            if (g_active_children > 0) g_active_children--;
            sigprocmask(SIG_SETMASK, &old_sig, NULL);
            close(client);
            continue;
        }

        if (pid == 0) {
            /* Child: reset signal mask so child handles signals normally */
            sigprocmask(SIG_SETMASK, &old_sig, NULL);
            /* Close inherited listen socket so the child doesn't keep it
             * alive past parent shutdown. */
            if (g_server_fd >= 0) close(g_server_fd);
            handle_client(client, inet_ntoa(client_addr.sin_addr));
            _exit(0);
        } else {
            /* Parent — unblock SIGCHLD now that the slot is reserved */
            sigprocmask(SIG_SETMASK, &old_sig, NULL);
            close(client);  /* Parent doesn't use the connection socket */
        }
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
