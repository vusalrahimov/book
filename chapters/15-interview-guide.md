# Chapter 23: Senior Engineer Interview Guide

## Introduction

This chapter consolidates the most important interview questions for senior Java backend, distributed systems, and platform engineering roles. Questions are organized by topic with model answers.

## System Design Questions

### Design a Payment Processing System

**Requirements:**
- Process 1,000 payments/second
- Zero money lost (exactly-once)
- Audit trail for compliance
- Sub-second processing
- Multi-currency, multi-country

**Model Answer:**

```
Key properties:
1. Idempotency — retries must not double-charge
2. Exactly-once — use Kafka transactions or DB idempotency keys
3. Audit trail — immutable event store
4. High availability — active-active, multi-region

Architecture:
┌─────────────────────────────────────────────┐
│  API Gateway (rate limiting, auth)          │
└─────────────────┬───────────────────────────┘
                  │
┌─────────────────▼───────────────────────────┐
│  Payment Service                            │
│  - Idempotency check (Redis)                │
│  - Business validation                      │
│  - Write to Outbox table (Postgres)         │
│  - Publish via Debezium → Kafka             │
└─────────────────────────────────────────────┘
                  │
        ┌─────────┴──────────┐
        │                    │
┌───────▼──────┐   ┌─────────▼──────┐
│ Fraud         │   │ Payment Gateway│
│ Detection     │   │ Stripe/Adyen   │
│ (Flink)       │   └────────────────┘
└───────────────┘
                  │
┌─────────────────▼───────────────────────────┐
│  Event Store (Kafka + Cassandra)            │
│  Immutable ledger — append only             │
└─────────────────────────────────────────────┘

Idempotency:
- Clients send Idempotency-Key header
- Redis stores results for 24 hours
- Same key → return same result, no double charge

Exactly-once:
- Outbox pattern: DB write + event are atomic
- Kafka exactly-once transactions for consumers
- Stripe webhook: process idempotently using event ID
```

### Design a Rate Limiter

**Model Answer:**

```
Algorithms:

1. Token Bucket:
   - Bucket holds up to N tokens
   - Tokens refill at R rate/second
   - Each request consumes 1 token
   - If empty: reject request
   - Allows bursts up to N
   - Good for: most APIs

2. Sliding Window Log:
   - Store timestamp of each request in Redis sorted set
   - Remove timestamps older than window
   - Count remaining = current requests in window
   - Accurate but memory-intensive (stores all timestamps)

3. Fixed Window Counter:
   - Counter per time window (e.g., per minute)
   - Simple but boundary problem: user can do 200 in 2 windows

4. Sliding Window Counter:
   - Weighted average of current + previous window
   - Good accuracy, memory efficient

Implementation (Redis + Lua for atomicity):
```

```java
@Service
public class SlidingWindowRateLimiter {
    private final RedisTemplate<String, String> redis;

    public boolean isAllowed(String userId, int limit, Duration window) {
        String key = "rate:" + userId;
        long now = System.currentTimeMillis();
        long windowStart = now - window.toMillis();

        // Atomic Lua script: remove old entries, count, add current
        String luaScript = """
            local key = KEYS[1]
            local now = tonumber(ARGV[1])
            local window = tonumber(ARGV[2])
            local limit = tonumber(ARGV[3])
            local clearBefore = now - window

            redis.call('ZREMRANGEBYSCORE', key, 0, clearBefore)
            local count = redis.call('ZCARD', key)

            if count < limit then
                redis.call('ZADD', key, now, now)
                redis.call('EXPIRE', key, math.ceil(window / 1000) + 1)
                return 1
            end
            return 0
            """;

        Long result = redis.execute(
            new DefaultRedisScript<>(luaScript, Long.class),
            List.of(key),
            String.valueOf(now),
            String.valueOf(window.toMillis()),
            String.valueOf(limit)
        );

        return Long.valueOf(1L).equals(result);
    }
}
```

## Java Deep-Dive Questions

**Q: What is the difference between `String`, `StringBuilder`, and `StringBuffer`?**

A: `String` is immutable — every operation creates a new object. `StringBuilder` is mutable, not thread-safe, but fast. `StringBuffer` is mutable and thread-safe (synchronized methods) but slower. In practice: use `String` for constants and values. Use `StringBuilder` in single-threaded code that builds strings in loops. Never use `StringBuffer` — if you need thread-safety at the string level, you have a design problem; use locks at a higher level.

**Q: What is the difference between `==` and `.equals()` for Strings?**

A: `==` compares object identity (same reference). `.equals()` compares content. Due to String interning (`String.intern()`), string literals with the same value often share the same object, so `==` sometimes returns `true` — but this is an implementation detail you cannot rely on. Always use `.equals()` for string comparison. Always use `Objects.equals(a, b)` when `a` might be null.

**Q: Explain `HashMap` internals.**

A: `HashMap` uses an array of linked lists (or tree nodes for large buckets). The key's `hashCode()` determines the bucket index: `(n - 1) & hash`. If multiple keys hash to the same bucket (collision), they form a linked list. When a bucket exceeds `TREEIFY_THRESHOLD` (8 entries), it converts to a red-black tree for O(log n) lookup. Default initial capacity: 16. Default load factor: 0.75 (resizes when 75% full). Resizing copies all entries to a new, larger array — O(n) operation. Java 8+ improvement: tree buckets prevent worst-case O(n) to O(log n).

**Q: What is a memory barrier and when does Java need them?**

A: A memory barrier is a CPU instruction that prevents reordering of memory operations across it. CPUs and compilers reorder instructions for performance — this is invisible in single-threaded code but causes bugs in multi-threaded code. Java needs barriers: `volatile` reads/writes have full barriers. `synchronized` has barriers on entry (acquire) and exit (release). `AtomicInteger.set()` uses a release barrier. Without barriers, CPU cache lines may not be flushed to main memory, making writes invisible to other threads.

## Distributed Systems Questions

**Q: How would you implement distributed rate limiting across 100 microservice instances?**

A: Centralized rate limiting with Redis. Each service instance sends requests through a Redis Lua script that atomically checks and increments a counter. The counter key includes the user ID and time window. Redis handles concurrency — all 100 instances share the same counter. For resilience: if Redis is unavailable, fail open (allow requests) or fail closed (reject) depending on business requirements. For extreme scale: use Redis Cluster, or consider a hierarchical approach where each instance does local rate limiting (fast) and periodically syncs with Redis for global limits.

**Q: What is the "exactly-once" problem in distributed systems?**

A: In a distributed system, a producer sends a message and the network fails before getting an acknowledgement. The producer doesn't know if the message was received. If it retries: at-least-once (might deliver twice). If it doesn't retry: at-most-once (might lose the message). Exactly-once requires: (1) Idempotent operations — safe to call multiple times with same result. (2) Unique message IDs — detect and discard duplicates at the receiver. (3) Two-phase commit or distributed transactions — expensive. In Kafka: idempotent producer + transactions solve exactly-once for produce. For consume-process-produce: Kafka transactions wrap offset commit + produce.

**Q: How do you handle a partial database migration in production?**

A: Never do a big-bang schema migration in production. Use Expand-Contract pattern: (1) Expand: add new column/table alongside old one. Deploy application that writes to BOTH old and new. (2) Migrate: backfill data from old to new. Can be done online with batches. (3) Contract: once all data is migrated and verified, remove the old column/table. Each step is a separate deployment. Blue-green deployment between steps. Tools: Flyway with repeatable migrations. Always: have a rollback plan. Always: test on a copy of production data first.

## Architecture Questions

**Q: When should you use a monolith vs. microservices?**

A: Start with a monolith. Microservices are justified when: teams are large enough that coordination costs of a monolith outweigh distribution costs (rough guide: team too large for 2 pizzas per service). Different services need different scaling — one service needs 100x the instances of another. Different services need different technology stacks. You need independent deployment velocity — teams cannot coordinate releases. Signals that microservices are wrong: services that always deploy together (distributed monolith). Lots of synchronous inter-service calls (tight coupling). You struggle to define boundaries (premature extraction).

**Q: What is the strangler fig pattern?**

A: A migration strategy from monolith to microservices. Like a strangler fig plant that grows around a tree and replaces it. Approach: (1) Put a facade/proxy in front of the monolith. (2) Implement new functionality as new services (not in the monolith). (3) Gradually move existing functionality: new service handles the feature, proxy routes traffic from monolith to service. (4) Eventually the monolith is "strangled" — all traffic goes to services. Benefits: no big-bang rewrite, business keeps working throughout, rollback is possible at any point.

## Kubernetes Questions

**Q: A pod is in CrashLoopBackOff. How do you debug it?**

A: Systematic debugging: (1) `kubectl describe pod <name>` — check Events section for error messages, exit code, OOMKilled. (2) `kubectl logs <pod> --previous` — logs from the last failed container. (3) Exit code 1: application error. Exit code 137: OOMKilled (increase memory limit). Exit code 139: SIGSEGV/segfault (JVM crash). Exit code 255 often: container couldn't start. (4) If no logs: the container crashes before writing logs — check if liveness probe is misconfigured, if the command is wrong, if the image doesn't exist. (5) Temporarily override the command: `kubectl debug pod/name -it --image=busybox -- sh` to inspect the pod.

**Q: How does Kubernetes handle rolling updates?**

A: With `RollingUpdate` strategy: (1) Kubernetes creates a new ReplicaSet with the new image. (2) It incrementally scales up the new RS while scaling down the old RS. (3) `maxSurge`: how many extra pods can exist during update (e.g., `1` = one extra pod). (4) `maxUnavailable`: how many pods can be unavailable (e.g., `0` = never less than desired count). With `maxSurge=1, maxUnavailable=0` and 3 replicas: you'll have 4 pods during the update (3 old + 1 new), and new pods must be Ready before old ones are terminated. Readiness probes are critical — a pod is only removed from load balancer rotation when it fails readiness.

## Observability Questions

**Q: Your service has high latency. Walk through how you investigate it.**

A: Structured investigation: (1) **Metrics first**: Check Grafana — is it affecting all endpoints or specific ones? Is it all users or specific regions? Is CPU/memory high? (2) **Traces**: Find slow traces in Jaeger. Which span is slow? Is it DB, external service, or in-process? (3) **If slow DB span**: Check PostgreSQL slow query log. EXPLAIN ANALYZE the slow query. Missing index? N+1 queries? Lock contention? (4) **If slow external service**: Check the downstream service's metrics. Is their SLO degraded? (5) **If in-process**: Use async-profiler to find CPU hotspots. Check JVM GC logs for pauses. (6) **Thread pool**: Is the thread pool exhausted? Check `active_threads / max_threads` metric. (7) **Connection pool**: HikariCP connection timeout indicates DB connection saturation.

**Q: What is the four golden signals of monitoring?**

A: From Google SRE book: (1) **Latency**: How long it takes to service a request. Measure both successful and failed requests (failed fast is not the same as latency). (2) **Traffic**: How much demand is being placed on your system. Requests per second, queries per second. (3) **Errors**: The rate of requests that fail. 5xx errors, timeouts, business logic failures. (4) **Saturation**: How "full" your service is. CPU, memory, thread pool, DB connections — the resources most likely to constrain performance. Monitor these four for every service.

## Scenario Questions

**Q: You wake up at 3am to a PagerDuty alert: "Order service error rate is 50%." What do you do?**

A:
1. Acknowledge in PagerDuty to stop escalation
2. Check dashboards: When did it start? What changed? (Recent deploys? Traffic spike?)
3. Check pod status: `kubectl get pods -n production -l app=order-service`
4. Check logs: `kubectl logs -l app=order-service --tail=100 | grep ERROR`
5. Check dependencies: Is the database up? Is Kafka healthy? Is the payment service responding?
6. Quick win: If recent deploy caused it, rollback: `kubectl rollout undo deploy/order-service`
7. If not a deploy issue: Check if it's a traffic spike — scale up: `kubectl scale deploy order-service --replicas=10`
8. Update status page every 10 minutes
9. When resolved: document what happened, schedule post-mortem
10. Root cause must be identified and fixed before closing the incident

**Q: How do you handle a database that is 90% full and growing fast?**

A: Immediate actions: (1) Alert the team — do not wait for 100%. (2) Identify what's growing fastest: `SELECT pg_size_pretty(pg_relation_size(relid)), relname FROM pg_stat_user_tables ORDER BY pg_relation_size(relid) DESC LIMIT 10;`. (3) Check for table bloat (dead tuples): run VACUUM ANALYZE. (4) Check for missing indexes causing sequential scans that write temp files. Medium-term: (5) Archive old data to cold storage (S3). (6) Add more disk or upgrade instance. (7) Implement data retention policies (delete records older than X). (8) Enable compression if using PostgreSQL 14+ (TOAST compression, table compression). Long-term: (9) Consider partitioning (time-based for time-series data). (10) Evaluate archival database (Cassandra or Redshift for historical data).

---

## Quick Reference: Decision Framework

**Choose SQL when:**
- Transactions and ACID compliance are required
- Complex queries with JOINs
- Data structure is well-defined
- Relational data model fits naturally

**Choose Cassandra when:**
- Extreme write throughput (millions/sec)
- Time-series or append-heavy data
- Multi-datacenter with active-active
- Query patterns are known and limited

**Choose Redis when:**
- Caching
- Rate limiting
- Distributed locks
- Leaderboards and counters
- Session storage

**Choose Kafka when:**
- Event streaming between services
- High-throughput message passing
- Event sourcing
- CDC (Change Data Capture)
- Multiple consumers of the same data

**Choose gRPC when:**
- Service-to-service (internal) communication
- Strong typing needed
- High performance (binary protocol)
- Streaming required

**Choose REST when:**
- Public APIs
- Browser clients
- Simplicity preferred over performance
- Wide ecosystem support needed

---
