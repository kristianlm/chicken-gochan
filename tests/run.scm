
(cond-expand
 (chicken-5
  (import gochan test
	  (only srfi-18 thread-start! thread-yield! thread-sleep! thread-state thread-join!)
          (only (chicken sort) sort)
          (only (chicken time) current-milliseconds)
	  (only srfi-1 list-tabulate make-list count)))
 (else
  (use gochan test
       (only srfi-18 thread-start! thread-yield! thread-sleep! thread-state thread-join!)
       (only data-structures sort)
       (only srfi-1 list-tabulate make-list count))))
;;(define-syntax test (syntax-rules () ((_ body ...) (begin body ...))))

;; todo:
;; - unbuffered synchronous
;; - unbuffered multiple receivers
;; - unbuffered multiple senders
;; - unbuffered send&recv on channel

(test-group
 "unbuffered 1 channel gochan-select* meta"
 (define chan (gochan 0))
 (go (gochan-send chan 'hello))
 ;;      msg   fail meta
 (test '(hello #f   meta!) (receive (gochan-select* `((,chan meta!))))))

(test-group
 "unbuffered 2 channels, 1 channel ready"
 (define chan1 (gochan 0))
 (define chan2 (gochan 0))
 (go (gochan-send chan1 'one)
     (gochan-send chan1 'two))

 (test "pick from data-ready in order data first"
       'one
       (gochan-select ((chan1 -> msg) msg)
                      ((chan2 -> msg) 'wrong!)))
 (test "pick from data-ready in order data last"
       'two
       (gochan-select ((chan2 -> msg) 'wrong!)
                      ((chan1 -> msg) msg))))

(test-group
 "unbuffered 2 channels, 2 channels ready"
 (define chan1 (gochan 0))
 (define chan2 (gochan 0))
 (go (gochan-send chan1 1)
     (gochan-send chan1 2))
 (go (gochan-send chan2 3)
     (gochan-send chan2 4))

 (test "all messages received exactly once (order unknown by design)"
       '(1 2 3 4)
       (sort
        (list (gochan-select ((chan1 -> msg) msg)
                             ((chan2 -> msg) msg))
              (gochan-select ((chan1 -> msg) msg)
                             ((chan2 -> msg) msg))
              (gochan-select ((chan2 -> msg) msg)
                             ((chan1 -> msg) msg))
              (gochan-select ((chan2 -> msg) msg)
                             ((chan1 -> msg) msg)))
        <)))

(test-group
 "unbuffered 1 channel fifo, primordial first"

 (define chan (gochan 0))
 (go (thread-yield!)
     (gochan-send chan 1)
     (gochan-send chan 2))
 (test "1 channel fifo priomaridal first" 1 (gochan-recv chan))
 (test "1 channel fifo priomaridal first" 2 (gochan-recv chan))

 (define chan (gochan 0))
 (go (gochan-send chan 1)
     (gochan-send chan 2))
 (thread-yield!)
 (test "1 channel fifo goroutine   first" 1 (gochan-recv chan))
 (test "1 channel fifo goroutine   first" 2 (gochan-recv chan)))

(test-group
 "timers"
 (define to1 (gochan-after 100))
 (define to2 (gochan-after 200))
 (define reply (gochan 0))

 (go (gochan-select ((to1 -> x) (gochan-send reply 'to1))
                    ((to2 -> x) (gochan-send reply 'to2))))
 (go (gochan-select ((to1 -> x) (gochan-send reply 'to1))
                    ((to2 -> x) (gochan-send reply 'to2))))

 (define start (current-milliseconds))
 (test "timeout order 1" 'to1 (gochan-recv reply))
 (test "timeout order 2" 'to2 (gochan-recv reply))
 (define duration (- (current-milliseconds) start))
 (test "200ms to timeout took <220ms " #t (begin (print* "(" duration ")")(< duration 220)))

 (test "to1 post-timeout closed" #t (gochan-select ((to1 -> x closed?) closed?)))
 (test "to2 post-timeout closed" #t (gochan-select ((to2 -> x closed?) closed?))))

(test-group
 "timers: each gochan-tick gets consumed by only one recv"

 (define reply (gochan 1024))
 (define tick  (gochan-tick 10 #|ms|#))
 (go (let loop () (gochan-select ((tick -> _) (gochan-select ((reply <- 1) (loop)))))))
 (go (let loop () (gochan-select ((tick -> _) (gochan-select ((reply <- 2) (loop)))))))
 (go (let loop () (gochan-select ((tick -> _) (gochan-select ((reply <- 3) (loop)))))))
 (go (let loop () (gochan-select ((tick -> _) (gochan-select ((reply <- 4) (loop)))))))

 (thread-sleep! .105) ;; just a little past the last tick
 (gochan-close reply) ;; allow goroutines to exit (this is an antipattern in golang, hopefully ok here!)

 ;; so, we've ticked every 100ms in 1 second. that should give us
 ;; exactly 10 results, from a random selection of threads above.
 (define results
   (let loop ((res '()))
     (gochan-select ((reply -> msg fail)
                     (if fail
                         (reverse res)
                         (loop (cons msg res)))))))

 (test "10ms messages for 105ms means 10 messages" 10 (length results))
 (print "hopefully different senders: " results))

(test-group
 "closing channels"

 (define chan1 (gochan 1))
 (gochan-send chan1 'test)
 (gochan-close chan1)
 ;;                                                         data fail meta
 (test "closed, non-empty buffered channel gives us data" '(test #f   #t) (receive (gochan-recv chan1)))
 (test "closed, empty     buffered channel fails"         '(#f   #t   #t) (receive (gochan-recv chan1)))

 (define chan (gochan 0))

 (go (gochan-recv chan)
     (gochan-recv chan))
 (thread-yield!)
 (test "sender fail-flag says no error 1" #f (gochan-select ((chan <- 'hello fail) fail)))
 (test "sender fail-flag says no error 2" #f (gochan-select ((chan <- 'hi    fail) fail)))

 (define r1 'untouched)
 (define r2 'untouched)
 (define r3 'untouched)
 (define r4 'untouched)

 (define r1-thread (go (gochan-select ((chan -> msg)        (set! r1 'touched)))))
 (define r2-thread (go (gochan-select ((chan -> msg fail)   (set! r2 fail)))))
 (define r3-thread (go (gochan-select ((chan <- 'TEST)      (set! r3 'touched)))))
 (define r4-thread (go (gochan-select ((chan <- 'TEST fail) (set! r4 fail)))))

 (gochan-close chan 'my-fail-flag)

 (thread-sleep! 0.1) ;; r1/r2 threads should exit quickly

 (test "blocked receiving thread was terminated" 'dead (thread-state r1-thread))

 (test "blocked receiving thread with implicit fail flag" 'untouched (values r1))
 (test "blocked receiving thread with explicit fail flag" 'my-fail-flag (values r2))
 (test "blocked sending   thread with implicit fail flag" 'untouched (values r3))
 (test "blocked sending   thread with explicit fail flag" 'my-fail-flag (values r4))

 (test "receiving from closed channel sync"
       '(#f my-fail-flag)
       (gochan-select ((chan -> msg fail) (list msg fail))))
 (test "sending to closed channel sync"
       'my-fail-flag
       (gochan-select ((chan <- 123 fail) fail)))

 (test "gochan-select ignored body of closed chan recv" (void)
       (gochan-select ((chan -> msg) (error "chan closed, this should never run!"))))
 (test "gochan-select ignores body of closed chan send"(void)
       (gochan-select ((chan <- 123) (error "chan closed, this should never run!"))))

 (define chan (gochan 0))
 (define go1 (go (receive (gochan-recv chan))))
 (define go2 (go (receive (gochan-recv chan))))
 (define go3 (go (receive (gochan-recv chan))))
 (thread-sleep! 0.1);; ensure goroutines are blocking on chan

 (test "thread waiting 1" 'sleeping (thread-state go1))
 (test "thread waiting 2" 'sleeping (thread-state go2))
 (test "thread waiting 3" 'sleeping (thread-state go3))

 (gochan-close chan)
 ;;                                   data fail meta
 (test "thread awakened by close 1" '(#f   #t   #t) (thread-join! go1))
 (test "thread awakened by close 2" '(#f   #t   #t) (thread-join! go2))
 (test "thread awakened by close 3" '(#f   #t   #t) (thread-join! go3)))

(test-group
 "buffered channels"

 (define chan (gochan 2))
 (define done #f)

 (define go1
   (go (gochan-send chan 1) (set! done 1)
       (gochan-send chan 2) (set! done 2)
       (gochan-send chan 3) (set! done 3)
       (gochan-close chan)
       'exited))

 (thread-yield!)
 (test "thread blocked" 'sleeping (thread-state go1))
 (test "thread filled buffer of two items" 2 done)
 (print "gochan is now " chan)
 (test "buffered data from chan item 1" 1 (gochan-recv chan))
 (test "thread awakened by previous receive (buffer available)"
       'exited (thread-join! go1))
 (test "thread " 3 done)
 (test "buffered leftovers from chan 2" 2 (gochan-recv chan))
 (test "buffered leftovers from chan 3" 3 (gochan-recv chan))
 (test "chan closed"     #f (gochan-recv chan)))

(test-group
 "gochan-select else clause"

 (test
  "else clause gets executed if nobody else ready"
  'my-else
  (gochan-select
   (((gochan 0) -> msg) (error "should never happen"))
   (else 'my-else)))

 (define chan (gochan 100))
 (list-tabulate 100 (lambda (i) (gochan-send chan i)))
 (test "else clause does not get executed if data ready"
       (make-list 100 'data)
       (list-tabulate 100
                      (lambda (i)
                        (gochan-select (( chan -> when) 'data)
                                       (else (error "should never happen!!"))))))

 (test "else clause does not get executed if timeout ready"
       (make-list 100 'data)
       (list-tabulate 100
                      (lambda (i)
                        (gochan-select (( (gochan-after 0) -> when) 'data)
                                       (else (error "should never happen!!"))))))

 )

(test-group
 "load-balancer"

 ;; create some chans with lots of data immediately available
 (define chan1 (gochan 100))
 (define chan2 (gochan 100))
 (list-tabulate 100 (lambda (x) (gochan-send chan1 x)))
 (list-tabulate 100 (lambda (x) (gochan-send chan2 x)))

 ;; receive from either
 (define origin
   (list-tabulate
    20 (lambda (x)
         (gochan-select
          ((chan1 -> msg) 1)
          ((chan2 -> msg) 2)))))

 ;; check that we got data from both contestants
 (define num-chan1 (count (lambda (x) (eq? x 1)) origin))
 (define num-chan2 (count (lambda (x) (eq? x 2)) origin))
 (print "message origins: " origin)
 (test "not just results from chan1" #t (< num-chan1 19))
 (test "not just results from chan2" #t (< num-chan2 19)))

(test-group
 "multiple gochan-close calls"

 (define c (gochan 0))
 (gochan-close c 1) (test "first gochan-close gets 1" 1 (gochan-select ((c -> m f) f)))
 (gochan-close c 2) (test "first gochan-close gets 2" 2 (gochan-select ((c -> m f) f)))
 (gochan-close c 3) (test "first gochan-close gets 3" 3 (gochan-select ((c -> m f) f)))
 (gochan-close c 4) (test "first gochan-close gets 4" 4 (gochan-select ((c -> m f) f))))

(include "signal-handler.scm")
(test-exit)
