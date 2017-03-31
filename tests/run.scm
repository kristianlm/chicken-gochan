(use gochan test srfi-1 srfi-13)

(test-group
 "simple gochan"
 (define c (gochan 1024))
 (gochan-send c 'one)
 (test "synchronous recv" 'one (gochan-receive c))
 (gochan-send c 'two)
 (gochan-send c 'three)
 (gochan-close c)
 (test "closed?" #t (gochan-closed? c))
 (test-error "send to closed gochan fails" (gochan-send c 'three))

 (test "closed channel keeps buffer" 'two        (gochan-receive c))
 (test "gochan-receive*"             'three      (gochan-receive* c #f))

 (test "recving from closed and empty gochan" #f (gochan-receive c) )

 (test "gochan-receive* #f when closed" #f (gochan-receive* c #f))
 (test "on-closed unlocks mutex"        #f (gochan-receive* c #f))

 )

(test-group
 "lockstep unbuffered channel"


 (test
  "synchronous from multiple threads"
  "sent 0\ngot 0\nsent 1\ngot 1\nsent 2\ngot 2\n"
  (with-output-to-string
    (lambda ()
      (define c (gochan 0))
      (go (gochan-send c 0) (print "sent 0")
          (gochan-send c 1) (print "sent 1")
          (gochan-send c 2) (print "sent 2"))

      (print "got " (gochan-receive c))
      (print "got " (gochan-receive c))
      (print "got " (gochan-receive c))))))


(test-group
 "multiple receivers - no blocking"

 (define channel (gochan 0))
 (define result  (gochan 0))
 (go (gochan-send result (gochan-receive channel)))
 (go (gochan-send result (gochan-receive channel)))

 (thread-yield!) ;; make both t1 and t2 wait on condvar

 (gochan-send channel "1") (test "1" (gochan-receive result))
 (gochan-send channel "2") (test "2" (gochan-receive result)))


(test-group
 "multiple channels"

 (define c1 (gochan 1024))
 (define c2 (gochan 1024))
 (gochan-send c1 'c1)
 (gochan-send c2 'c2)

 (test "nonempty first"  'c1 (gochan-receive (list c1 c2)))
 (test "nonempty second" 'c2 (gochan-receive (list c1 c2)))

 (gochan-send c2 'c2-again)
 (gochan-close c1)
 (gochan-close c2)

 (test "close first" #f (gochan-receive (list c1)))
 (test "close first" 'c2-again (gochan-receive (list c2)))
 (test "both closed" #f (gochan-receive (list c1 c2)))
 )

(test-group
 "empty multiple channels"
 (define c1 (gochan 0))
 (define c2 (gochan 0))
 (define (process) (gochan-fold (list c1 c2) (lambda (x s) (thread-yield!) (+ x s)) 0))
 (define workers (map thread-start! (make-list 4 process)))

 ;; a couple of challenges
 (thread-yield!) (for-each (cut gochan-send c1 <>) (iota 10 1000)) (print "FOR-EACH 1")
 (thread-yield!) (for-each (cut gochan-send c2 <>) (iota 10 100))  (print "FOR-EACH 1")
 (thread-yield!)

 (gochan-close c1)
 (gochan-close c2)

 (let ((worker-sums (map thread-join! workers)))
   (test "fair worker distribution" #t (every (cut < 1000 <>) worker-sums))
   (test "multiple empty channels with multiple workers"
         (+ 10000 9 8 7 6 5 4 3 2 1
            1000  9 8 7 6 5 4 3 2 1)
         (fold + 0 worker-sums)))
 )

(test-group
 "gochan-for-each"

 (define c (gochan 1024 initial: '("a" "b" "c")))
 (gochan-close c)

 (test "simple for-each"
       "abc"
       (with-output-to-string (lambda () (gochan-for-each c display)))))

(test-group
 "gochan-fold"
  (define c (gochan 1024))
  (for-each (cut gochan-send c <>) (iota 101))
  (gochan-close c)
  (test "gochan-fold sum" 5050 (gochan-fold c (lambda (msg state) (+ msg state)) 0)))

(test-group
 "gochan-select 1"
 (define c1 (gochan 1024))
 (gochan-send c1 1)
 (gochan-send c1 2)

 (define (next)
   (gochan-select
    (c1 msg (list "c1" msg))))

 (test "gochan-select 1" '("c1" 1) (next))
 (test "gochan-select 2" '("c1" 2) (next))
 (gochan-close c1)
 (test "gochan-select 3" '("c1" #f) (next)))

(test-group
 "timeouts"

 (test "immediate timeout" '(#f #f #f) (receive (gochan-receive* (gochan 0) 0)))
 ;; g(test "timeout error" (gochan-receive (gochan 0) 0))

 (define c (gochan 0))
 (define workers (map thread-start! (make-list 4 (lambda () (gochan-receive* c 0.1)))))

 ;;(test "simultaneous timeouts" '(#t #t #t #t) (map thread-join! workers))


 ;;(test 'timeout (gochan-select (c msg (error "from c1" msg)) (0.1 'timeout)))


 (define cclosed (gochan 0))
 (gochan-close cclosed)
 (test
  "closed channel still produces values"
  #f ;; from msg
  (gochan-select
   (cclosed msg msg)
   (0 'to)))
 )

(test-group
 "closing a channel will trigger all receivers"
 (define result  (gochan 3))
 (define closing (gochan 0))
 (thread-start! (lambda () (gochan-send result (receive (gochan-receive closing)))))
 (thread-start! (lambda () (gochan-send result (receive (gochan-receive closing)))))
 (thread-start! (lambda () (gochan-send result (receive (gochan-receive closing)))))

 (thread-sleep! 0.1)
 (gochan-close closing)
 (test '((#f #t) (#f #t) (#f #t)) (list-tabulate 3 (lambda (i) (gochan-receive result)))))

(warning "stress-testing, this may take a few seconds ...")
(test-group
 "stress test"
 (include "stress.scm")
 (test "no stress.scm assertions" #t #t))

(test-exit)
