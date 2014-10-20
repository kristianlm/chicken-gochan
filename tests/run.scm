(use gochan test srfi-1 srfi-13)

(test-group
 "simple gochan"
 (define c (make-gochan))
 (gochan-send c 'one)
 (test "synchronous recv" 'one (gochan-receive c))
 (gochan-send c 'two)
 (gochan-send c 'three)
 (gochan-close c)
 (test "closed?" #t (gochan-closed? c))
 (test-error "send to closed gochan fails" (gochan-send c 'three))

 (test "closed channel keeps buffer" 'two        (gochan-receive c))
 (test "gochan-receive*"             'three (car (gochan-receive* c #f)))

 (test-error "errors on recving from closed and empty gochan" (gochan-receive c) )

 (test "gochan-receive* #f when closed" #f (gochan-receive* c #f))
 (test "on-closed unlocks mutex"        #f (gochan-receive* c #f))

 )

(test-group
 "multiple receivers - no blocking"

 (define channel (make-gochan))
 (define result (make-gochan))
 (define (process) (gochan-send result (gochan-receive channel)))
 (define t1 (thread-start! (make-thread process "tst1")))
 (define t2 (thread-start! (make-thread process "tst2")))

 (thread-yield!) ;; make both t1 and t2 wait on condvar

 (begin
   (gochan-send channel "1")
   (gochan-send channel "2"))

 (test "1" (gochan-receive result))
 (test "2" (gochan-receive result)))


(test-group
 "multiple channels"

 (define c1 (make-gochan))
 (define c2 (make-gochan))
 (gochan-send c1 'c1)
 (gochan-send c2 'c2)

 (test "nonempty first"  'c1 (gochan-receive (list c1 c2)))
 (test "nonempty second" 'c2 (gochan-receive (list c1 c2)))

 (gochan-send c2 'c2-again)
 (gochan-close c1)
 (gochan-close c2)

 (test "close first" 'c2-again (gochan-receive (list c1 c2)))
 (test "both closed" #f (gochan-receive* (list c1 c2) #f))
 )

(test-group
 "empty multiple channels"
 (define c1 (make-gochan))
 (define c2 (make-gochan))
 (define (process) (gochan-fold (list c1 c2) (lambda (x s) (thread-yield!) (+ x s)) 0))
 (define workers (map thread-start! (make-list 4 process)))

 ;; a couple of challenges
 (thread-yield!) (for-each (cut gochan-send c1 <>) (iota 10 1000))
 (thread-yield!) (for-each (cut gochan-send c2 <>) (iota 10 100))
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

 (define c (make-gochan))
 (gochan-send c "a")
 (gochan-send c "b")
 (gochan-send c "c")
 (gochan-close c)

 (test "simple for-each"
       "abc"
       (with-output-to-string (lambda () (gochan-for-each c display)))))

(test-group
 "gochan-fold"
  (define c (make-gochan))
  (for-each (cut gochan-send c <>) (iota 101))
  (gochan-close c)
  (test "gochan-fold sum" 5050 (gochan-fold c (lambda (msg state) (+ msg state)) 0)))

(test-group
 "gochan-select"
 (define c1 (make-gochan))
 (define c2 (make-gochan))
 (gochan-send c2 2)
 (gochan-send c1 1)
 (gochan-send c1 1)
 (gochan-close c1)
 (gochan-close c2)
 (define (next)
   (gochan-select
    (c1 msg (list "c1" msg))
    (c2 obj (list "c2" obj))))

 (test "gochan-select 1" '("c1" 1) (next))
 (test "gochan-select 2" '("c1" 1) (next))
 (test "gochan-select 3" '("c2" 2) (next))
 )

(test-group
 "timeouts"

 (test "immediate timeout" #t (gochan-receive* (make-gochan) 0))
 (test-error "timeout error" (gochan-receive (make-gochan) 0))

 (define c (make-gochan))
 (define workers (map thread-start! (make-list 4 (lambda () (gochan-receive* c 0.1)))))

 (test "simultaneous timeouts"
       '(#t #t #t #t)
       (map thread-join! workers))


 (test 'timeout
       (gochan-select
        (c msg (error "from c1" msg))
        (0.1 'timeout)))


 (define cclosed (make-gochan))
 (gochan-close cclosed)
 (test-error
  "no timeout, closed channel still produces error"
  (gochan-select
   (cclosed msg 'msg)
   (0 'to)))
 )

(test-exit)
