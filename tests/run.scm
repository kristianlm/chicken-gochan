(use gochan test)
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
 ;;      msg   ok meta
 (test '(hello #t meta!) (receive (gochan-select* `((,chan meta!))))))

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
 (test "200ms to timeout took <220ms " #t (begin (print* "(" duration ")")(< duration 220))))

(test-group
 "closing channels"
 (define chan (gochan 0))

 (go (gochan-recv chan)
     (gochan-recv chan))
 (thread-yield!)
 (test "sender `ok` flag success 1" #t (gochan-select ((chan <- 'hello ok) ok)))
 (test "sender `ok` flag success 2" #t (gochan-select ((chan <- 'hi    ok) ok)))


 (gochan-close chan)
 (test "receiving from closed channel sync"
       '(#f #f)
       (gochan-select ((chan -> msg ok) (list msg ok))))
 (test "sending to closed channel sync"
       '#f
       (gochan-select ((chan <- 123 ok) ok)))

 (define chan (gochan 0))
 (define go1 (go (receive (gochan-recv chan))))
 (define go2 (go (receive (gochan-recv chan))))
 (define go3 (go (receive (gochan-recv chan))))
 (thread-yield!);; ensure goroutines are blocking on chan

 (test "thread waiting 1" 'sleeping (thread-state go1))
 (test "thread waiting 2" 'sleeping (thread-state go2))
 (test "thread waiting 3" 'sleeping (thread-state go3))

 (gochan-close chan)
 ;;                                   data ok  meta
 (test "thread awakened by close 1" '(#f   #f  #t) (thread-join! go1))
 (test "thread awakened by close 2" '(#f   #f  #t) (thread-join! go2))
 (test "thread awakened by close 3" '(#f   #f  #t) (thread-join! go3)))

(test-exit)
