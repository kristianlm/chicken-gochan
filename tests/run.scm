(use gochan test)
;;(define-syntax test (syntax-rules () ((_ body ...) (begin body ...))))

;; todo:
;; - unbuffered synchronous
;; - unbuffered multiple receivers
;; - unbuffered multiple senders
;; - unbuffered send&recv on channel

(test-group
 "unbuffered 1 channel fifo, primordial first"

 (define chan (gochan 0))
 (go (thread-sleep! 0.01)
     (gochan-send chan 1)
     (gochan-send chan 2)
     (test -1 (gochan-recv chan))
     (test -2 (gochan-recv chan))
     (gochan-send chan 3)
     (test -3 (gochan-recv chan)))
 ;;      msg ok  meta
 (test 1 (gochan-recv chan))
 (test 2 (gochan-recv chan))
 (gochan-send chan -1)
 (gochan-send chan -2)
 (test 3 (gochan-recv chan))
 (gochan-send chan -3))


