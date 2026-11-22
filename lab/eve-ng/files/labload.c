/* 压测用的客户端，放在发流量的节点上（vm-farm，或某一台虚拟机）。
 *
 * 它做三件现成工具做不到的事：
 *   1. 每条连接绑定不同的源地址，用一个节点模拟大量虚拟机（身份）；
 *   2. 每个响应都核对“内网服务看到的来源地址”是不是这个身份应有的内网 IP，统计串了多少；
 *   3. 按 0.1 秒一格记录成功和失败的次数，故障注入时用来算“新连接多久恢复”。
 *
 * 用法：labload --target IP:端口 [选项]
 *   --src-base IP        第一个身份的源地址；不给就不绑定源地址（用本机地址）
 *   --src-count N        身份的个数，源地址是 src-base 起连续的 N 个（默认 1）
 *   --expect-base IP     第一个身份应有的内网 IP，第 i 个身份是它加 i；不给就不核对
 *   --conns C            同时在用的连接数（默认 64）
 *   --threads T          线程数（默认 1）
 *   --duration S         持续秒数（默认 10）
 *   --reqs-per-conn R    每条连接发几个请求；1 是每个请求新建一条连接（默认），0 是一直复用
 *   --rate N             每秒发起的请求数上限；不给就是有多快发多快
 *   --timeout MS         单个请求的超时，含建连（默认 2000）
 *   --sport-base P       第 j 条连接固定用源端口 P+j（用来构造连接跟踪的五元组冲突）
 *   --timeline 文件      每 0.1 秒一行：时间（Unix 秒） 成功数 失败数
 *   --host 名字          请求里的 Host（默认是目标地址）
 * 结果是标准输出上的一行 JSON。只为实验写的。
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define HIST 1000000          /* 延迟直方图：10 微秒一格，到 10 秒 */
#define RBUF 1024
enum { S_IDLE, S_CONNECTING, S_READING, S_WAIT };
enum { E_CONNECT, E_TIMEOUT, E_RESET, E_HTTP, E_MISMATCH, E_N };
static const char *ENAME[E_N] = { "connect", "timeout", "reset", "http", "mismatch" };

struct conn {
	int fd, state, slot, reqs_done, inlen;
	uint32_t ident;
	uint64_t t_start, deadline;
	char in[RBUF];
};

struct thread {
	pthread_t tid;
	int id, nconn, ep;
	struct conn *conns;
	uint64_t ok, err[E_N], opened;
	uint32_t *hist;
	uint32_t next_ident;
	double tokens;
	char sample[4][160];
	int nsample;
};

static struct sockaddr_in target;
static char target_str[64], host_hdr[96];
static int have_src, have_expect, n_conns = 64, n_threads = 1, duration = 10, reqs_per_conn = 1, timeout_ms = 2000, sport_base;
static uint32_t src_base, src_count = 1, expect_base;
static double rate;
static const char *timeline_path;
static uint64_t t0_mono, t_end;
static double t0_wall;
static uint32_t *tl_ok, *tl_fail;
static int tl_n;
static char request[256];
static int request_len;

static uint64_t now_us(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void tick(int ok) {
	uint64_t i = (now_us() - t0_mono) / 100000;
	if (i < (uint64_t)tl_n) __sync_fetch_and_add(ok ? &tl_ok[i] : &tl_fail[i], 1);
}

static void close_conn(struct thread *t, struct conn *c) {
	if (c->fd >= 0) { epoll_ctl(t->ep, EPOLL_CTL_DEL, c->fd, NULL); close(c->fd); }
	c->fd = -1;
	c->state = S_IDLE;
	c->reqs_done = 0;
}

static void fail(struct thread *t, struct conn *c, int kind) {
	t->err[kind]++;
	tick(0);
	close_conn(t, c);
}

static void send_request(struct thread *t, struct conn *c) {
	c->t_start = c->state == S_CONNECTING ? c->t_start : now_us();
	c->deadline = c->t_start + (uint64_t)timeout_ms * 1000;
	c->inlen = 0;
	if (send(c->fd, request, request_len, MSG_NOSIGNAL) != request_len) { fail(t, c, E_RESET); return; }
	c->state = S_READING;
	struct epoll_event e = { .events = EPOLLIN, .data.ptr = c };
	epoll_ctl(t->ep, EPOLL_CTL_MOD, c->fd, &e);
}

static void start_conn(struct thread *t, struct conn *c) {
	int one = 1;
	c->ident = t->next_ident;
	t->next_ident = (t->next_ident + 1) % src_count;
	c->fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
	if (c->fd < 0) { t->err[E_CONNECT]++; tick(0); return; }
	setsockopt(c->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
	if (have_src || sport_base) {
		struct sockaddr_in a = { .sin_family = AF_INET };
		if (have_src) a.sin_addr.s_addr = htonl(src_base + c->ident);
		setsockopt(c->fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
		if (sport_base) a.sin_port = htons(sport_base + c->slot);
		else setsockopt(c->fd, IPPROTO_IP, IP_BIND_ADDRESS_NO_PORT, &one, sizeof one);
		if (bind(c->fd, (struct sockaddr *)&a, sizeof a) < 0) { fail(t, c, E_CONNECT); return; }
	}
	c->t_start = now_us();
	c->deadline = c->t_start + (uint64_t)timeout_ms * 1000;
	c->reqs_done = 0;
	t->opened++;
	if (connect(c->fd, (struct sockaddr *)&target, sizeof target) < 0 && errno != EINPROGRESS) { fail(t, c, E_CONNECT); return; }
	c->state = S_CONNECTING;
	struct epoll_event e = { .events = EPOLLOUT, .data.ptr = c };
	epoll_ctl(t->ep, EPOLL_CTL_ADD, c->fd, &e);
}

/* 响应收全了返回 1，还没收全返回 0，出错返回负的错误类别减一。 */
static int parse(struct thread *t, struct conn *c) {
	char *end = memmem(c->in, c->inlen, "\r\n\r\n", 4);
	if (!end) return c->inlen >= RBUF - 1 ? -(E_HTTP + 1) : 0;
	int hdr = end + 4 - c->in, clen = 0;
	for (char *p = c->in; p < end; p++)
		if ((*p == 'c' || *p == 'C') && !strncasecmp(p, "content-length:", 15)) { clen = atoi(p + 15); break; }
	if (hdr + clen > RBUF - 1) return -(E_HTTP + 1);
	if (c->inlen < hdr + clen) return 0;
	if (c->inlen < 12 || memcmp(c->in + 9, "200", 3)) {
		/* 留几个样本：状态行和响应体的开头，换行换成空格 */
		if (t->nsample < 4) {
			int n = snprintf(t->sample[t->nsample], 160, "%.12s | %.120s", c->in, c->in + hdr);
			for (char *p = t->sample[t->nsample]; n > 0 && *p; p++) if (*p == '\r' || *p == '\n' || *p == '"' || *p == '\\') *p = ' ';
			t->nsample++;
		}
		return -(E_HTTP + 1);
	}
	if (have_expect) {
		char want[INET_ADDRSTRLEN], got[32] = "?";
		struct in_addr a = { htonl(expect_base + c->ident) };
		inet_ntop(AF_INET, &a, want, sizeof want);
		c->in[hdr + clen] = 0;
		char *p = strstr(c->in + hdr, "\"client\": \"");
		if (p) { p += 11; int n = strcspn(p, "\""); if (n > 31) n = 31; memcpy(got, p, n); got[n] = 0; }
		if (strcmp(got, want)) {
			if (t->nsample < 4) {
				char src[INET_ADDRSTRLEN]; struct in_addr s = { htonl(src_base + c->ident) };
				inet_ntop(AF_INET, &s, src, sizeof src);
				snprintf(t->sample[t->nsample++], 160, "%s 期望 %s 实际 %s", src, want, got);
			}
			return -(E_MISMATCH + 1);
		}
	}
	return 1;
}

static void *worker(void *arg) {
	struct thread *t = arg;
	struct epoll_event evs[512];
	uint64_t last_scan = now_us(), last_refill = last_scan;
	double per_thread_rate = rate / n_threads;
	int cursor = 0;
	t->ep = epoll_create1(0);
	for (;;) {
		uint64_t now = now_us();
		if (now >= t_end) break;
		/* 补充令牌，然后让空着的连接槽发起新的请求 */
		if (rate > 0) {
			t->tokens += per_thread_rate * (now - last_refill) / 1e6;
			if (t->tokens > per_thread_rate / 10 + 1) t->tokens = per_thread_rate / 10 + 1;
		}
		last_refill = now;
		/* 从上次停下的位置接着轮，令牌不够时后面的连接槽下一轮先得到，不会总是前面几条在用 */
		for (int k = 0; k < t->nconn; k++) {
			int i = (cursor + k) % t->nconn;
			struct conn *c = &t->conns[i];
			if (c->state != S_IDLE && c->state != S_WAIT) continue;
			if (rate > 0) { if (t->tokens < 1) { cursor = i; break; } t->tokens -= 1; }
			if (c->state == S_IDLE) start_conn(t, c); else send_request(t, c);
		}
		int n = epoll_wait(t->ep, evs, 512, rate > 0 ? 1 : 10);
		for (int i = 0; i < n; i++) {
			struct conn *c = evs[i].data.ptr;
			if (c->state == S_CONNECTING) {
				int err = 0; socklen_t l = sizeof err;
				getsockopt(c->fd, SOL_SOCKET, SO_ERROR, &err, &l);
				if (err || (evs[i].events & (EPOLLERR | EPOLLHUP))) { fail(t, c, E_CONNECT); continue; }
				send_request(t, c);
			} else if (c->state == S_READING) {
				int r = recv(c->fd, c->in + c->inlen, RBUF - 1 - c->inlen, 0);
				if (r < 0 && errno == EAGAIN) continue;
				if (r <= 0) { fail(t, c, E_RESET); continue; }
				c->inlen += r;
				int p = parse(t, c);
				if (p == 0) continue;
				if (p < 0) { fail(t, c, -p - 1); continue; }
				uint64_t us = now_us() - c->t_start;
				t->hist[us / 10 >= HIST ? HIST - 1 : us / 10]++;
				t->ok++;
				tick(1);
				c->reqs_done++;
				if (reqs_per_conn && c->reqs_done >= reqs_per_conn) close_conn(t, c);
				else if (rate > 0) c->state = S_WAIT;
				else send_request(t, c);
			} else if (c->state == S_WAIT && (evs[i].events & (EPOLLERR | EPOLLHUP | EPOLLIN))) {
				close_conn(t, c);   /* 空闲时被对端关掉，下次重新建连 */
			}
		}
		now = now_us();
		if (now - last_scan >= 20000) {
			last_scan = now;
			for (int i = 0; i < t->nconn; i++) {
				struct conn *c = &t->conns[i];
				if ((c->state == S_CONNECTING || c->state == S_READING) && now >= c->deadline) fail(t, c, E_TIMEOUT);
			}
		}
	}
	for (int i = 0; i < t->nconn; i++) if (t->conns[i].fd >= 0) close(t->conns[i].fd);
	return NULL;
}

static uint32_t ip(const char *s) {
	struct in_addr a;
	if (inet_pton(AF_INET, s, &a) != 1) { fprintf(stderr, "不是合法的地址：%s\n", s); exit(2); }
	return ntohl(a.s_addr);
}

int main(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		const char *k = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (!v) { fprintf(stderr, "%s 缺少参数\n", k); return 2; }
		i++;
		if (!strcmp(k, "--target")) {
			snprintf(target_str, sizeof target_str, "%s", v);
			char buf[64]; snprintf(buf, sizeof buf, "%s", v);
			char *colon = strchr(buf, ':');
			if (!colon) { fprintf(stderr, "--target 要写成 IP:端口\n"); return 2; }
			*colon = 0;
			target.sin_family = AF_INET; target.sin_addr.s_addr = htonl(ip(buf)); target.sin_port = htons(atoi(colon + 1));
		} else if (!strcmp(k, "--src-base")) { src_base = ip(v); have_src = 1; }
		else if (!strcmp(k, "--src-count")) src_count = strtoul(v, NULL, 10);
		else if (!strcmp(k, "--expect-base")) { expect_base = ip(v); have_expect = 1; }
		else if (!strcmp(k, "--conns")) n_conns = atoi(v);
		else if (!strcmp(k, "--threads")) n_threads = atoi(v);
		else if (!strcmp(k, "--duration")) duration = atoi(v);
		else if (!strcmp(k, "--reqs-per-conn")) reqs_per_conn = atoi(v);
		else if (!strcmp(k, "--rate")) rate = atof(v);
		else if (!strcmp(k, "--timeout")) timeout_ms = atoi(v);
		else if (!strcmp(k, "--sport-base")) sport_base = atoi(v);
		else if (!strcmp(k, "--timeline")) timeline_path = v;
		else if (!strcmp(k, "--host")) snprintf(host_hdr, sizeof host_hdr, "%s", v);
		else { fprintf(stderr, "不认识的选项 %s\n", k); return 2; }
	}
	if (!target.sin_port || src_count < 1 || n_conns < 1 || n_threads < 1) { fprintf(stderr, "用法见源文件开头\n"); return 2; }
	if (n_threads > n_conns) n_threads = n_conns;
	if (!host_hdr[0]) snprintf(host_hdr, sizeof host_hdr, "%s", target_str);
	request_len = snprintf(request, sizeof request, "GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: labload\r\n\r\n", host_hdr);
	signal(SIGPIPE, SIG_IGN);
	struct rlimit rl = { 1 << 20, 1 << 20 };
	setrlimit(RLIMIT_NOFILE, &rl);

	tl_n = duration * 10 + 10;
	tl_ok = calloc(tl_n, sizeof *tl_ok);
	tl_fail = calloc(tl_n, sizeof *tl_fail);
	struct timespec ws; clock_gettime(CLOCK_REALTIME, &ws);
	t0_wall = ws.tv_sec + ws.tv_nsec / 1e9;
	t0_mono = now_us();
	t_end = t0_mono + (uint64_t)duration * 1000000;

	struct thread *ts = calloc(n_threads, sizeof *ts);
	int slot = 0;
	for (int i = 0; i < n_threads; i++) {
		struct thread *t = &ts[i];
		t->id = i;
		t->nconn = n_conns / n_threads + (i < n_conns % n_threads);
		t->conns = calloc(t->nconn, sizeof *t->conns);
		for (int j = 0; j < t->nconn; j++) { t->conns[j].fd = -1; t->conns[j].slot = slot++; }
		t->hist = calloc(HIST, sizeof *t->hist);
		t->next_ident = (uint64_t)src_count * i / n_threads;
		pthread_create(&t->tid, NULL, worker, t);
	}
	uint64_t ok = 0, err[E_N] = { 0 }, opened = 0, errs = 0;
	uint32_t *hist = calloc(HIST, sizeof *hist);
	for (int i = 0; i < n_threads; i++) {
		pthread_join(ts[i].tid, NULL);
		ok += ts[i].ok; opened += ts[i].opened;
		for (int e = 0; e < E_N; e++) { err[e] += ts[i].err[e]; errs += ts[i].err[e]; }
		for (int b = 0; b < HIST; b++) hist[b] += ts[i].hist[b];
	}
	double secs = (now_us() - t0_mono) / 1e6;
	static const double Q[] = { 0.5, 0.9, 0.99, 0.999 };
	double q[4] = { 0 }; uint64_t acc = 0, maxb = 0; int qi = 0;
	for (int b = 0; b < HIST; b++) {
		if (!hist[b]) continue;
		acc += hist[b]; maxb = b;
		while (qi < 4 && acc >= Q[qi] * ok) q[qi++] = (b + 1) / 100.0;
	}
	printf("{\"target\": \"%s\", \"seconds\": %.2f, \"conns\": %d, \"threads\": %d, \"identities\": %u, \"reqs_per_conn\": %d, "
	       "\"ok\": %llu, \"errors\": %llu, \"rps\": %.0f, \"opened\": %llu, \"conn_per_s\": %.0f, "
	       "\"p50_ms\": %.2f, \"p90_ms\": %.2f, \"p99_ms\": %.2f, \"p999_ms\": %.2f, \"max_ms\": %.2f, \"t0\": %.3f",
	       target_str, secs, n_conns, n_threads, src_count, reqs_per_conn,
	       (unsigned long long)ok, (unsigned long long)errs, ok / secs, (unsigned long long)opened, opened / secs,
	       q[0], q[1], q[2], q[3], (maxb + 1) / 100.0, t0_wall);
	for (int e = 0; e < E_N; e++) printf(", \"err_%s\": %llu", ENAME[e], (unsigned long long)err[e]);
	printf(", \"samples\": [");
	int first = 1;
	for (int i = 0; i < n_threads; i++)
		for (int s = 0; s < ts[i].nsample; s++) { printf("%s\"%s\"", first ? "" : ", ", ts[i].sample[s]); first = 0; }
	printf("]}\n");
	if (timeline_path) {
		FILE *f = fopen(timeline_path, "w");
		if (f) {
			for (int i = 0; i < duration * 10; i++) fprintf(f, "%.1f %u %u\n", t0_wall + i / 10.0, tl_ok[i], tl_fail[i]);
			fclose(f);
		}
	}
	return 0;
}
