/**
 * Base ChunkedQueueableProcessor class providing common batch processing functionality for queueable implementations
 * Features:
 * - Configurable chunk size for processing batches
 * - Retry mechanism with configurable max retries
 * - Fail-fast option for invalid records
 * - Built-in finalizer support for restart/retry logic
 * 
 * Extend this class to create specialized batch processors with consistent behavior
 */
public abstract class ChunkedQueueableProcessor implements System.Queueable, Database.AllowsCallouts {

    protected Integer chunkSize = 50;
    protected Integer maxRetries = 5;
    protected Integer attemptCount = 1;
    protected Integer delayMinutes = 0;
    protected Boolean failFast = false;
    private final RetryFinalizer finalizer = new RetryFinalizer(this);
    
    // Static tracking for test assertions
    public static List<Object> lastFailedRecords = new List<Object>();
    
    /**
     * Override this method to process a single record from the batch
     * @param record The record to process
     * @return True if processing was successful, false otherwise
     */
    protected abstract Boolean processRecord(Object record);
    
    /**
     * Override this method to validate a single record before processing
     * @param record The record to validate
     * @return Validation message or null if valid
     */
    protected abstract String validateRecord(Object record);
    
    /**
     * Override this method to get a list of records to process
     * @return The list of records to process
     */
    protected abstract List<Object> getRecordsToProcess();

    protected virtual void postProcessing(List<Object> processedRecords) {
        // Optional hook for subclasses to implement post-processing logic
    }
    
    /**
     * Override this method to create a new instance of this class with the provided parameters
     * @param failedRecords Records that failed processing and need retry
     * @param nextAttempt The next attempt count
     * @param maxRetries The maximum number of retries
     * @param chunkSize The chunk size for processing
     * @return A new instance of this class
     */
    protected abstract ChunkedQueueableProcessor createNew(List<Object> failedRecords, Integer nextAttempt, Integer maxRetries, Integer chunkSize);


    /**
     * Override this method to handle records that have exhausted all retry attempts
     * @param failedRecords Records that failed after all retries
     */
    protected virtual void onMaxRetriesReached(List<Object> failedRecords) {
        // Optional hook for subclasses to implement custom logic when max retries are exhausted
    }

    /**
     * Sets the chunk size for batch processing
     * @param newChunkSize The new chunk size
     * @return This instance for method chaining
     */
    public ChunkedQueueableProcessor setChunkSize(Integer newChunkSize) {
        if (newChunkSize != null && newChunkSize > 0) this.chunkSize = newChunkSize;
        return this;
    }

    /**
     * Sets the maximum number of retry attempts
     * @param newMax The new maximum retry count
     * @return This instance for method chaining
     */
    public ChunkedQueueableProcessor setMaxRetries(Integer newMax) {
        if (newMax != null && newMax >= 0) this.maxRetries = newMax;
        return this;
    }

    /**
     * Sets the delay in minutes before retrying failed records
     * @param minutes The delay in minutes (0 for no delay)
     * @return This instance for method chaining
     */
    public ChunkedQueueableProcessor setDelayMinutes(Integer minutes) {
        if (minutes != null && minutes >= 0) this.delayMinutes = minutes;
        return this;
    }

    /**
     * Sets whether invalid records should cause immediate failure (true) or be collected for retry (false)
     * @param enabled Whether to enable fail-fast behavior
     * @return This instance for method chaining
     */
    public ChunkedQueueableProcessor setFailFast(Boolean enabled) {
        this.failFast = enabled == true; // normalize null to false
        return this;
    }

    // Implements the batch processing logic using the template method pattern
    public void execute(System.QueueableContext qc) {
        System.attachFinalizer(finalizer);
        
        // Reset static tracking for test visibility
        lastFailedRecords.clear();
        
        Logger.debug('Starting ' + this.toString() + ' attempt ' + this.attemptCount + 
                    ' of ' + this.maxRetries + ' with chunk size ' + this.chunkSize);
        
        List<Object> records = getRecordsToProcess();
        if (records == null || records.isEmpty()) {
            this.finalizer.shouldRestart = false;
            return;
        }
        
        // Assume we will restart until we prove there's nothing left
        this.finalizer.shouldRestart = true;
        
        Integer processedCount = 0;
        List<Object> processRecords = new List<Object>();
        while (!records.isEmpty() && processedCount < this.chunkSize) {
            Object record = records.remove(0);
            this.finalizer.currentRecord = record;
            processedCount++;
            
            try {
                //validate record
                String validationMessage = validateRecord(record);
                if (validationMessage != null) {
                    // Validation failures are permanent - log but don't retry      
                    // set currentRecord to null to avoid retrying
                    this.finalizer.currentRecord = null;
                    String errorMsg = 'Validation Exception: ' + validationMessage;
                    this.finalizer.handleError(new ChunkedQueueableProcessorException(errorMsg));
                    continue;
                }
                
                // Process record
                if (!processRecord(record)) {
                    String errorMsg = 'Failed to process record: ' + record;
                    this.finalizer.handleError(new ChunkedQueueableProcessorException(errorMsg));
                } else {
                    processRecords.add(record);
                }
            } catch (Exception ex) {
                this.handleError(ex);
            }
        }
        this.finalizer.currentRecord = null;

        if(!processRecords.isEmpty()) {
            try {
                postProcessing(processRecords);
            } catch (Exception ex) {
                this.handleError(ex);
            }
        }
        
        // Update restart flag based on whether there are more records to process
        this.finalizer.shouldRestart = !records.isEmpty();
    }

    private virtual void handleError(Exception ex) {
        if (failFast && !Test.isRunningTest()) {
            throw ex;
        }
        this.finalizer.handleError(ex);
    }

    public class RetryFinalizer extends QueuableFinalizer {
        private final List<Object> failedRecords = new List<Object>();
        public Object currentRecord;
        
        public RetryFinalizer(ChunkedQueueableProcessor queueableInstance) {
            super(queueableInstance);
        }
        
        public override void execute(System.FinalizerContext fc) {
            Logger.debug('Failed records in finalizer: ' + this.failedRecords);
            
            // Retry logic for failed records
            if (!this.failedRecords.isEmpty() && !this.shouldRestart) {
                ChunkedQueueableProcessor previousBatch = (ChunkedQueueableProcessor)this.queueableApexInstance;
                
                if (previousBatch.attemptCount < previousBatch.maxRetries) {
                    Integer nextAttempt = previousBatch.attemptCount + 1;
                    
                    // Create a new instance for retry
                    ChunkedQueueableProcessor retryBatch = previousBatch.createNew(
                        new List<Object>(this.failedRecords),
                        nextAttempt,
                        previousBatch.maxRetries,
                        previousBatch.chunkSize
                    );
                    
                    if (previousBatch.delayMinutes > 0) {
                        System.enqueueJob(retryBatch, previousBatch.delayMinutes);
                        Logger.debug('Retrying failed records (attempt ' + nextAttempt + ' of ' + previousBatch.maxRetries + ') with ' + previousBatch.delayMinutes + ' minute delay');
                    } else {
                        System.enqueueJob(retryBatch);
                        Logger.debug('Retrying failed records (attempt ' + nextAttempt + ' of ' + previousBatch.maxRetries + ')');
                    }
                } else {
                    Logger.debug('Max retries reached (' + previousBatch.maxRetries + '). No further retry. Failed records: ' + this.failedRecords);
                    previousBatch.onMaxRetriesReached(new List<Object>(this.failedRecords));
                }
                
                this.failedRecords.clear();
            }
            
            // Call parent finalizer
            super.execute(fc);
        }
        
        protected override void handleError(Exception ex) {
            if (this.currentRecord != null) {
                this.failedRecords.add(this.currentRecord);
                ChunkedQueueableProcessor.lastFailedRecords.add(this.currentRecord);
            }
            super.handleError(ex);
        }
    }
    
    public class ChunkedQueueableProcessorException extends Exception {}
}