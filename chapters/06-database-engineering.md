# Section 6: Database Engineering

## Chapter 12: PostgreSQL Internals, Storage Engines, and Query Optimization

### Introduction

Understanding how databases work internally makes you a better engineer. You will make better indexing decisions, write better queries, design better schemas, and solve performance problems that others cannot.

This chapter covers PostgreSQL deeply — its storage format, transaction handling, indexing structures, and query planner. The concepts (B-trees, WAL, MVCC) apply to other databases too.

### MVCC — Multi-Version Concurrency Control

MVCC is how PostgreSQL allows concurrent reads and writes without locking readers. Instead of a single row version, PostgreSQL keeps multiple versions of each row. Each transaction sees a consistent snapshot of the database at a specific point in time.

**Every row in PostgreSQL has hidden system columns:**
- `xmin`: The transaction ID (XID) that inserted this row version
- `xmax`: The transaction ID that deleted/updated this row version (0 if still current)
- `ctid`: Physical location (page, offset) of this row version

```sql
-- See hidden MVCC columns
SELECT xmin, xmax, ctid, * FROM orders LIMIT 5;

-- When you UPDATE a row:
-- 1. Old row: xmax = current_txn_id
-- 2. New row: xmin = current_txn_id, xmax = 0
-- Both versions exist on disk until VACUUM removes the old one
```

**Transaction isolation using MVCC:**

```sql
-- Transaction 1 starts at time T1
BEGIN;
-- Snapshot: see all rows committed before T1

-- Transaction 2 updates a row at time T2
UPDATE orders SET status = 'CONFIRMED' WHERE id = 'order-123';
COMMIT;

-- Transaction 1 still sees the OLD version (from its snapshot)
SELECT status FROM orders WHERE id = 'order-123';
-- Returns: PENDING  (not CONFIRMED — MVCC gives transaction 1 its own view)

COMMIT; -- Transaction 1 ends
-- Now new transactions see CONFIRMED
```

**VACUUM — the MVCC cleanup process:**

Old row versions accumulate on disk. `VACUUM` removes dead tuples (rows that no older transaction can see). `AUTOVACUUM` does this automatically.

```sql
-- Manual vacuum (rarely needed if autovacuum is configured)
VACUUM ANALYZE orders;

-- Aggressive vacuum — reclaims disk space (blocks table briefly)
VACUUM FULL orders;

-- Check bloat and autovacuum status
SELECT
    relname AS table,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows,
    last_autovacuum,
    last_autoanalyze,
    round(n_dead_tup::numeric / nullif(n_live_tup, 0) * 100, 2) AS dead_pct
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```

**Transaction ID Wraparound — a critical PostgreSQL concern:**

XIDs are 32-bit integers — they wrap around after ~2 billion transactions. PostgreSQL uses modular arithmetic for XID comparison. If VACUUM doesn't run, old rows might become "future" transactions — they'd be invisible!

```sql
-- Check for XID wraparound risk (vacuum ASAP if age > 1 billion)
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- PostgreSQL will shut down if age > 1.6 billion (autovacuum_freeze_max_age)
-- vacuum_freeze_table_age triggers aggressive freeze
```

### Write-Ahead Logging (WAL)

WAL is PostgreSQL's durability mechanism. Every change is written to the WAL (a sequential log) BEFORE being applied to data pages. If PostgreSQL crashes, it can replay the WAL to recover.

```
Write sequence:
1. Write change to WAL (sequential write — very fast)
2. fsync() WAL to disk (durable)
3. Apply change to data buffer (in memory)
4. Eventually: write dirty data pages to disk (checkpoint)

Recovery sequence (after crash):
1. Find last checkpoint
2. Replay WAL from checkpoint to end of log
3. Undo incomplete transactions
4. Ready to serve requests
```

**WAL configuration for performance vs. durability:**

```sql
-- postgresql.conf settings

-- Synchronous commit (default: on)
-- on: wait for WAL flush before returning to client (full durability)
-- off: don't wait for WAL flush (faster, but 1-few commits can be lost on crash)
-- local: wait for local WAL flush but not replicas
synchronous_commit = on

-- WAL buffer size (in memory)
wal_buffers = 64MB               -- default: -1 (auto)

-- Checkpoint settings
checkpoint_completion_target = 0.9   -- Spread checkpoint I/O over 90% of checkpoint interval
checkpoint_timeout = 5min            -- At least one checkpoint every 5 minutes
max_wal_size = 4GB                   -- WAL grows up to 4GB between checkpoints

-- For maximum write performance (risk: lose last few transactions on crash)
synchronous_commit = off
```

### B-Tree Internals

B-Trees are the default index structure in PostgreSQL (and most databases). Understanding them helps you design better indexes.

**Structure:**
```
Root Page
├── Internal Page (pointer + key)
│   ├── Leaf Page [1, 3, 5, 7] → actual TIDs (table row pointers)
│   └── Leaf Page [9, 11, 13] → actual TIDs
└── Internal Page
    ├── Leaf Page [15, 17, 19] → actual TIDs
    └── Leaf Page [21, 23, 25] → actual TIDs
```

- **Leaf pages**: Store actual index entries (key + TID — table row pointer)
- **Internal pages**: Store keys and pointers to child pages
- **Height**: Typically 3-4 levels for millions of rows (log₄₀₉₆(n) levels)
- **Balanced**: All leaf pages are at the same depth
- **Doubly linked**: Leaves are linked for efficient range scans

**B-Tree vs LSM Tree:**

| Property | B-Tree | LSM Tree |
|---|---|---|
| Read performance | Fast | Slower (SSTable merge) |
| Write performance | Moderate | Faster (append-only) |
| Space amplification | Low | Higher |
| Write amplification | Moderate | Higher |
| Used by | PostgreSQL, MySQL | Cassandra, LevelDB, RocksDB |

**LSM Tree internals (Cassandra):**

```
Write path:
1. Write to MemTable (in-memory write buffer) — very fast
2. Write to CommitLog (WAL equivalent) — sequential disk write
3. When MemTable fills: flush to SSTable (Sorted String Table) on disk

Read path:
1. Check MemTable (most recent)
2. Check Bloom filter for each SSTable (probably not there?)
3. Read from SSTable(s) — merge if key exists in multiple SSTables
4. Compaction: periodically merge SSTables (reduce read amplification)
```

### Indexing Strategy

**Creating the right index is the single highest-impact database optimization.**

**B-Tree index basics:**

```sql
-- Simple index
CREATE INDEX CONCURRENTLY idx_orders_customer_id ON orders (customer_id);

-- Composite index (order matters!)
-- Covers queries on: (customer_id), (customer_id, status), (customer_id, status, created_at)
-- Does NOT cover queries on: (status) alone, (status, customer_id)
CREATE INDEX CONCURRENTLY idx_orders_customer_status_created
    ON orders (customer_id, status, created_at DESC);

-- Partial index — only index rows matching a condition
-- Smaller, faster, covers only the queries you care about
CREATE INDEX CONCURRENTLY idx_orders_pending
    ON orders (created_at)
    WHERE status = 'PENDING';

-- Expression index — index the result of an expression
CREATE INDEX CONCURRENTLY idx_orders_lower_email
    ON customers (lower(email));

-- Covering index — store additional columns to avoid table lookup
-- (index-only scan)
CREATE INDEX CONCURRENTLY idx_orders_covering
    ON orders (customer_id, created_at)
    INCLUDE (status, total_amount);
```

**Understanding EXPLAIN ANALYZE:**

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT o.id, o.status, o.total_amount, c.email
FROM orders o
JOIN customers c ON o.customer_id = c.id
WHERE o.customer_id = 'cust-123'
  AND o.status IN ('PENDING', 'CONFIRMED')
  AND o.created_at > NOW() - INTERVAL '30 days'
ORDER BY o.created_at DESC
LIMIT 100;
```

**Reading an execution plan:**

```
Sort (cost=2348.12..2349.75 rows=651 width=64) (actual time=8.234..8.312 rows=47 loops=1)
  Sort Key: o.created_at DESC
  Sort Method: quicksort  Memory: 30kB
  ->  Hash Join (cost=1243.20..2318.45 rows=651 width=64) (actual time=6.123..8.102 rows=47 loops=1)
        Hash Cond: (o.customer_id = c.id)
        Buffers: shared hit=234 read=12  <-- 234 pages from cache, 12 from disk
        ->  Index Scan using idx_orders_customer_status_created on orders o
              (cost=0.57..1064.32 rows=651 width=48) (actual time=0.024..5.890 rows=47 loops=1)
              Index Cond: ((customer_id = 'cust-123') AND (status = ANY ('{PENDING,CONFIRMED}'::text[])))
              Filter: (created_at > (now() - '30 days'::interval))
        ->  Hash (cost=987.32..987.32 rows=20432 width=24) (actual time=4.123..4.123 rows=20432 loops=1)
              Buckets: 32768  Batches: 1  Memory Usage: 1234kB
              ->  Seq Scan on customers c  (cost=0.00..987.32 rows=20432 width=24)
```

**Key metrics:**
- `cost=X..Y`: Estimated cost (X = startup cost, Y = total cost)
- `actual time=X..Y`: Actual time in milliseconds
- `rows=N`: Actual rows produced
- `Buffers: shared hit=X read=Y`: Cache hits vs disk reads
- Large `rows` with small `actual rows` = bad estimate (stale statistics?)

**Common query optimization techniques:**

```sql
-- 1. Use RETURNING to avoid extra SELECT
INSERT INTO orders (customer_id, total) VALUES ($1, $2)
RETURNING id, created_at;

-- 2. Use CTEs for clarity (but check if materialized affects performance)
WITH recent_orders AS MATERIALIZED (  -- Force materialization
    SELECT * FROM orders
    WHERE created_at > NOW() - INTERVAL '7 days'
)
SELECT customer_id, COUNT(*) FROM recent_orders GROUP BY customer_id;

-- 3. Bulk insert with unnest (much faster than individual INSERTs)
INSERT INTO order_items (order_id, product_id, quantity, price)
SELECT *
FROM unnest(
    $1::uuid[],
    $2::uuid[],
    $3::int[],
    $4::numeric[]
) AS t(order_id, product_id, quantity, price);

-- 4. Use connection pooling (PgBouncer) — database connections are expensive
-- Max connections: max_connections = 200 (default)
-- Each connection uses ~5-10MB memory
-- PgBouncer: pool 1000 app connections → 50 actual DB connections

-- 5. Statistics and vacuum
ANALYZE orders;  -- Update statistics (for query planner)
-- Or auto-analyze handles this if autovacuum is configured

-- 6. Partition large tables
CREATE TABLE orders (
    id UUID DEFAULT gen_random_uuid(),
    created_at TIMESTAMP NOT NULL,
    status VARCHAR(50),
    total_amount NUMERIC(19,4)
) PARTITION BY RANGE (created_at);

CREATE TABLE orders_2024_q1 PARTITION OF orders
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');

CREATE TABLE orders_2024_q2 PARTITION OF orders
    FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');

-- With partition pruning, queries on date ranges only scan relevant partitions
```

### Cassandra Internals

Cassandra is a wide-column, distributed database designed for write-heavy workloads with high availability.

**Data model:**
```
Keyspace (database) → Table → Partition → Rows → Columns

Partition key determines which node stores the data (hash-based routing)
Clustering columns determine ordering within a partition
```

**Design rules for Cassandra:**
1. **Design for queries**: Unlike relational, you design tables around your queries
2. **No joins**: Denormalize — store data together that is queried together
3. **No GROUP BY**: Pre-aggregate or use multiple tables
4. **Partition key must be in every query**: You cannot filter without it

```java
// Cassandra table design
// Query: "Get all orders for a customer, ordered by date, filtered by status"

// WRONG: Don't design by entity
CREATE TABLE orders_wrong (
    id UUID PRIMARY KEY,  -- Random partition — poor locality
    customer_id UUID,
    status TEXT,
    created_at TIMESTAMP
);

// RIGHT: Design by query pattern
CREATE TABLE orders_by_customer (
    customer_id UUID,         -- Partition key — all orders for customer on same node
    created_at TIMESTAMP,     -- Clustering key — sorted by date
    status TEXT,              -- Clustering key for filtering
    order_id UUID,
    total_amount DECIMAL,
    PRIMARY KEY ((customer_id), created_at, status, order_id)
) WITH CLUSTERING ORDER BY (created_at DESC, status ASC);

// Java query
Mono<List<OrderSummary>> findCustomerOrders(UUID customerId, String status) {
    Select query = QueryBuilder.selectFrom("orders_by_customer")
        .all()
        .whereColumn("customer_id").isEqualTo(QueryBuilder.literal(customerId))
        .whereColumn("status").isEqualTo(QueryBuilder.literal(status))
        .limit(100);

    return Mono.fromCompletionStage(
        session.executeAsync(query.build()
            .setConsistencyLevel(ConsistencyLevel.LOCAL_QUORUM))
    ).map(rs -> rs.all().stream()
        .map(this::mapToOrderSummary)
        .collect(Collectors.toList()));
}
```

**Cassandra consistency levels:**

```java
// LOCAL_QUORUM = majority of replicas in the local DC
// Use this for normal operations — good balance

// ALL = all replicas must respond (highest consistency, lowest availability)
// Use for critical financial operations

// ONE = just one replica (fastest, lowest consistency)
// Use for metrics, logs, analytics where occasional staleness is OK

// For most applications:
// Writes: LOCAL_QUORUM
// Reads: LOCAL_QUORUM
// This gives strong consistency within a DC and handles 1 replica failure
```

### Database Connection Pooling

Every database connection uses resources. PostgreSQL handles connections with processes (~5-10MB each). At scale, you need connection pooling.

**HikariCP configuration (Spring Boot default):**

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 20          # Max connections in pool
      minimum-idle: 5                # Keep 5 connections open always
      connection-timeout: 30000      # Wait up to 30s for a connection
      idle-timeout: 600000           # Close idle connections after 10min
      max-lifetime: 1800000          # Recreate connections after 30min
      keepalive-time: 300000         # Send keepalive after 5min idle
      pool-name: OrderDB
      leak-detection-threshold: 60000 # Warn if connection held > 60s
      connection-test-query: SELECT 1  # Test connection before use
```

**PgBouncer — proxy-level connection pooling:**

When you have many application instances (50+ pods), each with a pool of 20 connections, you can exceed PostgreSQL's `max_connections`. PgBouncer sits between your app and PostgreSQL, multiplexing many app connections to fewer DB connections.

```ini
# pgbouncer.ini
[databases]
orders = host=postgres-primary port=5432 dbname=orders

[pgbouncer]
listen_port = 6432
listen_addr = *
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

# Pool mode:
# session: one server connection per client session (default, safest)
# transaction: connection returned to pool after each transaction (most efficient)
# statement: connection returned after each statement (breaks multi-statement transactions)
pool_mode = transaction

max_client_conn = 10000          # Max clients connecting to pgbouncer
default_pool_size = 50           # Max server connections per database/user pair
reserve_pool_size = 10           # Emergency reserve

# Useful for high connection counts:
server_idle_timeout = 600        # Close idle server connections after 10min
server_lifetime = 3600           # Recreate server connections after 1 hour
```

### Database Scaling Patterns

**Read replicas:**
```
                     ┌─────────────────────┐
 Writes ──────────→  │    Primary (Leader)  │
                     └─────────────────────┘
                              │ Streaming replication
                    ┌─────────┴──────────┐
                    ↓                    ↓
          ┌─────────────────┐  ┌─────────────────┐
 Reads ─→ │ Read Replica 1  │  │ Read Replica 2  │ ←─ Reads
          └─────────────────┘  └─────────────────┘
```

**Spring configuration to route reads to replicas:**

```java
@Configuration
public class DataSourceConfig {

    @Bean
    @Primary
    public DataSource dataSource() {
        AbstractRoutingDataSource routingDataSource = new ReadWriteRoutingDataSource();

        Map<Object, Object> targetDataSources = new HashMap<>();
        targetDataSources.put("primary", primaryDataSource());
        targetDataSources.put("replica1", replica1DataSource());
        targetDataSources.put("replica2", replica2DataSource());

        routingDataSource.setTargetDataSources(targetDataSources);
        routingDataSource.setDefaultTargetDataSource(primaryDataSource());
        return routingDataSource;
    }
}

public class ReadWriteRoutingDataSource extends AbstractRoutingDataSource {
    @Override
    protected Object determineCurrentLookupKey() {
        return TransactionSynchronizationManager.isCurrentTransactionReadOnly()
            ? "replica" + (Math.random() < 0.5 ? "1" : "2") // simple round-robin
            : "primary";
    }
}

// Usage: @Transactional(readOnly = true) → routes to replica
@Transactional(readOnly = true)
public List<Order> findRecentOrders(String customerId) {
    return orderRepository.findByCustomerId(customerId); // goes to replica
}

@Transactional  // readOnly=false → routes to primary
public Order placeOrder(PlaceOrderCommand cmd) {
    return orderRepository.save(Order.create(cmd)); // goes to primary
}
```

### Interview Questions

**Q: What is the N+1 query problem and how do you fix it?**

A: The N+1 problem happens when you load N entities and then make 1 additional query for each entity's related data. Example: load 100 orders, then for each order load its items — 1 + 100 = 101 queries. Fix: (1) Use `JOIN FETCH` in JPQL to fetch related data in one query. (2) Use `@EntityGraph` to specify what to load eagerly. (3) Use batch loading — Spring Data JPA can batch N+1 into a few IN queries. (4) Never use `spring.jpa.open-in-view=true` in production — it hides the N+1 problem by keeping the session open through the HTTP request.

**Q: What is MVCC and how does it affect reads?**

A: Multi-Version Concurrency Control keeps multiple versions of each row. When a transaction reads data, it sees a consistent snapshot from the time the transaction started — regardless of concurrent writes. This means reads never block writes and writes never block reads. The tradeoff: disk space grows with accumulated old versions until VACUUM cleans them up. It also means a long-running transaction can prevent VACUUM from reclaiming space (transaction ID wraparound risk).

**Q: How would you design a schema for a multi-tenant SaaS application?**

A: Three approaches: (1) Shared table with tenant_id column — simplest, but data is co-mingled and RLS (Row Level Security) is needed for isolation. (2) Separate schema per tenant — medium isolation, schemas share PostgreSQL resources but data is separated. (3) Separate database per tenant — strongest isolation, highest operational overhead. For most SaaS: use shared tables with a `tenant_id` on every table, add it to all indexes, use PostgreSQL RLS (`CREATE POLICY`) to enforce isolation at the database level, and set the tenant context in connection setup (`SET app.tenant_id = $1`).

---
