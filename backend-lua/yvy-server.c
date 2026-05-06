/* yvy-server.c - Minimal HTTP server for Yvy frontend
 * Serves static files + proxies /api/* to Lua backend
 * 
 * Linux: gcc -o yvy-server yvy-server.c
 * Windows (MinGW): gcc -o yvy-server.exe yvy-server.c -lws2_32
 */

#ifdef _WIN32
    #include <winsock2.h>
    #include <ws2tcpip.h>
    typedef int socklen_t;
#else
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <unistd.h>
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>

#define PORT_DEFAULT 5001
#define BACKEND_PORT 5000
#define BUFFER_SIZE 65536
#define MAX_HEADERS 50

static const char *STATIC_DIR = "../frontend/build";
static const char *BACKEND_HOST = "127.0.0.1";
static const char *API_KEY = "";
static int PORT = PORT_DEFAULT;

/* MIME types */
const char *get_mime_type(const char *path) {
    const char *ext = strrchr(path, '.');
    if (!ext) return "application/octet-stream";
    
    if (strcmp(ext, ".html") == 0 || strcmp(ext, ".htm") == 0) return "text/html";
    if (strcmp(ext, ".css") == 0) return "text/css";
    if (strcmp(ext, ".js") == 0) return "application/javascript";
    if (strcmp(ext, ".json") == 0) return "application/json";
    if (strcmp(ext, ".png") == 0) return "image/png";
    if (strcmp(ext, ".jpg") == 0 || strcmp(ext, ".jpeg") == 0) return "image/jpeg";
    if (strcmp(ext, ".gif") == 0) return "image/gif";
    if (strcmp(ext, ".svg") == 0) return "image/svg+xml";
    if (strcmp(ext, ".ico") == 0) return "image/x-icon";
    if (strcmp(ext, ".woff") == 0) return "font/woff";
    if (strcmp(ext, ".woff2") == 0) return "font/woff2";
    if (strcmp(ext, ".txt") == 0) return "text/plain";
    return "application/octet-stream";
}

/* Read file into buffer */
ssize_t read_file(const char *path, char **buf) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    
    *buf = malloc(size + 1);
    if (!*buf) { fclose(f); return -1; }
    
    size_t read = fread(*buf, 1, size, f);
    (*buf)[read] = '\0';
    fclose(f);
    
    return read;
}

/* Parse HTTP request */
int parse_request(const char *request, char *method, char *path, char headers[][2][256], int *num_headers) {
    char line[1024];
    const char *p = request;
    
    /* Request line */
    if (sscanf(p, "%63s %511s", method, path) != 2) return -1;
    
    /* Headers */
    p = strchr(p, '\n');
    if (!p) return -1;
    p++;
    
    *num_headers = 0;
    while (*p && *num_headers < MAX_HEADERS) {
        const char *end = strchr(p, '\n');
        if (!end) break;
        
        int len = end - p;
        if (len > 0 && len < 1024) {
            strncpy(line, p, len);
            line[len] = '\0';
            
            if (line[0] == '\r' || line[0] == '\n') break;
            
            char *colon = strchr(line, ':');
            if (colon) {
                *colon = '\0';
                char *value = colon + 1;
                while (*value == ' ') value++;
                
                strncpy(headers[*num_headers][0], line, 255);
                strncpy(headers[*num_headers][1], value, 255);
                (*num_headers)++;
            }
        }
        
        p = end + 1;
    }
    
    return 0;
}

/* Send HTTP response */
void send_response(int client, int status, const char *status_text, 
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
    
    send(client, header, header_len, 0);
    if (body && body_len > 0) {
        send(client, body, body_len, 0);
    }
}

/* Serve static file */
void serve_static(int client, const char *path) {
    char file_path[512];
    
    /* Default to index.html for root or SPA routes */
    if (strcmp(path, "/") == 0 || strchr(path, '.') == NULL) {
        snprintf(file_path, sizeof(file_path), "%s/index.html", STATIC_DIR);
    } else {
        snprintf(file_path, sizeof(file_path), "%s%s", STATIC_DIR, path);
    }
    
    char *content;
    ssize_t size = read_file(file_path, &content);
    
    if (size < 0) {
        /* Try index.html as fallback for SPA */
        snprintf(file_path, sizeof(file_path), "%s/index.html", STATIC_DIR);
        size = read_file(file_path, &content);
        
        if (size < 0) {
            const char *error = "{\"error\":\"Not found\"}";
            send_response(client, 404, "Not Found", "application/json", error, strlen(error));
            return;
        }
    }
    
    const char *mime = get_mime_type(file_path);
    send_response(client, 200, "OK", mime, content, size);
    free(content);
}

/* Proxy to backend */
void proxy_to_backend(int client, const char *method, const char *path, 
                      char headers[][2][256], int num_headers,
                      const char *body, size_t body_len) {
    char backend_path[1024];
    snprintf(backend_path, sizeof(backend_path), "%s", path);
    
    /* Connect to backend */
    int backend_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (backend_fd < 0) {
        const char *error = "{\"error\":\"Backend unavailable\"}";
        send_response(client, 502, "Bad Gateway", "application/json", error, strlen(error));
        return;
    }
    
    struct sockaddr_in backend_addr = {
        .sin_family = AF_INET,
        .sin_port = htons(BACKEND_PORT),
        .sin_addr.s_addr = inet_addr(BACKEND_HOST)
    };
    
    if (connect(backend_fd, (struct sockaddr*)&backend_addr, sizeof(backend_addr)) < 0) {
        close(backend_fd);
        const char *error = "{\"error\":\"Backend connection failed\"}";
        send_response(client, 502, "Bad Gateway", "application/json", error, strlen(error));
        return;
    }
    
    /* Build backend request */
    char request[4096];
    int req_len = snprintf(request, sizeof(request), "%s %s HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "Connection: close\r\n",
        method, backend_path, BACKEND_HOST, BACKEND_PORT);
    
    /* Copy headers and add API key */
    for (int i = 0; i < num_headers; i++) {
        const char *name = headers[i][0];
        const char *value = headers[i][1];
        
        /* Skip hop-by-hop headers */
        if (strcasecmp(name, "host") == 0 || 
            strcasecmp(name, "connection") == 0 ||
            strcasecmp(name, "proxy-connection") == 0) {
            continue;
        }
        
        req_len += snprintf(request + req_len, sizeof(request) - req_len, 
                           "%s: %s\r\n", name, value);
    }
    
    /* Add API key */
    req_len += snprintf(request + req_len, sizeof(request) - req_len,
                       "X-API-Key: %s\r\n", API_KEY);
    
    if (body_len > 0) {
        req_len += snprintf(request + req_len, sizeof(request) - req_len,
                           "Content-Length: %zu\r\n\r\n", body_len);
    } else {
        req_len += snprintf(request + req_len, sizeof(request) - req_len, "\r\n");
    }
    
    /* Send request to backend */
    send(backend_fd, request, req_len, 0);
    if (body_len > 0) {
        send(backend_fd, body, body_len, 0);
    }
    
    /* Read and forward response */
    char response[BUFFER_SIZE];
    ssize_t n;
    while ((n = recv(backend_fd, response, sizeof(response), 0)) > 0) {
        send(client, response, n, 0);
    }
    
    close(backend_fd);
}

/* Handle client connection */
void handle_client(int client) {
    char buffer[BUFFER_SIZE];
    ssize_t n = recv(client, buffer, sizeof(buffer) - 1, 0);
    
    if (n <= 0) {
        close(client);
        return;
    }
    
    buffer[n] = '\0';
    
    char method[64], path[512];
    char headers[MAX_HEADERS][2][256];
    int num_headers = 0;
    
    if (parse_request(buffer, method, path, headers, &num_headers) < 0) {
        const char *error = "{\"error\":\"Bad request\"}";
        send_response(client, 400, "Bad Request", "application/json", error, strlen(error));
        close(client);
        return;
    }
    
    /* Handle OPTIONS (CORS preflight) */
    if (strcmp(method, "OPTIONS") == 0) {
        send_response(client, 204, "No Content", "text/plain", "", 0);
        close(client);
        return;
    }
    
    /* Find body */
    const char *body = strstr(buffer, "\r\n\r\n");
    size_t body_len = 0;
    if (body) {
        body += 4;
        body_len = n - (body - buffer);
    }
    
    /* Route: /api/* → proxy to backend */
    if (strncmp(path, "/api", 4) == 0) {
        proxy_to_backend(client, method, path, headers, num_headers, 
                        body ? body : "", body_len);
    } else {
        /* Static file */
        serve_static(client, path);
    }
    
    close(client);
}

/* Signal handler for graceful shutdown */
volatile sig_atomic_t running = 1;

void handle_signal(int sig) {
    printf("\nShutting down...\n");
    running = 0;
}

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
#ifdef _WIN32
    signal(SIGTERM, handle_signal);
#else
    signal(SIGTERM, handle_signal);
#endif
    
    /* Create server socket */
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return 1;
    }
    
    int opt = 1;
#ifdef _WIN32
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, (const char*)&opt, sizeof(opt));
#else
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#endif
    
    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(PORT),
        .sin_addr.s_addr = INADDR_ANY
    };
    
    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    
    if (listen(server_fd, 128) < 0) {
        perror("listen");
        return 1;
    }
    
    printf("=== Yvy C Frontend Server ===\n");
    printf("Port: %d\n", PORT);
    printf("Backend: %s:%d\n", BACKEND_HOST, BACKEND_PORT);
    printf("Static: %s\n", STATIC_DIR);
    printf("Server running. Press Ctrl+C to stop.\n");
    
    /* Main loop */
    while (running) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        
        int client = accept(server_fd, (struct sockaddr*)&client_addr, &client_len);
        if (client < 0) {
            if (errno == EINTR) continue;  /* Interrupted by signal */
            perror("accept");
            continue;
        }
        
        handle_client(client);
    }
    
    close(server_fd);
    printf("Server stopped.\n");
    
#ifdef _WIN32
    WSACleanup();
#endif
    return 0;
}
