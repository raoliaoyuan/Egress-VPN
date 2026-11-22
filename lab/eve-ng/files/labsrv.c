/* 压测用的服务端，放在内网服务节点上。
 *
 * 用法：labsrv [--threads N] [--http 端口]... [--echo 端口]...
 *   --http：最小的 HTTP/1.1 服务。对任何请求都返回一段 JSON，里面是它看到的来源地址和端口：
 *           {"server": "labsrv", "client": "100.67.0.5", "cport": 40000}
 *           格式和 echo-server.py 的 client 字段一致，压测工具用它核对“身份有没有串”。
 *           支持长连接；请求里带 Connection: close 时回完就关。
 *   --echo：把收到的字节原样发回。用来测一条持续传输的长连接在故障前后断没断。
 *
 * 回显服务 echo-server.py 是 Python 写的，每秒只能处理一两千个请求，压测时它会先成为瓶颈，所以另写了这个。
 * 每个线程一个 epoll，监听套接字用 SO_REUSEPORT 分给各线程。只为实验写的，不做任何鉴权。
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAXPORTS 16
#define INBUF 4096
#define ECHOBUF 65536

enum { K_LISTEN_HTTP, K_LISTEN_ECHO, K_HTTP, K_ECHO };

struct conn {
	int fd, kind;
	char peer[INET_ADDRSTRLEN];
	int pport;
	int inlen;
	char in[INBUF];
	/* 回显模式下没发完的数据 */
	char *out;
	int outlen, outoff;
};

static int http_ports[MAXPORTS], n_http, echo_ports[MAXPORTS], n_echo, n_threads = 1;

static void die(const char *m) { perror(m); exit(1); }

static int listener(int port) {
	int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0), one = 1;
	struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = INADDR_ANY };
	if (fd < 0) die("socket");
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
	if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) die("bind");
	if (listen(fd, 4096) < 0) die("listen");
	return fd;
}

static void add(int ep, struct conn *c, uint32_t ev) {
	struct epoll_event e = { .events = ev, .data.ptr = c };
	if (epoll_ctl(ep, EPOLL_CTL_ADD, c->fd, &e) < 0) die("epoll_ctl");
}

static void drop(int ep, struct conn *c) {
	epoll_ctl(ep, EPOLL_CTL_DEL, c->fd, NULL);
	close(c->fd);
	free(c->out);
	free(c);
}

/* 处理缓冲区里所有完整的请求。返回 0 表示连接要关。 */
static int serve_http(struct conn *c) {
	for (;;) {
		char *end = memmem(c->in, c->inlen, "\r\n\r\n", 4);
		if (!end) return c->inlen < INBUF;   /* 请求头超过缓冲区就关掉 */
		int reqlen = end + 4 - c->in;
		int closing = 0;
		for (char *p = c->in; p < end; p++)
			if ((*p == 'C' || *p == 'c') && end - p >= 17 && !strncasecmp(p, "connection: close", 17)) closing = 1;
		char body[128], resp[320];
		int bl = snprintf(body, sizeof body, "{\"server\": \"labsrv\", \"client\": \"%s\", \"cport\": %d}", c->peer, c->pport);
		int rl = snprintf(resp, sizeof resp,
			"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n%s\r\n%s",
			bl, closing ? "Connection: close\r\n" : "", body);
		/* 响应很小，套接字缓冲区放得下；放不下就当作出错关掉 */
		if (send(c->fd, resp, rl, MSG_NOSIGNAL) != rl) return 0;
		memmove(c->in, c->in + reqlen, c->inlen - reqlen);
		c->inlen -= reqlen;
		if (closing) return 0;
	}
}

static int flush_echo(int ep, struct conn *c) {
	while (c->outoff < c->outlen) {
		int n = send(c->fd, c->out + c->outoff, c->outlen - c->outoff, MSG_NOSIGNAL);
		if (n < 0) {
			if (errno == EAGAIN) {
				struct epoll_event e = { .events = EPOLLOUT, .data.ptr = c };
				epoll_ctl(ep, EPOLL_CTL_MOD, c->fd, &e);
				return 1;
			}
			return 0;
		}
		c->outoff += n;
	}
	c->outlen = c->outoff = 0;
	struct epoll_event e = { .events = EPOLLIN, .data.ptr = c };
	epoll_ctl(ep, EPOLL_CTL_MOD, c->fd, &e);
	return 1;
}

static void *worker(void *arg) {
	(void)arg;
	int ep = epoll_create1(0);
	if (ep < 0) die("epoll_create1");
	for (int i = 0; i < n_http + n_echo; i++) {
		struct conn *c = calloc(1, sizeof *c);
		c->kind = i < n_http ? K_LISTEN_HTTP : K_LISTEN_ECHO;
		c->fd = listener(i < n_http ? http_ports[i] : echo_ports[i - n_http]);
		add(ep, c, EPOLLIN);
	}
	struct epoll_event evs[256];
	for (;;) {
		int n = epoll_wait(ep, evs, 256, -1);
		for (int i = 0; i < n; i++) {
			struct conn *c = evs[i].data.ptr;
			if (c->kind == K_LISTEN_HTTP || c->kind == K_LISTEN_ECHO) {
				for (;;) {
					struct sockaddr_in a; socklen_t al = sizeof a;
					int fd = accept4(c->fd, (struct sockaddr *)&a, &al, SOCK_NONBLOCK);
					if (fd < 0) break;
					int one = 1;
					setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
					struct conn *nc = calloc(1, sizeof *nc);
					nc->fd = fd;
					nc->kind = c->kind == K_LISTEN_HTTP ? K_HTTP : K_ECHO;
					inet_ntop(AF_INET, &a.sin_addr, nc->peer, sizeof nc->peer);
					nc->pport = ntohs(a.sin_port);
					if (nc->kind == K_ECHO) nc->out = malloc(ECHOBUF);
					add(ep, nc, EPOLLIN);
				}
			} else if (c->kind == K_HTTP) {
				int r = recv(c->fd, c->in + c->inlen, INBUF - c->inlen, 0);
				if (r <= 0) { if (r == 0 || errno != EAGAIN) drop(ep, c); continue; }
				c->inlen += r;
				if (!serve_http(c)) drop(ep, c);
			} else {
				if (evs[i].events & EPOLLOUT) { if (!flush_echo(ep, c)) drop(ep, c); continue; }
				int r = recv(c->fd, c->out, ECHOBUF, 0);
				if (r <= 0) { if (r == 0 || errno != EAGAIN) drop(ep, c); continue; }
				c->outlen = r; c->outoff = 0;
				if (!flush_echo(ep, c)) drop(ep, c);
			}
		}
	}
	return NULL;
}

int main(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--http") && i + 1 < argc && n_http < MAXPORTS) http_ports[n_http++] = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--echo") && i + 1 < argc && n_echo < MAXPORTS) echo_ports[n_echo++] = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--threads") && i + 1 < argc) n_threads = atoi(argv[++i]);
		else { fprintf(stderr, "用法：labsrv [--threads N] [--http 端口]... [--echo 端口]...\n"); return 2; }
	}
	if (n_http + n_echo == 0) { fprintf(stderr, "至少给一个 --http 或 --echo 端口\n"); return 2; }
	signal(SIGPIPE, SIG_IGN);
	struct rlimit rl = { 1 << 20, 1 << 20 };
	setrlimit(RLIMIT_NOFILE, &rl);
	pthread_t t;
	for (int i = 1; i < n_threads; i++) pthread_create(&t, NULL, worker, NULL);
	worker(NULL);
	return 0;
}
