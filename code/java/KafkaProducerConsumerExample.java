package com.example.kafka;

import org.apache.kafka.clients.consumer.*;
import org.apache.kafka.clients.producer.*;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;

import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Production-grade Kafka Producer and Consumer examples.
 *
 * Features demonstrated:
 * - Idempotent producer with acks=all
 * - Manual offset management
 * - Graceful shutdown
 * - Error handling and dead letter queue
 * - Batch processing
 * - Transactional producer (exactly-once)
 */
public class KafkaProducerConsumerExample {

    private static final String BOOTSTRAP_SERVERS = "localhost:9092";
    private static final String TOPIC = "order-events";
    private static final String GROUP_ID = "order-processor";

    // ── Producer ──────────────────────────────────────────────────────────────

    public static class OrderEventProducer implements AutoCloseable {
        private final KafkaProducer<String, String> producer;

        public OrderEventProducer() {
            Properties props = new Properties();
            props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, BOOTSTRAP_SERVERS);
            props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
            props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());

            // ── Reliability settings ──────────────────────────────────────────
            // Wait for all in-sync replicas to acknowledge
            props.put(ProducerConfig.ACKS_CONFIG, "all");

            // Idempotent producer: deduplicates retried messages
            // Automatically sets: acks=all, retries=MAX_INT, max.in.flight=5
            props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);
            props.put(ProducerConfig.RETRIES_CONFIG, Integer.MAX_VALUE);
            props.put(ProducerConfig.MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION, 5);

            // ── Performance settings ──────────────────────────────────────────
            // Accumulate up to 64KB in a batch before sending
            props.put(ProducerConfig.BATCH_SIZE_CONFIG, 65_536);
            // Wait up to 5ms for batch to fill
            props.put(ProducerConfig.LINGER_MS_CONFIG, 5);
            // 64MB producer buffer
            props.put(ProducerConfig.BUFFER_MEMORY_CONFIG, 67_108_864);
            // Compress batches with snappy (fast, good ratio)
            props.put(ProducerConfig.COMPRESSION_TYPE_CONFIG, "snappy");
            // Block for up to 60s if buffer is full (backpressure)
            props.put(ProducerConfig.MAX_BLOCK_MS_CONFIG, 60_000);

            // ── Metadata settings ─────────────────────────────────────────────
            // Refresh cluster metadata every 5 minutes
            props.put(ProducerConfig.METADATA_MAX_AGE_CONFIG, 300_000);

            this.producer = new KafkaProducer<>(props);
        }

        /**
         * Send a message with async callback.
         * The key ensures all events for the same order go to the same partition (ordered).
         */
        public CompletableFuture<RecordMetadata> sendOrderEvent(String orderId, String eventJson) {
            CompletableFuture<RecordMetadata> future = new CompletableFuture<>();

            ProducerRecord<String, String> record = new ProducerRecord<>(
                TOPIC,
                orderId,    // Key: all events for orderId go to same partition → ordered
                eventJson
            );

            // Add custom headers for routing and tracing
            record.headers().add("eventType", "OrderCreated".getBytes());
            record.headers().add("version", "1".getBytes());
            record.headers().add("sourceService", "order-service".getBytes());
            record.headers().add("traceId", getTraceId().getBytes());

            producer.send(record, (metadata, exception) -> {
                if (exception != null) {
                    System.err.printf("ERROR sending order %s: %s%n", orderId, exception.getMessage());
                    future.completeExceptionally(exception);
                } else {
                    System.out.printf("Sent order %s to partition %d at offset %d%n",
                        orderId, metadata.partition(), metadata.offset());
                    future.complete(metadata);
                }
            });

            return future;
        }

        /**
         * Transactional producer — atomic write to multiple partitions/topics.
         * Use for exactly-once consume-transform-produce pipelines.
         */
        public static class TransactionalOrderProducer {
            private final KafkaProducer<String, String> producer;

            public TransactionalOrderProducer(String transactionalId) {
                Properties props = new Properties();
                props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, BOOTSTRAP_SERVERS);
                props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
                props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
                props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);
                props.put(ProducerConfig.ACKS_CONFIG, "all");

                // Unique ID for this producer instance
                // IMPORTANT: Only ONE instance with this ID can be active at a time
                props.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, transactionalId);

                this.producer = new KafkaProducer<>(props);
                this.producer.initTransactions(); // Register with broker
            }

            public void processAndForward(String inputKey, String inputValue) {
                try {
                    producer.beginTransaction();

                    // Process the record
                    String processedValue = processRecord(inputValue);

                    // Write to output topic
                    producer.send(new ProducerRecord<>("processed-orders", inputKey, processedValue));

                    // Commit input offset atomically with output write
                    // (offset commit is part of the transaction)
                    Map<TopicPartition, OffsetAndMetadata> offsets = new HashMap<>();
                    // ... populate offsets ...
                    producer.sendOffsetsToTransaction(offsets, new ConsumerGroupMetadata(GROUP_ID));

                    producer.commitTransaction();

                } catch (Exception e) {
                    producer.abortTransaction();
                    throw e;
                }
            }

            private String processRecord(String value) {
                return value.toUpperCase(); // Example transformation
            }
        }

        @Override
        public void close() {
            producer.flush(); // Send any buffered messages
            producer.close(Duration.ofSeconds(10));
        }

        private String getTraceId() {
            return UUID.randomUUID().toString().substring(0, 8);
        }
    }

    // ── Consumer ──────────────────────────────────────────────────────────────

    public static class OrderEventConsumer implements Runnable {
        private final KafkaConsumer<String, String> consumer;
        private final AtomicBoolean running = new AtomicBoolean(true);
        private final String deadLetterTopic = TOPIC + ".DLT";

        public OrderEventConsumer() {
            Properties props = new Properties();
            props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, BOOTSTRAP_SERVERS);
            props.put(ConsumerConfig.GROUP_ID_CONFIG, GROUP_ID);
            props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
            props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());

            // ── Offset management ─────────────────────────────────────────────
            // Disable auto-commit — we control when we commit
            props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false);
            // Start from earliest if no committed offset exists
            props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");

            // ── Performance settings ──────────────────────────────────────────
            // Fetch at least 64KB before returning (reduces round trips)
            props.put(ConsumerConfig.FETCH_MIN_BYTES_CONFIG, 65_536);
            // Wait at most 500ms for enough data
            props.put(ConsumerConfig.FETCH_MAX_WAIT_MS_CONFIG, 500);
            // Process up to 500 records per poll
            props.put(ConsumerConfig.MAX_POLL_RECORDS_CONFIG, 500);

            // ── Session management ────────────────────────────────────────────
            // Heartbeat to broker every 3 seconds
            props.put(ConsumerConfig.HEARTBEAT_INTERVAL_MS_CONFIG, 3_000);
            // Kick consumer out of group if no heartbeat for 30 seconds
            props.put(ConsumerConfig.SESSION_TIMEOUT_MS_CONFIG, 30_000);
            // Max time between poll() calls (must be > processing time for a batch)
            props.put(ConsumerConfig.MAX_POLL_INTERVAL_MS_CONFIG, 300_000);

            // ── Rebalance strategy ────────────────────────────────────────────
            // Cooperative sticky: minimal partition movement during rebalance
            props.put(ConsumerConfig.PARTITION_ASSIGNMENT_STRATEGY_CONFIG,
                "org.apache.kafka.clients.consumer.CooperativeStickyAssignor");

            this.consumer = new KafkaConsumer<>(props);
        }

        @Override
        public void run() {
            consumer.subscribe(List.of(TOPIC));

            try {
                while (running.get()) {
                    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(1000));

                    if (records.isEmpty()) continue;

                    // Process records partition by partition
                    for (TopicPartition partition : records.partitions()) {
                        List<ConsumerRecord<String, String>> partitionRecords =
                            records.records(partition);

                        long lastOffset = -1;

                        for (ConsumerRecord<String, String> record : partitionRecords) {
                            try {
                                processRecord(record);
                                lastOffset = record.offset();

                            } catch (RetryableException e) {
                                // Retryable error — stop processing, seek back, retry later
                                System.err.printf("Retryable error at offset %d: %s%n",
                                    record.offset(), e.getMessage());
                                consumer.seek(partition, record.offset()); // Go back
                                break; // Stop this partition — will retry on next poll

                            } catch (Exception e) {
                                // Non-retryable — send to DLQ, continue
                                System.err.printf("Non-retryable error at offset %d: %s%n",
                                    record.offset(), e.getMessage());
                                sendToDlq(record, e);
                                lastOffset = record.offset(); // Continue after failed record
                            }
                        }

                        // Commit only successfully processed offsets
                        if (lastOffset >= 0) {
                            consumer.commitSync(Map.of(
                                partition,
                                new OffsetAndMetadata(lastOffset + 1)
                            ));
                        }
                    }
                }
            } finally {
                // Commit pending offsets before shutdown
                consumer.commitSync();
                consumer.close(Duration.ofSeconds(10));
            }
        }

        private void processRecord(ConsumerRecord<String, String> record) {
            System.out.printf("Processing: key=%s partition=%d offset=%d value=%s%n",
                record.key(), record.partition(), record.offset(),
                record.value().substring(0, Math.min(50, record.value().length())));

            // Your business logic here
            // Simulate processing time
            try { Thread.sleep(1); } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }

        private void sendToDlq(ConsumerRecord<String, String> record, Exception error) {
            // In production: use Spring Kafka's DeadLetterPublishingRecoverer
            System.err.printf("Sending to DLQ: key=%s error=%s%n",
                record.key(), error.getMessage());
        }

        public void shutdown() {
            running.set(false);
            consumer.wakeup(); // Interrupt poll() call
        }
    }

    // ── Main ──────────────────────────────────────────────────────────────────

    public static void main(String[] args) throws Exception {
        // Start consumer in background thread
        OrderEventConsumer consumer = new OrderEventConsumer();
        Thread consumerThread = Thread.ofVirtual()
            .name("kafka-consumer")
            .start(consumer);

        // Graceful shutdown hook
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println("Shutting down...");
            consumer.shutdown();
            try { consumerThread.join(Duration.ofSeconds(30)); }
            catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        }));

        // Produce some messages
        try (OrderEventProducer producer = new OrderEventProducer()) {
            for (int i = 0; i < 10; i++) {
                String orderId = "order-" + i;
                String event = String.format(
                    """
                    {"orderId":"%s","status":"CREATED","amount":%.2f,"customerId":"cust-%d"}
                    """,
                    orderId, 50.0 + i * 10, i
                );
                producer.sendOrderEvent(orderId, event);
            }
        }

        // Wait a bit for consumer to process
        Thread.sleep(5000);
        consumer.shutdown();
    }

    // ── Custom Exceptions ─────────────────────────────────────────────────────

    static class RetryableException extends RuntimeException {
        public RetryableException(String message) { super(message); }
    }

    static class NonRetryableException extends RuntimeException {
        public NonRetryableException(String message, Throwable cause) { super(message, cause); }
    }
}
