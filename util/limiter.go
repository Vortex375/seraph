package util

import (
	"context"
	"sync"
)

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
	Begin(context.Context) bool
	End()
	Join()
}

type empty = struct{}

type limiter struct {
	limitChan chan empty
	mu        sync.Mutex
	cond      *sync.Cond
	count     int
}

func NewLimiter(limit int) Limiter {
	lim := limiter{
		limitChan: make(chan empty, limit),
		// cancelChan: make(chan empty),
	}
	lim.cond = sync.NewCond(&lim.mu)
	return &lim
}

func (l *limiter) Begin(ctx context.Context) bool {
	select {
	case l.limitChan <- empty{}:
		l.mu.Lock()
		defer l.mu.Unlock()
		l.count++
		return true
	case <-ctx.Done():
		return false
	}
}

func (l *limiter) End() {
	<-l.limitChan
	l.mu.Lock()
	defer l.mu.Unlock()
	l.count--
	if l.count == 0 {
		l.cond.Broadcast()
	}
}

func (l *limiter) Join() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.count == 0 {
		return
	}
	l.cond.Wait()
}
