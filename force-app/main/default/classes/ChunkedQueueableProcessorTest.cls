@isTest
private class ChunkedQueueableProcessorTest {
    // Static variables to track state across test instances
    public static List<Object> staticValidationFailures = new List<Object>();
    public static List<Object> staticProcessedRecords = new List<Object>();
    // Static tracking for test assertions
    public static Boolean staticPostProcessingCalled = false;
    public static Integer staticPostProcessedCount = 0;
    public static Boolean staticPostProcessingExceptionThrown = false;
    public static Boolean staticMaxRetriesReachedCalled = false;
    public static List<Object> staticMaxRetriesFailedRecords;
    
    // Mock implementation for testing
    private virtual class MockQueueableProcessor extends ChunkedQueueableProcessor {
        public List<Object> recordsToProcess;
        public List<Object> processedRecords = new List<Object>();
        public List<Object> validationFailures = new List<Object>();
        public Map<Object, Integer> processAttempts = new Map<Object, Integer>();
        public Boolean shouldFailProcessing = false;
        public Boolean shouldThrowException = false;
        public String validationErrorMessage;
        private Boolean hasReturnedRecords = false;
        
        public MockQueueableProcessor(List<Object> records) {
            this.recordsToProcess = records != null ? records : new List<Object>();
        }
        
        // Getters for testing protected variables
        public Integer getChunkSize() { return this.chunkSize; }
        public Integer getMaxRetries() { return this.maxRetries; }
        public Integer getDelayMinutes() { return this.delayMinutes; }
        public Boolean getFailFast() { return this.failFast; }
        
        protected override Boolean processRecord(Object record) {
            // Mark that we've started processing to prevent re-enqueueing after this execution
            hasReturnedRecords = true;
            
            Integer attempts = processAttempts.containsKey(record) ? processAttempts.get(record) + 1 : 1;
            processAttempts.put(record, attempts);
            
            if (shouldThrowException) {
                throw new ChunkedQueueableProcessorException('Simulated processing exception');
            }
            
            if (shouldFailProcessing) {
                return false;
            }
            
            processedRecords.add(record);
            staticProcessedRecords.add(record); // Track in static variable for test assertions
            return true;
        }
        
        protected override String validateRecord(Object record) {
            if (validationErrorMessage != null && String.valueOf(record).startsWith('INVALID')) {
                validationFailures.add(record);
                staticValidationFailures.add(record); // Track in static variable for test assertions
                return validationErrorMessage;
            }
            return null;
        }
        
        protected override List<Object> getRecordsToProcess() {
            // After first queueable execution, return empty to prevent infinite chaining
            // Return a clone so base class can modify it
            if (hasReturnedRecords) {
                return new List<Object>();
            }
            return this.recordsToProcess.clone();
        }
        
        protected virtual override ChunkedQueueableProcessor createNew(
            List<Object> failedRecords, 
            Integer nextAttempt, 
            Integer maxRetries, 
            Integer chunkSize
        ) {
            MockQueueableProcessor newInstance = new MockQueueableProcessor(failedRecords);
            newInstance.attemptCount = nextAttempt;
            newInstance.maxRetries = maxRetries;
            newInstance.chunkSize = chunkSize;
            newInstance.shouldFailProcessing = this.shouldFailProcessing;
            newInstance.shouldThrowException = this.shouldThrowException;
            return newInstance;
        }
    }
    
    @isTest
    static void testSuccessfulProcessing() {
        // Arrange
        staticProcessedRecords.clear();
        List<Object> testRecords = new List<Object>{ 'Record1', 'Record2', 'Record3' };
        MockQueueableProcessor processor = new MockQueueableProcessor(testRecords);
        
        // Act
        Test.startTest();
        System.enqueueJob(processor);
        Test.stopTest();
        
        // Assert
        System.assertEquals(3, staticProcessedRecords.size(), 'All records should be processed');
        System.assert(staticProcessedRecords.contains('Record1'), 'Record1 should be processed');
        System.assert(staticProcessedRecords.contains('Record2'), 'Record2 should be processed');
        System.assert(staticProcessedRecords.contains('Record3'), 'Record3 should be processed');
    }
    
    @isTest
    static void testChunkSizeLimit() {
        // Arrange
        staticProcessedRecords.clear();
        List<Object> testRecords = new List<Object>();
        for (Integer i = 0; i < 100; i++) {
            testRecords.add('Record' + i);
        }
        MockQueueableProcessor processor = new MockQueueableProcessor(testRecords);
        processor.setChunkSize(10);
        
        // Act
        Test.startTest();
        System.enqueueJob(processor);
        Test.stopTest();
        
        // Assert
        System.assertEquals(10, staticProcessedRecords.size(), 'Only chunk size records should be processed');
    }
    
    @isTest
    static void testValidationFailure() {
        // Arrange
        staticProcessedRecords.clear();
        staticValidationFailures.clear();
        ChunkedQueueableProcessor.lastFailedRecords.clear();
        List<Object> testRecords = new List<Object>{ 'INVALID1', 'Record2', 'INVALID2' };
        MockQueueableProcessor processor = new MockQueueableProcessor(testRecords);
        processor.validationErrorMessage = 'Invalid record format';
        
        // Act
        Test.startTest();
        System.enqueueJob(processor);
        Test.stopTest();
        
        // Assert
        System.assertEquals(1, staticProcessedRecords.size(), 'Only valid record should be processed');
        System.assert(staticProcessedRecords.contains('Record2'), 'Valid record should be processed');
        System.assertEquals(2, staticValidationFailures.size(), 'Invalid records should be tracked');
    }
    
    @isTest
    static void testProcessingFailureWithRetry() {
        // Arrange
        staticProcessedRecords.clear();
        ChunkedQueueableProcessor.lastFailedRecords.clear();
        List<Object> testRecords = new List<Object>{ 'Record1', 'Record2' };
        MockQueueableProcessor processor = new MockQueueableProcessor(testRecords);
        processor.shouldFailProcessing = true;
        processor.setMaxRetries(2);
        
        // Act
        Test.startTest();
        System.enqueueJob(processor);
        Test.stopTest();
        
        // Assert
        System.assertEquals(0, staticProcessedRecords.size(), 'No records should be processed successfully');
        System.assertEquals(2, ChunkedQueueableProcessor.lastFailedRecords.size(), 'All records should fail');
    }
    
    @isTest
    static void testExceptionHandling() {
        // Arrange
        staticProcessedRecords.clear();
        ChunkedQueueableProcessor.lastFailedRecords.clear();
        List<Object> testRecords = new List<Object>{ 'Record1', 'Record2' };
        MockQueueableProcessor processor = new MockQueueableProcessor(testRecords);
        processor.shouldThrowException = true;
        
        // Act
        Test.startTest();
        System.enqueueJob(processor);
        Test.stopTest();
        
        // Assert
        System.assertEquals(0, staticProcessedRecords.size(), 'No records should be processed due to exception');
        System.assertEquals(2, ChunkedQueueableProcessor.lastFailedRecords.size(), 'Exception records should be tracked');
    }
    
    @isTest
    static void testFailFastBehavior() {
        // Arrange
        ChunkedQueueableProcessor.lastFailedRecords.clear();
        List<Object> testRecords = new List<Object>{ 'Record1' };
        MockQueueableProcessor processor = new MockQueueableProcessor(testRecords);
        processor.setFailFast(true);
        processor.shouldThrowException = true;
        
        // Act
        Test.startTest();
        System.enqueueJob(processor);
        Test.stopTest();
        
        // Assert
        // In test context, exceptions in queueables are caught by the framework
        // With fail-fast enabled and an exception, no records should be processed
        System.assertEquals(0, staticProcessedRecords.size(), 'No records should be processed with fail-fast exception');
        System.assertEquals(1, ChunkedQueueableProcessor.lastFailedRecords.size(), 'Failed record should be tracked');
    }
    
    @isTest
    static void testSetChunkSize() {
        // Arrange & Act
        MockQueueableProcessor processor = new MockQueueableProcessor(new List<Object>());
        processor.setChunkSize(25);
        
        // Assert
        System.assertEquals(25, processor.getChunkSize(), 'Chunk size should be updated');
        
        // Test invalid values
        processor.setChunkSize(null);
        System.assertEquals(25, processor.getChunkSize(), 'Null should not change chunk size');
        
        processor.setChunkSize(-5);
        System.assertEquals(25, processor.getChunkSize(), 'Negative value should not change chunk size');
    }
    
    @isTest
    static void testSetMaxRetries() {
        // Arrange & Act
        MockQueueableProcessor processor = new MockQueueableProcessor(new List<Object>());
        processor.setMaxRetries(10);
        
        // Assert
        System.assertEquals(10, processor.getMaxRetries(), 'Max retries should be updated');
        
        // Test invalid values
        processor.setMaxRetries(null);
        System.assertEquals(10, processor.getMaxRetries(), 'Null should not change max retries');
        
        // Test zero retries (valid)
        processor.setMaxRetries(0);
        System.assertEquals(0, processor.getMaxRetries(), 'Zero retries should be allowed');
    }
    
    @isTest
    static void testSetDelayMinutes() {
        // Arrange & Act
        MockQueueableProcessor processor = new MockQueueableProcessor(new List<Object>());
        processor.setDelayMinutes(5);
        
        // Assert
        System.assertEquals(5, processor.getDelayMinutes(), 'Delay minutes should be updated');
        
        // Test invalid values
        processor.setDelayMinutes(null);
        System.assertEquals(5, processor.getDelayMinutes(), 'Null should not change delay');
        
        processor.setDelayMinutes(-1);
        System.assertEquals(5, processor.getDelayMinutes(), 'Negative value should not change delay');
    }
    
    @isTest
    static void testMethodChaining() {
        // Arrange & Act
        MockQueueableProcessor processor = new MockQueueableProcessor(new List<Object>());
        processor.setChunkSize(30)
            .setMaxRetries(3)
            .setDelayMinutes(2)
            .setFailFast(true);
        
        // Assert
        System.assertEquals(30, processor.getChunkSize(), 'Chunk size should be set');
        System.assertEquals(3, processor.getMaxRetries(), 'Max retries should be set');
        System.assertEquals(2, processor.getDelayMinutes(), 'Delay should be set');
        System.assertEquals(true, processor.getFailFast(), 'Fail fast should be set');
    }
    
    @isTest
    static void testEmptyRecordList() {
        // Arrange
        MockQueueableProcessor processor = new MockQueueableProcessor(new List<Object>());
        
        // Act
        Test.startTest();
        System.enqueueJob(processor);
        Test.stopTest();
        
        // Assert
        System.assertEquals(0, processor.processedRecords.size(), 'No records should be processed');
    }
    
    @isTest
    static void testNullRecordList() {
        // Arrange
        MockQueueableProcessor processor = new MockQueueableProcessor(null);
        
        // Act
        Test.startTest();
        System.enqueueJob(processor);
        Test.stopTest();
        
        // Assert
        System.assertEquals(0, processor.processedRecords.size(), 'No records should be processed');
    }
    
    @isTest
    static void testPostProcessingHook() {
        // Arrange
        staticProcessedRecords.clear();
        staticPostProcessingCalled = false;
        staticPostProcessedCount = 0;
        MockQueueableProcessorWithPostProcessing processor = new MockQueueableProcessorWithPostProcessing(
            new List<Object>{ 'Record1', 'Record2' }
        );
        
        // Act
        Test.startTest();
        System.enqueueJob(processor);
        Test.stopTest();
        
        // Assert
        System.assertEquals(2, staticProcessedRecords.size(), 'Both records should be processed first');
        System.assert(staticPostProcessingCalled, 'Post processing should be called');
        System.assertEquals(2, staticPostProcessedCount, 'All successful records should be passed to post processing');
    }
    
    @isTest
    static void testPostProcessingWithException() {
        // Arrange
        staticPostProcessingCalled = false;
        staticPostProcessingExceptionThrown = false;
        ChunkedQueueableProcessor.lastFailedRecords.clear();
        MockQueueableProcessorWithPostProcessing processor = new MockQueueableProcessorWithPostProcessing(
            new List<Object>{ 'Record1' }
        );
        processor.shouldThrowInPostProcessing = true;
        
        // Act
        Test.startTest();
        System.enqueueJob(processor);
        Test.stopTest();
        
        // Assert
        System.assert(staticPostProcessingCalled, 'Post processing should be called');
        System.assert(staticPostProcessingExceptionThrown, 'Exception should have been thrown');
    }
    
    @isTest
    static void testOnMaxRetriesReachedHook() {
        // Arrange
        staticMaxRetriesReachedCalled = false;
        staticMaxRetriesFailedRecords = null;
        MockQueueableProcessorWithMaxRetriesHook processor = new MockQueueableProcessorWithMaxRetriesHook(
            new List<Object>{ 'Record1' }
        );
        processor.shouldFailProcessing = true;
        processor.setMaxRetries(0); // Set to 0 so it fails immediately without needing retry
        
        // Act
        Test.startTest();
        System.enqueueJob(processor);
        Test.stopTest();
        
        // Assert
        System.assert(staticMaxRetriesReachedCalled, 'Max retries hook should be called');
        System.assertEquals(1, staticMaxRetriesFailedRecords.size(), 'Failed records should be passed to hook');
    }
    
    // Helper classes for post-processing and max retries testing
    private class MockQueueableProcessorWithPostProcessing extends MockQueueableProcessor {
        public Boolean postProcessingCalled = false;
        public Integer postProcessedCount = 0;
        public Boolean shouldThrowInPostProcessing = false;
        
        public MockQueueableProcessorWithPostProcessing(List<Object> records) {
            super(records);
        }
        
        protected override void postProcessing(List<Object> processedRecords) {
            postProcessingCalled = true;
            postProcessedCount = processedRecords.size();
            staticPostProcessingCalled = true;
            staticPostProcessedCount = processedRecords.size();
            
            if (shouldThrowInPostProcessing) {
                staticPostProcessingExceptionThrown = true;
                throw new ChunkedQueueableProcessorException('Post processing failed');
            }
        }
        
        protected override ChunkedQueueableProcessor createNew(
            List<Object> failedRecords, 
            Integer nextAttempt, 
            Integer maxRetries, 
            Integer chunkSize
        ) {
            MockQueueableProcessorWithPostProcessing newInstance = 
                new MockQueueableProcessorWithPostProcessing(failedRecords);
            newInstance.attemptCount = nextAttempt;
            newInstance.maxRetries = maxRetries;
            newInstance.chunkSize = chunkSize;
            newInstance.shouldFailProcessing = this.shouldFailProcessing;
            newInstance.shouldThrowInPostProcessing = this.shouldThrowInPostProcessing;
            return newInstance;
        }
    }
    
    private class MockQueueableProcessorWithMaxRetriesHook extends MockQueueableProcessor {
        public Boolean maxRetriesReachedCalled = false;
        public List<Object> maxRetriesFailedRecords;
        
        public MockQueueableProcessorWithMaxRetriesHook(List<Object> records) {
            super(records);
        }
        
        protected override void onMaxRetriesReached(List<Object> failedRecords) {
            maxRetriesReachedCalled = true;
            maxRetriesFailedRecords = failedRecords;
            staticMaxRetriesReachedCalled = true;
            staticMaxRetriesFailedRecords = failedRecords;
        }
        
        protected override ChunkedQueueableProcessor createNew(
            List<Object> failedRecords, 
            Integer nextAttempt, 
            Integer maxRetries, 
            Integer chunkSize
        ) {
            MockQueueableProcessorWithMaxRetriesHook newInstance = 
                new MockQueueableProcessorWithMaxRetriesHook(failedRecords);
            newInstance.attemptCount = nextAttempt;
            newInstance.maxRetries = maxRetries;
            newInstance.chunkSize = chunkSize;
            newInstance.shouldFailProcessing = this.shouldFailProcessing;
            return newInstance;
        }
    }
}