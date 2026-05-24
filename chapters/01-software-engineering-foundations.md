# Section 1: Software Engineering Foundations

## Chapter 1: Clean Code

### Introduction

Clean code is not about following rules. It is about writing code that other engineers can read, understand, change, and debug without your help. Bad code slows teams down. It creates bugs. It makes onboarding new engineers expensive. Clean code is a business concern, not just an aesthetic one.

At a senior engineer level, you are responsible for code quality across your team, not just in your own files. You review code. You establish patterns. You set the standard. This chapter gives you the principles and tools to do that well.

### Why It Matters

A study by the National Institute of Standards and Technology (NIST) estimated that software bugs cost the U.S. economy $60 billion per year. Most of those bugs live in complex, unreadable code. If you cannot read the code, you cannot find the bugs. If you cannot find the bugs, you cannot fix them.

Consider this: the average software engineer spends roughly 70% of their time **reading** code, not writing it. That means code readability is a performance multiplier. If your code takes twice as long to read, your team is running at 60% speed.

### Real-World Problem

Imagine a payment service. It processes 10,000 transactions per second. A new engineer joins and needs to add fraud detection logic. They spend two weeks trying to understand the existing code before writing a single line. The code has 500-line methods, cryptic variable names like `d`, `tmp`, `x2`, and zero comments. The deadline is missed. The business loses money.

Clean code would have let that engineer contribute in two days, not two weeks.

### Names Matter Most

The biggest factor in code readability is naming. Good names make code self-documenting.

**Bad:**
```java
public int calc(int a, int b, int c) {
    int x = a * b;
    if (c > 0) x = x - c;
    return x;
}
```

**Good:**
```java
public Money calculateOrderTotal(Money subtotal, int quantity, Money discountAmount) {
    Money total = subtotal.multiply(quantity);
    if (discountAmount.isPositive()) {
        total = total.subtract(discountAmount);
    }
    return total;
}
```

The good version tells you exactly what it does, what it returns, and what edge case it handles. No comments needed.

**Rules for naming:**
- Use intention-revealing names. `elapsedTimeInDays` is better than `d`.
- Avoid disinformation. Do not call a list `accountList` if it is not a `java.util.List`.
- Use pronounceable names. You need to talk about code in meetings.
- Use searchable names. `MAXIMUM_CLASSES_PER_STUDENT` is better than `7`.
- Avoid mental mapping. Readers should not translate `i` to "iterator index" in their head.
- Class names should be nouns: `Customer`, `PaymentProcessor`, `OrderService`.
- Method names should be verbs: `sendPayment`, `deleteAccount`, `validateInput`.

### Functions Should Do One Thing

The single responsibility principle at the method level. A function should do one thing, do it well, and do it only.

**How to know if a function does one thing:** Can you extract another meaningful function from it? If yes, it does more than one thing.

**Bad — one huge function doing everything:**
```java
public void processOrder(Order order) {
    // Validate
    if (order.getItems().isEmpty()) throw new IllegalArgumentException("Empty order");
    if (order.getCustomer() == null) throw new IllegalArgumentException("No customer");

    // Calculate price
    BigDecimal total = BigDecimal.ZERO;
    for (OrderItem item : order.getItems()) {
        total = total.add(item.getPrice().multiply(BigDecimal.valueOf(item.getQuantity())));
    }

    // Apply discount
    if (order.getCustomer().isPremium()) {
        total = total.multiply(BigDecimal.valueOf(0.9));
    }

    // Save to database
    orderRepository.save(order);

    // Send email
    emailService.send(order.getCustomer().getEmail(), "Order confirmed", "Your order total: " + total);

    // Update inventory
    for (OrderItem item : order.getItems()) {
        inventoryService.reduce(item.getProductId(), item.getQuantity());
    }
}
```

**Good — composed of small, named functions:**
```java
public void processOrder(Order order) {
    validateOrder(order);
    Money total = calculateTotal(order);
    applyDiscounts(order, total);
    persistOrder(order);
    notifyCustomer(order, total);
    updateInventory(order);
}

private void validateOrder(Order order) {
    if (order.getItems().isEmpty()) {
        throw new InvalidOrderException("Order must contain at least one item");
    }
    if (order.getCustomer() == null) {
        throw new InvalidOrderException("Order must have a customer");
    }
}

private Money calculateTotal(Order order) {
    return order.getItems().stream()
        .map(item -> item.getPrice().multiply(item.getQuantity()))
        .reduce(Money.ZERO, Money::add);
}
```

Notice how `processOrder` now reads like a table of contents. You understand the flow in seconds.

### The Rule of Three for Comments

Write a comment only when the code cannot explain itself. Comments lie. Code does not. When code changes, comments often do not get updated. Stale comments are worse than no comments.

**When NOT to comment:**
```java
// Increment counter by 1
counter++;

// Check if user is admin
if (user.isAdmin()) {
```

**When TO comment:**
```java
// We intentionally bypass the cache here because the fraud detection
// system requires real-time data. Caching would introduce a 5-minute lag
// that is unacceptable for compliance reasons. See ADR-047.
FraudResult result = fraudDetector.checkWithoutCache(transaction);

// This magic number comes from the EU payment regulation PSD2 Article 98.
// Transactions above 10,000 EUR require additional verification.
private static final Money PSD2_THRESHOLD = Money.of(10_000, Currency.EUR);
```

Good comments explain WHY, not WHAT.

### Error Handling

Error handling is not a second-class concern. It is part of the main logic.

**Rules for clean error handling:**

1. **Use exceptions, not return codes.** Return codes require the caller to check them. Exceptions force handling.

2. **Do not catch generic exceptions.** Catch what you can handle.
```java
// BAD
try {
    processPayment(order);
} catch (Exception e) {
    log.error("Something went wrong");
}

// GOOD
try {
    processPayment(order);
} catch (PaymentGatewayException e) {
    log.error("Payment gateway error for order {}: {}", order.getId(), e.getMessage());
    notifyOpsTeam(e);
    throw new PaymentFailedException("Payment processing failed", e);
} catch (InsufficientFundsException e) {
    log.info("Insufficient funds for customer {}", order.getCustomer().getId());
    return PaymentResult.insufficientFunds();
}
```

3. **Do not return null.** Return `Optional<T>`, empty collections, or null objects.
```java
// BAD — caller must null-check
public Customer findCustomer(String id) {
    return customerRepository.findById(id); // may return null
}

// GOOD — intent is clear
public Optional<Customer> findCustomer(String id) {
    return customerRepository.findById(id);
}
```

4. **Use checked exceptions for recoverable conditions, unchecked for programming errors.**

### The Boy Scout Rule

*Always leave the code cleaner than you found it.*

You do not need to refactor everything at once. Every time you touch a file, make it a little better. Rename one bad variable. Extract one large method. Remove one dead comment. Over months, this adds up to a dramatically better codebase.

---

## Chapter 2: SOLID Principles

### Introduction

SOLID is five design principles that make object-oriented code easier to maintain and extend. They were popularized by Robert C. Martin (Uncle Bob). Each principle addresses a specific type of design failure.

These principles are especially important in large codebases. A system with 10 classes can ignore them. A system with 10,000 classes cannot.

### S — Single Responsibility Principle

**Definition:** A class should have only one reason to change.

This is different from "do one thing." It means the class should have only one actor who can request changes to it. If the CEO asks you to change the report format AND the CTO asks you to change the report database query — you have two actors driving changes to one class. That is a violation.

**Bad design:**
```java
public class Employee {
    private String name;
    private double salary;

    // HR asks for changes to this method
    public Money calculatePay() { ... }

    // Accounting asks for changes to this method
    public void saveToDatabase() { ... }

    // CTO asks for changes to this method
    public String generateReport() { ... }
}
```

**Good design — one class per actor:**
```java
// HR department owns this
public class PayCalculator {
    public Money calculatePay(Employee employee) { ... }
}

// Data team owns this
public class EmployeeRepository {
    public void save(Employee employee) { ... }
}

// Reporting team owns this
public class EmployeeReportGenerator {
    public String generate(Employee employee) { ... }
}

// Just a data holder — no behavior that changes for external reasons
public record Employee(String name, String department, EmploymentType type) {}
```

### O — Open/Closed Principle

**Definition:** Software entities should be open for extension but closed for modification.

When you need new behavior, add new code — do not change existing code. Changing existing code risks breaking things that already work.

**Violation — adding a new payment type breaks everything:**
```java
public class PaymentProcessor {
    public void processPayment(Payment payment) {
        if (payment.getType() == PaymentType.CREDIT_CARD) {
            processCreditCard(payment);
        } else if (payment.getType() == PaymentType.PAYPAL) {
            processPayPal(payment);
        } else if (payment.getType() == PaymentType.CRYPTO) {   // New line added
            processCrypto(payment);                              // Risky change!
        }
    }
}
```

**OCP-compliant — adding new types requires zero changes to existing code:**
```java
public interface PaymentStrategy {
    void process(Payment payment);
    boolean supports(PaymentType type);
}

@Component
public class CreditCardPaymentStrategy implements PaymentStrategy {
    @Override
    public void process(Payment payment) { /* credit card logic */ }

    @Override
    public boolean supports(PaymentType type) { return type == PaymentType.CREDIT_CARD; }
}

@Component
public class CryptoPaymentStrategy implements PaymentStrategy {
    @Override
    public void process(Payment payment) { /* crypto logic */ }

    @Override
    public boolean supports(PaymentType type) { return type == PaymentType.CRYPTO; }
}

@Service
public class PaymentProcessor {
    private final List<PaymentStrategy> strategies;

    public PaymentProcessor(List<PaymentStrategy> strategies) {
        this.strategies = strategies;
    }

    public void processPayment(Payment payment) {
        strategies.stream()
            .filter(s -> s.supports(payment.getType()))
            .findFirst()
            .orElseThrow(() -> new UnsupportedPaymentTypeException(payment.getType()))
            .process(payment);
    }
}
```

Now you add a new payment type by creating a new class and annotating it with `@Component`. Zero changes to `PaymentProcessor`.

### L — Liskov Substitution Principle

**Definition:** Objects of a subtype must be substitutable for objects of their supertype without breaking the program.

If you have `Bird bird = new Duck()`, and you call `bird.fly()`, it should work. If `Duck` throws `UnsupportedOperationException` when you call `fly()`, you violated LSP.

**Classic violation:**
```java
public class Rectangle {
    protected int width, height;

    public void setWidth(int width) { this.width = width; }
    public void setHeight(int height) { this.height = height; }
    public int getArea() { return width * height; }
}

public class Square extends Rectangle {
    @Override
    public void setWidth(int width) {
        this.width = width;
        this.height = width; // square must keep sides equal
    }

    @Override
    public void setHeight(int height) {
        this.width = height;
        this.height = height;
    }
}

// This breaks when Square is used instead of Rectangle:
Rectangle r = new Square();
r.setWidth(5);
r.setHeight(10);
System.out.println(r.getArea()); // Expected 50, got 100 — LSP violated
```

**Fix — use composition, not inheritance:**
```java
public interface Shape {
    int getArea();
}

public record Rectangle(int width, int height) implements Shape {
    public int getArea() { return width * height; }
}

public record Square(int side) implements Shape {
    public int getArea() { return side * side; }
}
```

### I — Interface Segregation Principle

**Definition:** Clients should not be forced to depend on interfaces they do not use.

**Bad — fat interface:**
```java
public interface Worker {
    void work();
    void eat();
    void sleep();
}

// RobotWorker does not eat or sleep, but is forced to implement these
public class RobotWorker implements Worker {
    public void work() { /* works */ }
    public void eat() { throw new UnsupportedOperationException(); } // violation
    public void sleep() { throw new UnsupportedOperationException(); } // violation
}
```

**Good — segregated interfaces:**
```java
public interface Workable { void work(); }
public interface Eatable   { void eat(); }
public interface Sleepable { void sleep(); }

public class HumanWorker implements Workable, Eatable, Sleepable {
    public void work() { /* works */ }
    public void eat()  { /* eats */ }
    public void sleep(){ /* sleeps */ }
}

public class RobotWorker implements Workable {
    public void work() { /* works */ }
}
```

### D — Dependency Inversion Principle

**Definition:** High-level modules should not depend on low-level modules. Both should depend on abstractions.

This is the foundation of dependency injection.

**Bad — high-level module depends on low-level detail:**
```java
public class OrderService {
    private final MySQLOrderRepository repository; // concrete class — bad

    public OrderService() {
        this.repository = new MySQLOrderRepository(); // even worse — hardcoded
    }
}
```

**Good — both depend on abstraction:**
```java
public interface OrderRepository {
    Order findById(String id);
    Order save(Order order);
}

@Service
public class OrderService {
    private final OrderRepository repository; // depends on interface — good

    public OrderService(OrderRepository repository) { // injected — good
        this.repository = repository;
    }
}

@Repository
public class MySQLOrderRepository implements OrderRepository { ... }

// Easy to swap:
@Repository
@Profile("test")
public class InMemoryOrderRepository implements OrderRepository { ... }
```

Spring Boot does this automatically with `@Autowired` and component scanning. The principle is why Spring works.

---

## Chapter 3: Design Patterns

### Introduction

Design patterns are reusable solutions to common problems. They are not code — they are templates for solving problems that appear repeatedly. The "Gang of Four" book (Gamma, Helm, Johnson, Vlissides) defined 23 classic patterns. We cover the most important ones for backend engineering.

### Creational Patterns

#### Factory Method

Creates objects without specifying the exact class. Lets subclasses decide which class to instantiate.

```java
// Abstract factory method
public abstract class NotificationFactory {
    public abstract Notification createNotification(String message);

    // Template method — uses factory method
    public void sendNotification(String message) {
        Notification notification = createNotification(message);
        notification.send();
        notification.log();
    }
}

public class EmailNotificationFactory extends NotificationFactory {
    @Override
    public Notification createNotification(String message) {
        return new EmailNotification(message, config.getSmtpServer());
    }
}

public class SlackNotificationFactory extends NotificationFactory {
    @Override
    public Notification createNotification(String message) {
        return new SlackNotification(message, config.getSlackWebhook());
    }
}
```

#### Builder Pattern

Construct complex objects step by step. Essential when objects have many optional parameters.

```java
// Without Builder — telescoping constructor problem
new User("John", "Doe", "john@example.com", null, null, true, false, "en", "UTC");
// What does 'true' mean? What does 'false' mean?

// With Builder — readable and safe
User user = User.builder()
    .firstName("John")
    .lastName("Doe")
    .email("john@example.com")
    .emailVerified(true)
    .twoFactorEnabled(false)
    .locale("en")
    .timezone("UTC")
    .build();
```

Java `record` + Lombok's `@Builder` or manual builder pattern:

```java
@Builder
@Value // Lombok: immutable, final fields, constructor
public class HttpRequest {
    @NonNull String method;
    @NonNull URI uri;
    @Singular Map<String, String> headers;
    @Builder.Default Duration timeout = Duration.ofSeconds(30);
    byte[] body;

    public static class HttpRequestBuilder {
        public HttpRequestBuilder jsonBody(Object payload) {
            this.headers(Map.of("Content-Type", "application/json"));
            this.body(objectMapper.writeValueAsBytes(payload));
            return this;
        }
    }
}

// Usage:
HttpRequest request = HttpRequest.builder()
    .method("POST")
    .uri(URI.create("https://api.example.com/orders"))
    .header("Authorization", "Bearer " + token)
    .jsonBody(orderRequest)
    .timeout(Duration.ofSeconds(10))
    .build();
```

#### Singleton Pattern

Ensure only one instance of a class exists. Use carefully — global state is a design smell.

```java
// Thread-safe Singleton using enum (recommended in Java)
public enum DatabaseConnectionPool {
    INSTANCE;

    private final HikariDataSource dataSource;

    DatabaseConnectionPool() {
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(System.getenv("DB_URL"));
        config.setMaximumPoolSize(20);
        this.dataSource = new HikariDataSource(config);
    }

    public Connection getConnection() throws SQLException {
        return dataSource.getConnection();
    }
}

// Usage
Connection conn = DatabaseConnectionPool.INSTANCE.getConnection();
```

In Spring, `@Bean` creates singletons by default. You rarely need to implement the pattern manually.

### Structural Patterns

#### Decorator Pattern

Add behavior to objects dynamically without changing their class. Better than subclassing for adding optional features.

```java
public interface OrderRepository {
    Optional<Order> findById(String id);
    Order save(Order order);
}

// Base implementation
@Repository
public class DatabaseOrderRepository implements OrderRepository {
    @Override
    public Optional<Order> findById(String id) {
        return jpaRepository.findById(id);
    }

    @Override
    public Order save(Order order) {
        return jpaRepository.save(order);
    }
}

// Caching decorator
public class CachingOrderRepository implements OrderRepository {
    private final OrderRepository delegate;
    private final Cache<String, Order> cache;

    @Override
    public Optional<Order> findById(String id) {
        Order cached = cache.getIfPresent(id);
        if (cached != null) return Optional.of(cached);

        Optional<Order> found = delegate.findById(id);
        found.ifPresent(o -> cache.put(id, o));
        return found;
    }

    @Override
    public Order save(Order order) {
        Order saved = delegate.save(order);
        cache.put(saved.getId(), saved);
        return saved;
    }
}

// Logging decorator
public class LoggingOrderRepository implements OrderRepository {
    private final OrderRepository delegate;
    private static final Logger log = LoggerFactory.getLogger(LoggingOrderRepository.class);

    @Override
    public Optional<Order> findById(String id) {
        log.debug("Finding order by id: {}", id);
        long start = System.nanoTime();
        Optional<Order> result = delegate.findById(id);
        log.debug("Found order in {}ms", TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start));
        return result;
    }

    @Override
    public Order save(Order order) {
        log.info("Saving order: {}", order.getId());
        return delegate.save(order);
    }
}

// Compose decorators
@Configuration
public class RepositoryConfig {
    @Bean
    public OrderRepository orderRepository(DatabaseOrderRepository db) {
        return new LoggingOrderRepository(
                   new CachingOrderRepository(db, buildCache()));
    }
}
```

#### Adapter Pattern

Makes incompatible interfaces work together. Essential when integrating third-party libraries.

```java
// Our internal interface
public interface PaymentGateway {
    PaymentResult charge(Money amount, PaymentMethod method);
}

// External Stripe library has a different interface
// StripeClient.createCharge(long amountCents, String currency, String sourceToken)

// Adapter bridges the gap
public class StripePaymentGateway implements PaymentGateway {
    private final StripeClient stripeClient;

    @Override
    public PaymentResult charge(Money amount, PaymentMethod method) {
        // Convert our types to Stripe's types
        long amountCents = amount.toCents();
        String currency = amount.getCurrency().getCode().toLowerCase();
        String sourceToken = method.getToken();

        try {
            StripeCharge charge = stripeClient.createCharge(amountCents, currency, sourceToken);
            return PaymentResult.success(charge.getId());
        } catch (StripeException e) {
            return PaymentResult.failure(e.getMessage());
        }
    }
}
```

### Behavioral Patterns

#### Observer Pattern (Event-Driven)

Objects subscribe to events and react when those events happen. The foundation of event-driven architecture.

```java
// Event
public record OrderPlacedEvent(String orderId, Money total, String customerId) {}

// Observer interface
public interface OrderEventListener {
    void onOrderPlaced(OrderPlacedEvent event);
}

// Publisher
@Service
public class OrderService {
    private final List<OrderEventListener> listeners = new CopyOnWriteArrayList<>();

    public void addListener(OrderEventListener listener) {
        listeners.add(listener);
    }

    public Order placeOrder(PlaceOrderCommand command) {
        Order order = Order.create(command);
        orderRepository.save(order);

        OrderPlacedEvent event = new OrderPlacedEvent(
            order.getId(), order.getTotal(), order.getCustomerId()
        );
        listeners.forEach(l -> l.onOrderPlaced(event));

        return order;
    }
}

// Spring's @EventListener is the production way
@Component
public class InventoryService {
    @EventListener
    public void handleOrderPlaced(OrderPlacedEvent event) {
        // reserve inventory
    }
}

@Component
public class EmailService {
    @EventListener
    @Async
    public void sendConfirmationEmail(OrderPlacedEvent event) {
        // send email asynchronously
    }
}
```

#### Strategy Pattern

Define a family of algorithms, encapsulate each one, make them interchangeable.

```java
public interface PricingStrategy {
    Money calculatePrice(Product product, Customer customer, int quantity);
}

@Component("regularPricing")
public class RegularPricingStrategy implements PricingStrategy {
    @Override
    public Money calculatePrice(Product product, Customer customer, int quantity) {
        return product.getBasePrice().multiply(quantity);
    }
}

@Component("premiumPricing")
public class PremiumPricingStrategy implements PricingStrategy {
    @Override
    public Money calculatePrice(Product product, Customer customer, int quantity) {
        Money baseTotal = product.getBasePrice().multiply(quantity);
        return baseTotal.multiply(0.8); // 20% discount for premium
    }
}

@Component("bulkPricing")
public class BulkPricingStrategy implements PricingStrategy {
    @Override
    public Money calculatePrice(Product product, Customer customer, int quantity) {
        if (quantity >= 100) {
            return product.getBulkPrice().multiply(quantity);
        }
        return product.getBasePrice().multiply(quantity);
    }
}

@Service
public class PricingService {
    private final Map<String, PricingStrategy> strategies;

    public PricingService(Map<String, PricingStrategy> strategies) {
        this.strategies = strategies;
    }

    public Money calculatePrice(Product product, Customer customer, int quantity) {
        String strategyName = determineStrategy(customer, quantity);
        return strategies.get(strategyName).calculatePrice(product, customer, quantity);
    }

    private String determineStrategy(Customer customer, int quantity) {
        if (quantity >= 100) return "bulkPricing";
        if (customer.isPremium()) return "premiumPricing";
        return "regularPricing";
    }
}
```

### Anti-Patterns to Avoid

| Anti-Pattern | Description | Fix |
|---|---|---|
| God Class | One class that does everything | Apply SRP, split by responsibility |
| Anemic Domain Model | Objects with only data, no behavior | Move logic into domain objects |
| Service Locator | Objects pull dependencies from a registry | Use dependency injection |
| Singleton Overuse | Using singletons as global variables | Use DI containers |
| Premature Abstraction | Abstracting before you understand the problem | Start concrete, refactor when patterns emerge |
| Magic Numbers | Unexplained numeric constants | Use named constants with explanatory comments |

---

## Chapter 4: Testing Strategies

### Why Testing Matters for Senior Engineers

As a senior engineer, tests are not optional extras. They are how you move fast without breaking things. A good test suite is what lets you refactor confidently, deploy on Friday, and sleep on the weekend.

Testing strategy is a design decision. Different types of tests give different feedback at different speeds and costs.

### The Testing Pyramid

```
        /\
       /  \
      / E2E \        — Few, slow, expensive — full system tests
     /--------\
    /Integration\    — Moderate number — verify component interactions
   /------------\
  /  Unit Tests  \   — Many, fast, cheap — verify logic in isolation
 /______________  \
```

**Unit Tests** — Test one class or method in isolation. Mock all dependencies. Fast (milliseconds). Many of them.

**Integration Tests** — Test how components work together. Real database, real HTTP. Slower (seconds). Fewer of them.

**End-to-End (E2E) Tests** — Test the full system from user perspective. Slowest, most fragile. Very few.

### Unit Testing with JUnit 5 and Mockito

```java
@ExtendWith(MockitoExtension.class)
class OrderServiceTest {

    @Mock
    private OrderRepository orderRepository;

    @Mock
    private PaymentGateway paymentGateway;

    @Mock
    private EventPublisher eventPublisher;

    @InjectMocks
    private OrderService orderService;

    @Test
    @DisplayName("should place order successfully when payment succeeds")
    void shouldPlaceOrderWhenPaymentSucceeds() {
        // Given
        PlaceOrderCommand command = PlaceOrderCommand.builder()
            .customerId("cust-123")
            .items(List.of(new OrderItem("prod-456", 2, Money.of(50, EUR))))
            .paymentMethod(PaymentMethod.creditCard("4111111111111111", "12/27", "123"))
            .build();

        Order expectedOrder = Order.fromCommand(command);
        when(orderRepository.save(any(Order.class))).thenReturn(expectedOrder);
        when(paymentGateway.charge(any(), any())).thenReturn(PaymentResult.success("pay-789"));

        // When
        Order result = orderService.placeOrder(command);

        // Then
        assertThat(result.getId()).isNotNull();
        assertThat(result.getStatus()).isEqualTo(OrderStatus.CONFIRMED);
        assertThat(result.getTotal()).isEqualByComparingTo(Money.of(100, EUR));

        verify(orderRepository).save(any(Order.class));
        verify(paymentGateway).charge(eq(Money.of(100, EUR)), any(PaymentMethod.class));
        verify(eventPublisher).publish(any(OrderPlacedEvent.class));
    }

    @Test
    @DisplayName("should reject order when payment fails")
    void shouldRejectOrderWhenPaymentFails() {
        // Given
        PlaceOrderCommand command = buildValidCommand();
        when(paymentGateway.charge(any(), any()))
            .thenReturn(PaymentResult.failure("Insufficient funds"));

        // When / Then
        assertThatThrownBy(() -> orderService.placeOrder(command))
            .isInstanceOf(PaymentFailedException.class)
            .hasMessageContaining("Insufficient funds");

        verify(orderRepository, never()).save(any()); // order must not be saved
        verify(eventPublisher, never()).publish(any()); // no event on failure
    }

    @ParameterizedTest
    @ValueSource(ints = {0, -1, -100})
    @DisplayName("should reject orders with invalid quantity")
    void shouldRejectOrdersWithInvalidQuantity(int quantity) {
        PlaceOrderCommand command = buildCommandWithQuantity(quantity);

        assertThatThrownBy(() -> orderService.placeOrder(command))
            .isInstanceOf(InvalidOrderException.class)
            .hasMessageContaining("quantity");
    }
}
```

### Integration Testing with Spring Boot Test

```java
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@AutoConfigureMockMvc
@Testcontainers
@ActiveProfiles("test")
class OrderControllerIntegrationTest {

    @Container
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16")
        .withDatabaseName("testdb")
        .withUsername("test")
        .withPassword("test");

    @Container
    static KafkaContainer kafka = new KafkaContainer(DockerImageName.parse("confluentinc/cp-kafka:7.6.0"));

    @DynamicPropertySource
    static void configureProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", postgres::getJdbcUrl);
        registry.add("spring.datasource.username", postgres::getUsername);
        registry.add("spring.datasource.password", postgres::getPassword);
        registry.add("spring.kafka.bootstrap-servers", kafka::getBootstrapServers);
    }

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @Autowired
    private OrderRepository orderRepository;

    @BeforeEach
    void setUp() {
        orderRepository.deleteAll();
    }

    @Test
    void shouldCreateOrderAndReturnCreatedStatus() throws Exception {
        PlaceOrderRequest request = PlaceOrderRequest.builder()
            .customerId("cust-123")
            .items(List.of(new OrderItemRequest("prod-456", 2)))
            .build();

        mockMvc.perform(post("/api/v1/orders")
                .contentType(MediaType.APPLICATION_JSON)
                .content(objectMapper.writeValueAsString(request))
                .header("Authorization", "Bearer " + getTestJwt()))
            .andExpect(status().isCreated())
            .andExpect(jsonPath("$.id").isNotEmpty())
            .andExpect(jsonPath("$.status").value("CONFIRMED"))
            .andExpect(jsonPath("$.total.amount").isNumber());
    }
}
```

### Test-Driven Development (TDD)

TDD follows three steps, repeated: **Red → Green → Refactor**

1. **Red**: Write a failing test for the behavior you want
2. **Green**: Write the minimum code to make it pass
3. **Refactor**: Clean up the code without breaking the test

**Example — TDD for a discount calculator:**

```java
// Step 1: Write the failing test (RED)
@Test
void shouldApply20PercentDiscountForPremiumCustomers() {
    DiscountCalculator calculator = new DiscountCalculator();
    Customer premiumCustomer = Customer.premium("cust-1");
    Money price = Money.of(100, EUR);

    Money discount = calculator.calculate(price, premiumCustomer);

    assertThat(discount).isEqualByComparingTo(Money.of(20, EUR));
}

// Step 2: Write minimal code (GREEN)
public class DiscountCalculator {
    public Money calculate(Money price, Customer customer) {
        if (customer.isPremium()) {
            return price.multiply(0.20);
        }
        return Money.ZERO;
    }
}

// Step 3: Add another test (RED) — bulk discount
@Test
void shouldApply15PercentDiscountForBulkOrders() {
    DiscountCalculator calculator = new DiscountCalculator();
    Customer regularCustomer = Customer.regular("cust-2");

    Money discount = calculator.calculate(Money.of(1000, EUR), regularCustomer, 50);

    assertThat(discount).isEqualByComparingTo(Money.of(150, EUR));
}

// Update code (GREEN) — now handle quantity
public class DiscountCalculator {
    public Money calculate(Money price, Customer customer) {
        return calculate(price, customer, 1);
    }

    public Money calculate(Money price, Customer customer, int quantity) {
        if (customer.isPremium()) return price.multiply(0.20);
        if (quantity >= 50) return price.multiply(0.15);
        return Money.ZERO;
    }
}
```

### Best Practices

- **One assertion per test** — easier to diagnose failures
- **Use `@DisplayName`** — tests as documentation
- **Arrange-Act-Assert (AAA)** — clear structure with comments
- **Use test fixtures** — shared setup to avoid duplication
- **Test behavior, not implementation** — test what, not how
- **Use `@Nested`** — group related tests
- **Use `@Testcontainers`** — real infrastructure, no mocks for integration tests
- **Keep tests fast** — slow tests get skipped

### Interview Questions

**Q: What is the difference between a unit test and an integration test?**

A: A unit test tests a single class or function in complete isolation. All dependencies are mocked. It is fast (milliseconds) and tests logic only. An integration test tests how multiple components work together — often with a real database or message broker. It is slower but catches problems that unit tests miss, like SQL query errors or serialization issues.

**Q: Should you always aim for 100% code coverage?**

A: No. Coverage is a metric, not a goal. 100% coverage can mean bad tests that cover code without asserting anything meaningful. Focus on testing behavior — especially edge cases, error paths, and business rules. 80% meaningful coverage is better than 100% shallow coverage.

**Q: What is the difference between a mock and a stub?**

A: A stub provides canned answers to calls. It does not verify how it was called. A mock verifies behavior — it checks that specific methods were called with specific arguments. In Mockito: `when(mock.method()).thenReturn(value)` is a stub behavior. `verify(mock).method(arg)` is the mock verification.

---
