package util

// Limiter can be used to limit the number of concurrent operations.
//
// A call to [Limiter.Begin()] will block when the maximum concurrency has been reached.
//
// Callers of [Limiter.Begin()] must call [Limiter.End()] when the operation finishes
// in order to allow other tasks to run.
//
// [CancelAll()] can be called in order to abort all currently waiting tasks.
// In this case, [Begin()] will return false to indicate that the task was cancelled.
//
// Usage example:
//
//	if !limiter.Begin() {
//		return
//	}
//	defer limiter.End()
type Limiter interface {
	Begin() bool
	End()
	CancelAll()
}

type limiter struct {
	limitChan  chan bool
	cancelChan chan bool
}

func NewLimiter(limit int) Limiter {
	return &limiter{
		limitChan:  make(chan bool, limit),
		cancelChan: make(chan bool),
	}
}

func (l *limiter) Begin() bool {
	select {
	case l.limitChan <- true:
		return true
	case <-l.cancelChan:
		return false
	}
}

func (l *limiter) End() {
	<-l.limitChan
}

func (l *limiter) CancelAll() {
	close(l.cancelChan)
}
