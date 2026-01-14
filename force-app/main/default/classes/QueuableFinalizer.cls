public virtual class QueuableFinalizer implements System.Finalizer {
  public Boolean shouldRestart = false;

  protected final System.Queueable queueableApexInstance;

  public QueuableFinalizer(System.Queueable queueableApexInstance) {
    this.queueableApexInstance = queueableApexInstance;
  }

  public virtual void execute(System.FinalizerContext fc) {
    Logger.setAsyncContext(fc);
    Logger.debug('Finalizer result: ' + fc.getResult());
    Logger.debug('Should restart? ' + this.shouldRestart);

    switch on fc?.getResult() {
      when UNHANDLED_EXCEPTION {
        this.handleError(fc.getException());
      }
    }

    if (this.shouldRestart) {
      System.debug('Starting up again');
      System.enqueueJob(this.queueableApexInstance);
    }
    Logger.saveLog();
  }

  protected virtual void handleError(Exception ex) {
    Logger.error('An error occurred during last queueable run').setExceptionDetails(ex);
  }
}