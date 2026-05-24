package com.example.concurrency;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.IntStream;

/**
 * Production examples of Java 21 Virtual Threads.
 *
 * Virtual threads are lightweight threads managed by the JVM.
 * They are perfect for I/O-bound workloads (database, HTTP, file I/O).
 * One JVM can handle millions of virtual threads without memory issues.
 */
public class VirtualThreadsExample {

    // ── 1. Basic Virtual Thread Creation ─────────────────────────────────────

    public static void basicExample() throws InterruptedException {
        // Old way — platform thread (backed by OS thread)
        Thread platformThread = new Thread(() -> {
            System.out.println("Platform thread: " + Thread.currentThread());
        });
        platformThread.start();
        platformThread.join();

        // New way — virtual thread (lightweight, JVM-managed)
        Thread virtualThread = Thread.ofVirtual()
            .name("my-virtual-thread")
            .start(() -> {
                System.out.println("Virtual thread: " + Thread.currentThread());
                System.out.println("Is virtual: " + Thread.currentThread().isVirtual()); // true
            });
        virtualThread.join();
    }

    // ── 2. Massive Concurrency — 1 Million Concurrent Tasks ──────────────────

    public static void massiveConcurrencyExample() throws InterruptedException {
        int taskCount = 1_000_000;
        AtomicInteger completedTasks = new AtomicInteger(0);

        // ExecutorService backed by virtual threads — one thread per task
        try (ExecutorService executor = Executors.newVirtualThreadPerTaskExecutor()) {
            List<Future<?>> futures = new ArrayList<>(taskCount);

            long start = System.currentTimeMillis();

            for (int i = 0; i < taskCount; i++) {
                Future<?> future = executor.submit(() -> {
                    // Simulate I/O-bound work (database query, HTTP call)
                    Thread.sleep(Duration.ofMillis(100)); // blocks virtual thread, not OS thread
                    completedTasks.incrementAndGet();
                });
                futures.add(future);
            }

            // Wait for all tasks
            for (Future<?> future : futures) {
                try { future.get(); } catch (ExecutionException ignored) {}
            }

            long elapsed = System.currentTimeMillis() - start;
            System.out.printf("Completed %d tasks in %dms%n", completedTasks.get(), elapsed);
            // With platform threads: would need 1M OS threads (impossible)
            // With virtual threads: runs in ~100ms using carrier threads = CPU cores
        }
    }

    // ── 3. HTTP Server with Virtual Threads (Spring Boot style) ──────────────

    /**
     * In Spring Boot 3.2+, add to application.yml:
     *   spring:
     *     threads:
     *       virtual:
     *         enabled: true
     *
     * This configures Tomcat to use virtual threads for every HTTP request.
     * Each request gets its own virtual thread.
     * Database blocking, HTTP client blocking — all yield the carrier thread.
     */

    // ── 4. Replacing Thread Pool with Virtual Threads ─────────────────────────

    public static class OrderProcessor {
        // OLD approach: fixed thread pool limits concurrency
        private final ExecutorService platformPool = Executors.newFixedThreadPool(50);

        // NEW approach: virtual threads — unlimited concurrency
        private final ExecutorService virtualPool = Executors.newVirtualThreadPerTaskExecutor();

        public CompletableFuture<String> processOrderWithVirtualThread(String orderId) {
            return CompletableFuture.supplyAsync(() -> {
                // This thread will unmount from OS thread during I/O:
                String customer = fetchCustomerFromDatabase(orderId);  // blocks → unmounts
                String inventory = checkInventoryService(orderId);     // HTTP → unmounts
                String payment = callPaymentGateway(orderId);          // HTTP → unmounts

                return "Order " + orderId + " processed: " + customer + " " + inventory;
            }, virtualPool);
        }

        // Simulated I/O operations
        private String fetchCustomerFromDatabase(String orderId) {
            try { Thread.sleep(50); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            return "Customer-123";
        }

        private String checkInventoryService(String orderId) {
            try { Thread.sleep(30); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            return "Available";
        }

        private String callPaymentGateway(String orderId) {
            try { Thread.sleep(80); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            return "Charged";
        }
    }

    // ── 5. Structured Concurrency (Java 21 Preview) ──────────────────────────

    public static String fetchWithStructuredConcurrency(String city) throws Exception {
        // StructuredTaskScope ensures:
        // - All subtasks finish before scope exits
        // - If one fails, others are cancelled
        // - No orphaned threads
        try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
            // Fork two concurrent tasks
            StructuredTaskScope.Subtask<String> weatherTask =
                scope.fork(() -> fetchWeather(city));
            StructuredTaskScope.Subtask<String> restaurantTask =
                scope.fork(() -> fetchRestaurants(city));

            scope.join();           // Wait for both
            scope.throwIfFailed();  // Propagate failure

            return weatherTask.get() + " | " + restaurantTask.get();
        }
    }

    private static String fetchWeather(String city) throws InterruptedException {
        Thread.sleep(200); // Simulate API call
        return "Weather in " + city + ": Sunny 25°C";
    }

    private static String fetchRestaurants(String city) throws InterruptedException {
        Thread.sleep(150); // Simulate API call
        return "3 restaurants near " + city;
    }

    // ── 6. Pinning — Common Pitfall ──────────────────────────────────────────

    private static final Object MONITOR = new Object();

    /**
     * WRONG: synchronized block pins the virtual thread.
     * The carrier OS thread is blocked while the virtual thread waits.
     * Negates the benefit of virtual threads!
     */
    public static void badSynchronized() throws InterruptedException {
        Thread vt = Thread.ofVirtual().start(() -> {
            synchronized (MONITOR) {
                try {
                    Thread.sleep(Duration.ofMillis(100)); // PINS carrier thread!
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
        });
        vt.join();
    }

    /**
     * CORRECT: Use ReentrantLock — virtual thread can unmount while waiting.
     * The carrier OS thread is freed to run other virtual threads.
     */
    private static final ReentrantLock LOCK = new ReentrantLock();

    public static void goodReentrantLock() throws InterruptedException {
        Thread vt = Thread.ofVirtual().start(() -> {
            LOCK.lock();
            try {
                try {
                    Thread.sleep(Duration.ofMillis(100)); // Can unmount — no pinning!
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            } finally {
                LOCK.unlock();
            }
        });
        vt.join();
    }

    // ── 7. Benchmark: Virtual vs Platform Threads ─────────────────────────────

    public static void benchmark() throws InterruptedException {
        int taskCount = 10_000;
        int sleepMs = 10; // Simulate I/O

        // Platform thread pool (50 threads)
        long platformTime = measureTime(taskCount, sleepMs, Executors.newFixedThreadPool(50));
        System.out.printf("Platform threads (50): %dms%n", platformTime);

        // Virtual threads
        long virtualTime = measureTime(taskCount, sleepMs,
            Executors.newVirtualThreadPerTaskExecutor());
        System.out.printf("Virtual threads:       %dms%n", virtualTime);

        // Expected results:
        // Platform threads: 10000 tasks ÷ 50 threads × 10ms = ~2000ms
        // Virtual threads: all 10000 run "concurrently" → ~10ms
    }

    private static long measureTime(int tasks, int sleepMs, ExecutorService executor)
            throws InterruptedException {
        CountDownLatch latch = new CountDownLatch(tasks);
        long start = System.currentTimeMillis();

        IntStream.range(0, tasks).forEach(i ->
            executor.submit(() -> {
                try {
                    Thread.sleep(sleepMs);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } finally {
                    latch.countDown();
                }
            })
        );

        latch.await();
        executor.shutdown();
        return System.currentTimeMillis() - start;
    }

    public static void main(String[] args) throws Exception {
        System.out.println("=== Virtual Threads Demo ===\n");

        System.out.println("1. Basic example:");
        basicExample();

        System.out.println("\n2. Benchmark:");
        benchmark();

        System.out.println("\n3. Structured concurrency:");
        System.out.println(fetchWithStructuredConcurrency("Paris"));

        System.out.println("\n4. Massive concurrency (1M tasks):");
        massiveConcurrencyExample();
    }
}
