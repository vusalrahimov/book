-- =============================================================================
-- Enterprise Order Management Schema
-- PostgreSQL 16+
-- =============================================================================

-- Enable useful extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";     -- For text search
CREATE EXTENSION IF NOT EXISTS "btree_gin";   -- For GIN indexes on scalar types
CREATE EXTENSION IF NOT EXISTS "vector";      -- pgvector for AI

-- =============================================================================
-- Schema Setup
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS orders;
CREATE SCHEMA IF NOT EXISTS audit;
SET search_path = orders, public;

-- =============================================================================
-- Core Tables
-- =============================================================================

-- Customers
CREATE TABLE customers (
    id              UUID            DEFAULT gen_random_uuid() PRIMARY KEY,
    external_id     VARCHAR(255)    UNIQUE NOT NULL,          -- From identity provider
    email           VARCHAR(320)    UNIQUE NOT NULL,
    email_verified  BOOLEAN         NOT NULL DEFAULT FALSE,
    first_name      VARCHAR(100)    NOT NULL,
    last_name       VARCHAR(100)    NOT NULL,
    phone           VARCHAR(20),
    tier            VARCHAR(20)     NOT NULL DEFAULT 'STANDARD'
                                    CHECK (tier IN ('STANDARD', 'PREMIUM', 'VIP')),
    locale          VARCHAR(10)     NOT NULL DEFAULT 'en',
    timezone        VARCHAR(50)     NOT NULL DEFAULT 'UTC',
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,                               -- Soft delete
    version         BIGINT          NOT NULL DEFAULT 0        -- Optimistic locking
);

-- Index for common lookups
CREATE INDEX CONCURRENTLY idx_customers_email
    ON customers (lower(email))
    WHERE deleted_at IS NULL;

CREATE INDEX CONCURRENTLY idx_customers_external_id
    ON customers (external_id)
    WHERE deleted_at IS NULL;

-- Products
CREATE TABLE products (
    id              UUID            DEFAULT gen_random_uuid() PRIMARY KEY,
    sku             VARCHAR(100)    UNIQUE NOT NULL,
    name            VARCHAR(500)    NOT NULL,
    description     TEXT,
    category        VARCHAR(100)    NOT NULL,
    price_amount    NUMERIC(19, 4)  NOT NULL CHECK (price_amount >= 0),
    price_currency  CHAR(3)         NOT NULL DEFAULT 'USD',
    weight_grams    INTEGER,
    active          BOOLEAN         NOT NULL DEFAULT TRUE,
    metadata        JSONB           NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX CONCURRENTLY idx_products_sku ON products (sku) WHERE active = TRUE;
CREATE INDEX CONCURRENTLY idx_products_category ON products (category) WHERE active = TRUE;
CREATE INDEX CONCURRENTLY idx_products_name_trgm ON products USING gin (name gin_trgm_ops);

-- Orders (partitioned by month for scalability)
CREATE TABLE orders (
    id              UUID            DEFAULT gen_random_uuid(),
    customer_id     UUID            NOT NULL REFERENCES customers(id),
    status          VARCHAR(20)     NOT NULL DEFAULT 'PENDING'
                                    CHECK (status IN ('PENDING', 'CONFIRMED', 'PROCESSING',
                                                      'SHIPPED', 'DELIVERED', 'CANCELLED', 'REFUNDED')),
    subtotal_amount NUMERIC(19, 4)  NOT NULL CHECK (subtotal_amount >= 0),
    discount_amount NUMERIC(19, 4)  NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    tax_amount      NUMERIC(19, 4)  NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    total_amount    NUMERIC(19, 4)  NOT NULL CHECK (total_amount >= 0),
    currency        CHAR(3)         NOT NULL DEFAULT 'USD',
    payment_method  VARCHAR(50),
    idempotency_key VARCHAR(255)    UNIQUE,                    -- Prevent duplicate orders
    notes           TEXT,
    metadata        JSONB           NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id, created_at)                               -- Include partition key
) PARTITION BY RANGE (created_at);

-- Create monthly partitions (automate this with pg_partman in production)
CREATE TABLE orders_2024_01 PARTITION OF orders
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE orders_2024_02 PARTITION OF orders
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
CREATE TABLE orders_2024_03 PARTITION OF orders
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');
-- ... continue for all months

-- Default partition for any future months
CREATE TABLE orders_future PARTITION OF orders
    FOR VALUES FROM ('2025-01-01') TO (MAXVALUE);

-- Indexes on partitioned table (created on all partitions)
CREATE INDEX CONCURRENTLY idx_orders_customer_id
    ON orders (customer_id, created_at DESC)
    WHERE status != 'CANCELLED';

CREATE INDEX CONCURRENTLY idx_orders_status_created
    ON orders (status, created_at DESC);

CREATE INDEX CONCURRENTLY idx_orders_idempotency
    ON orders (idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- Order Items
CREATE TABLE order_items (
    id              UUID            DEFAULT gen_random_uuid() PRIMARY KEY,
    order_id        UUID            NOT NULL,
    order_created   TIMESTAMPTZ     NOT NULL,                  -- For partition-aware FK
    product_id      UUID            NOT NULL REFERENCES products(id),
    sku             VARCHAR(100)    NOT NULL,
    product_name    VARCHAR(500)    NOT NULL,                  -- Denormalized (snapshot)
    quantity        INTEGER         NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(19, 4)  NOT NULL CHECK (unit_price >= 0),
    discount_pct    NUMERIC(5, 2)   NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 100),
    line_total      NUMERIC(19, 4)  NOT NULL CHECK (line_total >= 0),
    FOREIGN KEY (order_id, order_created) REFERENCES orders (id, created_at)
);

CREATE INDEX CONCURRENTLY idx_order_items_order
    ON order_items (order_id);

-- =============================================================================
-- Outbox Pattern — Reliable Event Publishing
-- =============================================================================

CREATE TABLE outbox_events (
    id              UUID            DEFAULT gen_random_uuid() PRIMARY KEY,
    aggregate_type  VARCHAR(100)    NOT NULL,   -- 'Order', 'Customer', etc.
    aggregate_id    VARCHAR(255)    NOT NULL,
    event_type      VARCHAR(100)    NOT NULL,   -- 'OrderCreated', 'OrderCancelled', etc.
    event_version   INTEGER         NOT NULL DEFAULT 1,
    payload         JSONB           NOT NULL,
    headers         JSONB           NOT NULL DEFAULT '{}',
    status          VARCHAR(20)     NOT NULL DEFAULT 'PENDING'
                                    CHECK (status IN ('PENDING', 'PUBLISHED', 'FAILED')),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    published_at    TIMESTAMPTZ,
    error_message   TEXT
);

-- Debezium reads from this table (via WAL) and publishes to Kafka
CREATE INDEX CONCURRENTLY idx_outbox_pending
    ON outbox_events (created_at)
    WHERE status = 'PENDING';

-- =============================================================================
-- Audit Log — Immutable History
-- =============================================================================

CREATE TABLE audit.audit_log (
    id              BIGSERIAL       PRIMARY KEY,
    table_name      VARCHAR(100)    NOT NULL,
    record_id       UUID            NOT NULL,
    operation       VARCHAR(10)     NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    old_values      JSONB,
    new_values      JSONB,
    changed_by      VARCHAR(255),   -- User ID or service name
    changed_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    session_id      TEXT,
    ip_address      INET
);

-- Audit trigger function
CREATE OR REPLACE FUNCTION audit.record_change()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit.audit_log (
        table_name, record_id, operation, old_values, new_values,
        changed_by, changed_at, session_id
    ) VALUES (
        TG_TABLE_NAME,
        CASE
            WHEN TG_OP = 'DELETE' THEN OLD.id
            ELSE NEW.id
        END,
        TG_OP,
        CASE WHEN TG_OP != 'INSERT' THEN to_jsonb(OLD) ELSE NULL END,
        CASE WHEN TG_OP != 'DELETE' THEN to_jsonb(NEW) ELSE NULL END,
        current_setting('app.current_user', true),
        NOW(),
        current_setting('app.session_id', true)
    );
    RETURN NULL; -- AFTER trigger, return value ignored
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Apply audit trigger to orders table
CREATE TRIGGER orders_audit
    AFTER INSERT OR UPDATE OR DELETE ON orders
    FOR EACH ROW EXECUTE FUNCTION audit.record_change();

-- =============================================================================
-- Updated_at trigger
-- =============================================================================

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER customers_updated_at
    BEFORE UPDATE ON customers
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- =============================================================================
-- Row Level Security (Multi-tenant)
-- =============================================================================

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

-- Create policy: users can only see their own orders
-- Set in application: SET app.current_customer_id = 'cust-123'
CREATE POLICY customer_isolation ON orders
    USING (customer_id::text = current_setting('app.current_customer_id', true));

-- Admin role bypasses RLS
CREATE ROLE orders_admin;
ALTER TABLE orders FORCE ROW LEVEL SECURITY;
-- Note: table owner bypasses RLS by default — use FORCE to apply to owners too

-- =============================================================================
-- Useful Functions
-- =============================================================================

-- Calculate order total with discount
CREATE OR REPLACE FUNCTION calculate_order_total(
    p_subtotal NUMERIC,
    p_discount_pct NUMERIC DEFAULT 0,
    p_tax_pct NUMERIC DEFAULT 0
) RETURNS NUMERIC AS $$
BEGIN
    RETURN ROUND(
        p_subtotal * (1 - p_discount_pct / 100) * (1 + p_tax_pct / 100),
        4
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =============================================================================
-- Materialized View for Analytics
-- =============================================================================

CREATE MATERIALIZED VIEW order_daily_summary AS
SELECT
    DATE(created_at AT TIME ZONE 'UTC') AS order_date,
    status,
    currency,
    COUNT(*) AS order_count,
    SUM(total_amount) AS total_revenue,
    AVG(total_amount) AS avg_order_value,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_amount) AS median_order_value,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_amount) AS p95_order_value
FROM orders
WHERE created_at >= NOW() - INTERVAL '90 days'
GROUP BY 1, 2, 3;

CREATE UNIQUE INDEX ON order_daily_summary (order_date, status, currency);

-- Refresh daily (or use pg_cron for automation)
-- SELECT cron.schedule('refresh-order-summary', '0 1 * * *',
--   'REFRESH MATERIALIZED VIEW CONCURRENTLY order_daily_summary');

-- =============================================================================
-- Performance: Connection Pooling Setup
-- =============================================================================

-- Recommended HikariCP settings for this schema:
-- spring.datasource.hikari.maximum-pool-size=20
-- spring.datasource.hikari.minimum-idle=5
-- spring.datasource.hikari.connection-timeout=30000
-- spring.datasource.hikari.idle-timeout=600000
-- spring.datasource.hikari.max-lifetime=1800000

-- For PgBouncer (proxy-level pooling):
-- pool_mode=transaction
-- max_client_conn=10000
-- default_pool_size=50
