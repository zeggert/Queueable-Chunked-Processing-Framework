# Queueable Chunked Processing Framework

A robust, production-ready Salesforce framework for processing large datasets asynchronously using the Queueable interface with built-in chunking, retry logic, and error handling.

## Overview

This framework provides a base class `ChunkedQueueableProcessor` that simplifies the implementation of batch processing in Salesforce. It handles common concerns like:

- **Chunked Processing**: Automatically divides large datasets into manageable chunks to stay within governor limits
- **Automatic Retry Logic**: Failed records are automatically retried with configurable retry attempts
- **Error Handling**: Gracefully handles exceptions and validation failures without breaking the entire batch
- **Finalizer Support**: Uses Salesforce Finalizers to ensure processing continues even after failures
- **Flexible Configuration**: Fluent API for easy configuration of chunk size, retries, delays, and fail-fast behavior
- **Extensible Hooks**: Template methods and optional hooks for customizing behavior

## Key Features

### 🔄 Automatic Retry Mechanism
- Configurable maximum retry attempts (default: 5)
- Failed records are automatically collected and retried
- Optional delay between retry attempts (in minutes)
- Hook for handling records that exceed max retries

### 📦 Chunked Processing
- Configurable chunk size (default: 50 records per execution)
- Automatic continuation across multiple queueable jobs
- Prevents governor limit violations by processing records in batches

### ⚡ Fail-Fast Mode
- Optional fail-fast behavior for critical processing
- Throws exceptions immediately instead of collecting failures
- Useful for validation-critical workflows

### 🎯 Validation & Processing Separation
- Separate validation step before processing
- Validation failures don't consume retry attempts
- Clear separation of concerns

### 🔌 Extensible Architecture
- Template method pattern for required implementations
- Virtual hooks for optional customization
- Post-processing hook for batch operations

### 📞 Callout Support
- Implements `Database.AllowsCallouts`
- Safe for making HTTP callouts during processing

## Installation

Deploy the following classes to your Salesforce org:

1. `ChunkedQueueableProcessor.cls` - Main framework class
2. `QueuableFinalizer.cls` - Finalizer base class for restart logic
3. `ChunkedQueueableProcessorTest.cls` - Test class (optional, for development)

```bash
sfdx force:source:deploy -p force-app/main/default/classes
```

## Required Template Methods

When extending `ChunkedQueueableProcessor`, you **must** implement these abstract methods:

### 1. `processRecord(Object record)`
Process a single record from your batch.

```apex
protected abstract Boolean processRecord(Object record);
```

**Parameters:**
- `record` - The record to process (can be any object type)

**Returns:**
- `true` if processing was successful
- `false` if processing failed (record will be retried)

**Example:**
```apex
protected override Boolean processRecord(Object record) {
    Account acc = (Account)record;
    try {
        acc.Status__c = 'Processed';
        update acc;
        return true;
    } catch (Exception e) {
        return false;
    }
}
```

### 2. `validateRecord(Object record)`
Validate a record before processing. Validation failures are permanent and won't be retried.

```apex
protected abstract String validateRecord(Object record);
```

**Parameters:**
- `record` - The record to validate

**Returns:**
- `null` if the record is valid
- Error message string if validation fails

**Example:**
```apex
protected override String validateRecord(Object record) {
    Account acc = (Account)record;
    if (String.isBlank(acc.Name)) {
        return 'Account Name is required';
    }
    if (acc.AnnualRevenue == null || acc.AnnualRevenue < 0) {
        return 'Valid Annual Revenue is required';
    }
    return null;
}
```

### 3. `getRecordsToProcess()`
Retrieve the list of records to process.

```apex
protected abstract List<Object> getRecordsToProcess();
```

**Returns:**
- List of records to process (can be any object type)

**Example:**
```apex
protected override List<Object> getRecordsToProcess() {
    return [SELECT Id, Name, Status__c 
            FROM Account 
            WHERE Status__c = 'Pending' 
            LIMIT 1000];
}
```

### 4. `createNew(List<Object> failedRecords, Integer nextAttempt, Integer maxRetries, Integer chunkSize)`
Create a new instance of your processor for retry attempts.

```apex
protected abstract ChunkedQueueableProcessor createNew(
    List<Object> failedRecords, 
    Integer nextAttempt, 
    Integer maxRetries, 
    Integer chunkSize
);
```

**Parameters:**
- `failedRecords` - Records that failed and need retry
- `nextAttempt` - The next attempt number
- `maxRetries` - Maximum retry attempts
- `chunkSize` - Chunk size for processing

**Returns:**
- New instance of your processor class

**Example:**
```apex
protected override ChunkedQueueableProcessor createNew(
    List<Object> failedRecords, 
    Integer nextAttempt, 
    Integer maxRetries, 
    Integer chunkSize
) {
    AccountProcessor newInstance = new AccountProcessor();
    newInstance.recordsToRetry = failedRecords;
    newInstance.attemptCount = nextAttempt;
    newInstance.maxRetries = maxRetries;
    newInstance.chunkSize = chunkSize;
    return newInstance;
}
```

## Optional Hooks (Virtual Methods)

These methods have default implementations but can be overridden for custom behavior:

### 1. `postProcessing(List<Object> processedRecords)`
Called after a chunk of records has been successfully processed.

```apex
protected virtual void postProcessing(List<Object> processedRecords);
```

**Use Cases:**
- Sending summary emails
- Updating aggregate records
- Logging batch completion
- Triggering downstream processes

**Example:**
```apex
protected override void postProcessing(List<Object> processedRecords) {
    // Send notification email after each chunk
    Integer count = processedRecords.size();
    Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
    email.setToAddresses(new String[]{'admin@example.com'});
    email.setSubject('Batch Progress Update');
    email.setPlainTextBody('Successfully processed ' + count + ' accounts');
    Messaging.sendEmail(new Messaging.SingleEmailMessage[]{email});
}
```

### 2. `onMaxRetriesReached(List<Object> failedRecords)`
Called when records have exhausted all retry attempts.

```apex
protected virtual void onMaxRetriesReached(List<Object> failedRecords);
```

**Use Cases:**
- Logging permanently failed records
- Creating error records in a custom object
- Sending alert emails for manual intervention
- Moving records to a dead-letter queue

**Example:**
```apex
protected override void onMaxRetriesReached(List<Object> failedRecords) {
    // Log permanently failed records
    List<Error_Log__c> errorLogs = new List<Error_Log__c>();
    for (Object record : failedRecords) {
        Account acc = (Account)record;
        errorLogs.add(new Error_Log__c(
            Record_Id__c = acc.Id,
            Record_Type__c = 'Account',
            Error_Message__c = 'Failed after ' + maxRetries + ' attempts',
            Failed_Date__c = System.now()
        ));
    }
    insert errorLogs;
    
    // Send alert email
    Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
    email.setToAddresses(new String[]{'support@example.com'});
    email.setSubject('ALERT: Records Failed Processing');
    email.setPlainTextBody('Failed to process ' + failedRecords.size() + ' records after all retries');
    Messaging.sendEmail(new Messaging.SingleEmailMessage[]{email});
}
```

## Fluent API Configuration

The framework provides a fluent API for easy configuration. All configuration methods return `this` for method chaining.

### `setChunkSize(Integer newChunkSize)`
Set the number of records to process in each execution.

```apex
public ChunkedQueueableProcessor setChunkSize(Integer newChunkSize);
```

**Default:** 50  
**Valid Range:** > 0

**Example:**
```apex
AccountProcessor processor = new AccountProcessor()
    .setChunkSize(100);
```

### `setMaxRetries(Integer newMax)`
Set the maximum number of retry attempts for failed records.

```apex
public ChunkedQueueableProcessor setMaxRetries(Integer newMax);
```

**Default:** 5  
**Valid Range:** >= 0 (0 means no retries)

**Example:**
```apex
AccountProcessor processor = new AccountProcessor()
    .setMaxRetries(3);
```

### `setDelayMinutes(Integer minutes)`
Set the delay in minutes before retrying failed records.

```apex
public ChunkedQueueableProcessor setDelayMinutes(Integer minutes);
```

**Default:** 0 (no delay)  
**Valid Range:** >= 0

**Example:**
```apex
AccountProcessor processor = new AccountProcessor()
    .setDelayMinutes(5); // Wait 5 minutes before retry
```

### `setFailFast(Boolean enabled)`
Enable or disable fail-fast behavior.

```apex
public ChunkedQueueableProcessor setFailFast(Boolean enabled);
```

**Default:** false  
**Behavior:**
- `true` - Throw exceptions immediately, stop processing
- `false` - Collect failures for retry

**Example:**
```apex
AccountProcessor processor = new AccountProcessor()
    .setFailFast(true);
```

### Method Chaining Example

```apex
AccountProcessor processor = new AccountProcessor()
    .setChunkSize(75)
    .setMaxRetries(3)
    .setDelayMinutes(2)
    .setFailFast(false);

System.enqueueJob(processor);
```

## Complete Usage Examples

### Example 1: Basic Account Processor

```apex
public class AccountProcessor extends ChunkedQueueableProcessor {
    private List<Account> accounts;
    
    public AccountProcessor() {
        this.accounts = new List<Account>();
    }
    
    protected override List<Object> getRecordsToProcess() {
        if (this.accounts.isEmpty()) {
            this.accounts = [SELECT Id, Name, AnnualRevenue 
                            FROM Account 
                            WHERE Status__c = 'Pending'
                            LIMIT 1000];
        }
        return this.accounts;
    }
    
    protected override String validateRecord(Object record) {
        Account acc = (Account)record;
        if (String.isBlank(acc.Name)) {
            return 'Account name is required';
        }
        return null;
    }
    
    protected override Boolean processRecord(Object record) {
        Account acc = (Account)record;
        acc.Status__c = 'Processed';
        acc.Processed_Date__c = System.now();
        update acc;
        return true;
    }
    
    protected override ChunkedQueueableProcessor createNew(
        List<Object> failedRecords, 
        Integer nextAttempt, 
        Integer maxRetries, 
        Integer chunkSize
    ) {
        AccountProcessor newInstance = new AccountProcessor();
        newInstance.accounts = (List<Account>)failedRecords;
        newInstance.attemptCount = nextAttempt;
        newInstance.maxRetries = maxRetries;
        newInstance.chunkSize = chunkSize;
        return newInstance;
    }
}

// Usage
AccountProcessor processor = new AccountProcessor()
    .setChunkSize(50)
    .setMaxRetries(3);
    
System.enqueueJob(processor);
```

### Example 2: Advanced Processor with All Hooks

```apex
public class ContactEnrichmentProcessor extends ChunkedQueueableProcessor {
    private List<Contact> contacts;
    
    protected override List<Object> getRecordsToProcess() {
        if (this.contacts == null || this.contacts.isEmpty()) {
            this.contacts = [SELECT Id, Email, FirstName, LastName 
                            FROM Contact 
                            WHERE Enrichment_Status__c = 'Pending'
                            LIMIT 500];
        }
        return this.contacts;
    }
    
    protected override String validateRecord(Object record) {
        Contact con = (Contact)record;
        if (String.isBlank(con.Email)) {
            return 'Email is required for enrichment';
        }
        if (!Pattern.matches('[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}', con.Email)) {
            return 'Invalid email format';
        }
        return null;
    }
    
    protected override Boolean processRecord(Object record) {
        Contact con = (Contact)record;
        
        // Make callout to enrichment service
        Http http = new Http();
        HttpRequest request = new HttpRequest();
        request.setEndpoint('https://api.enrichment.service/enrich');
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setBody(JSON.serialize(new Map<String, String>{
            'email' => con.Email
        }));
        
        HttpResponse response = http.send(request);
        if (response.getStatusCode() == 200) {
            Map<String, Object> data = (Map<String, Object>)JSON.deserializeUntyped(response.getBody());
            con.Company__c = (String)data.get('company');
            con.Title = (String)data.get('title');
            con.Enrichment_Status__c = 'Completed';
            update con;
            return true;
        }
        
        return false; // Will retry
    }
    
    protected override void postProcessing(List<Object> processedRecords) {
        // Update summary statistics
        Integer enrichedCount = processedRecords.size();
        Enrichment_Summary__c summary = [SELECT Id, Total_Enriched__c 
                                        FROM Enrichment_Summary__c 
                                        LIMIT 1];
        summary.Total_Enriched__c += enrichedCount;
        summary.Last_Run__c = System.now();
        update summary;
    }
    
    protected override void onMaxRetriesReached(List<Object> failedRecords) {
        // Create error records for manual review
        List<Enrichment_Error__c> errors = new List<Enrichment_Error__c>();
        for (Object record : failedRecords) {
            Contact con = (Contact)record;
            errors.add(new Enrichment_Error__c(
                Contact__c = con.Id,
                Error_Message__c = 'Failed after ' + maxRetries + ' attempts',
                Requires_Manual_Review__c = true
            ));
        }
        insert errors;
    }
    
    protected override ChunkedQueueableProcessor createNew(
        List<Object> failedRecords, 
        Integer nextAttempt, 
        Integer maxRetries, 
        Integer chunkSize
    ) {
        ContactEnrichmentProcessor newInstance = new ContactEnrichmentProcessor();
        newInstance.contacts = (List<Contact>)failedRecords;
        newInstance.attemptCount = nextAttempt;
        newInstance.maxRetries = maxRetries;
        newInstance.chunkSize = chunkSize;
        return newInstance;
    }
}

// Usage with full configuration
ContactEnrichmentProcessor processor = new ContactEnrichmentProcessor()
    .setChunkSize(25)          // Smaller chunks for callouts
    .setMaxRetries(5)          // More retries for API failures
    .setDelayMinutes(2)        // Wait 2 minutes between retries
    .setFailFast(false);       // Collect all failures
    
System.enqueueJob(processor);
```

### Example 3: Custom Object Processing with Type Safety

```apex
public class OrderFulfillmentProcessor extends ChunkedQueueableProcessor {
    private List<Order__c> orders;
    
    protected override List<Object> getRecordsToProcess() {
        if (this.orders == null) {
            this.orders = [SELECT Id, Order_Number__c, Total_Amount__c, Status__c
                          FROM Order__c 
                          WHERE Status__c = 'Ready for Fulfillment'
                          LIMIT 200];
        }
        return this.orders;
    }
    
    protected override String validateRecord(Object record) {
        Order__c order = (Order__c)record;
        
        // Multiple validation rules
        if (order.Total_Amount__c == null || order.Total_Amount__c <= 0) {
            return 'Invalid order amount';
        }
        
        if (String.isBlank(order.Order_Number__c)) {
            return 'Order number is required';
        }
        
        // Check for required line items
        Integer lineItemCount = [SELECT COUNT() 
                                FROM Order_Line_Item__c 
                                WHERE Order__c = :order.Id];
        if (lineItemCount == 0) {
            return 'Order must have at least one line item';
        }
        
        return null;
    }
    
    protected override Boolean processRecord(Object record) {
        Order__c order = (Order__c)record;
        
        try {
            // Create fulfillment record
            Fulfillment__c fulfillment = new Fulfillment__c(
                Order__c = order.Id,
                Status__c = 'Processing',
                Created_Date__c = System.now()
            );
            insert fulfillment;
            
            // Update order status
            order.Status__c = 'Fulfillment In Progress';
            order.Fulfillment__c = fulfillment.Id;
            update order;
            
            return true;
        } catch (DmlException e) {
            System.debug('DML Error: ' + e.getMessage());
            return false;
        }
    }
    
    protected override ChunkedQueueableProcessor createNew(
        List<Object> failedRecords, 
        Integer nextAttempt, 
        Integer maxRetries, 
        Integer chunkSize
    ) {
        OrderFulfillmentProcessor newInstance = new OrderFulfillmentProcessor();
        newInstance.orders = (List<Order__c>)failedRecords;
        newInstance.attemptCount = nextAttempt;
        newInstance.maxRetries = maxRetries;
        newInstance.chunkSize = chunkSize;
        return newInstance;
    }
}

// Usage
System.enqueueJob(
    new OrderFulfillmentProcessor()
        .setChunkSize(50)
        .setMaxRetries(3)
);
```

## Advanced Patterns

### Pattern 1: Scheduled Processing

```apex
public class ScheduledAccountProcessor implements Schedulable {
    public void execute(SchedulableContext sc) {
        AccountProcessor processor = new AccountProcessor()
            .setChunkSize(100)
            .setMaxRetries(3)
            .setDelayMinutes(5);
        
        System.enqueueJob(processor);
    }
}

// Schedule to run daily at 2 AM
String cronExp = '0 0 2 * * ?';
System.schedule('Daily Account Processing', cronExp, new ScheduledAccountProcessor());
```

### Pattern 2: Triggered Processing

```apex
trigger AccountTrigger on Account (after insert, after update) {
    if (Trigger.isAfter && (Trigger.isInsert || Trigger.isUpdate)) {
        // Check if there are accounts that need processing
        List<Account> needsProcessing = new List<Account>();
        for (Account acc : Trigger.new) {
            if (acc.Status__c == 'Pending') {
                needsProcessing.add(acc);
            }
        }
        
        if (!needsProcessing.isEmpty()) {
            // Enqueue processor for new pending accounts
            System.enqueueJob(
                new AccountProcessor()
                    .setChunkSize(50)
                    .setMaxRetries(2)
            );
        }
    }
}
```

### Pattern 3: Configurable Processing

```apex
// Custom settings for configuration
Processor_Settings__c settings = Processor_Settings__c.getInstance();

AccountProcessor processor = new AccountProcessor()
    .setChunkSize(Integer.valueOf(settings.Chunk_Size__c))
    .setMaxRetries(Integer.valueOf(settings.Max_Retries__c))
    .setDelayMinutes(Integer.valueOf(settings.Retry_Delay_Minutes__c))
    .setFailFast(settings.Fail_Fast__c);

System.enqueueJob(processor);
```

## Best Practices

1. **Chunk Size Selection**
   - Start with default (50) and adjust based on processing complexity
   - Use smaller chunks (10-25) for callout-heavy processing
   - Use larger chunks (75-100) for simple DML operations

2. **Retry Strategy**
   - Use 3-5 retries for external API calls
   - Use 1-2 retries for DML operations
   - Set retry delays for rate-limited APIs

3. **Validation**
   - Perform all validation in `validateRecord()` method
   - Keep validation logic separate from processing
   - Return clear, actionable error messages

4. **Error Handling**
   - Implement `onMaxRetriesReached()` for critical failures
   - Log permanently failed records for manual review
   - Use `postProcessing()` for batch-level operations

5. **Testing**
   - Test with various record counts (0, 1, chunk size, > chunk size)
   - Test validation failures
   - Test processing failures and retries
   - Use `Test.startTest()` and `Test.stopTest()` to control async execution

6. **Governor Limits**
   - Be mindful of SOQL queries in `getRecordsToProcess()`
   - Cache records when possible
   - Consider DML limits in `processRecord()`

## Troubleshooting

### Issue: Records not being processed
- Check that `getRecordsToProcess()` returns non-empty list
- Verify records pass validation
- Check debug logs for errors

### Issue: Infinite retry loops
- Ensure `validateRecord()` catches permanent failures
- Check that `processRecord()` returns `true` on success
- Verify retry count is not too high

### Issue: Governor limit exceptions
- Reduce chunk size
- Optimize SOQL queries
- Batch DML operations

### Issue: Records stuck in processing
- Check finalizer logs
- Verify `createNew()` correctly initializes new instance
- Ensure records are being returned correctly

## Dependencies

This framework assumes the existence of a `Logger` class for logging. The Logger class should implement:
- `Logger.debug(String message)` - Debug logging
- `Logger.error(String message)` - Error logging
- `Logger.setAsyncContext(System.FinalizerContext fc)` - Set async context
- `Logger.setExceptionDetails(Exception ex)` - Log exception details
- `Logger.saveLog()` - Persist logs

If you don't have a Logger class, you can replace Logger calls with `System.debug()` statements.

## License

This framework is provided as-is for use in Salesforce projects.

## Contributing

Contributions are welcome! Please ensure all changes include corresponding test coverage.
