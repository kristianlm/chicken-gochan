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
 (test "gochan-receive*"             'three (car (gochan-receive* c)))

 (test-error "errors on recving from closed and empty gochan" (gochan-receive c) )

 (test "gochan-receive* #f when closed" #f (gochan-receive* c))
 (test "on-closed unlocks mutex"        #f (gochan-receive* c))

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
 "gochan-for-each"

 (define c (make-gochan))
 (define (process)
   (with-output-to-string
     (lambda () (gochan-for-each c
                            (lambda (x)
                              (display x)
                              (thread-sleep! 1))))))
 (define workers (map thread-start! (make-list 4 process)))
 (gochan-send c "a")
 (gochan-send c "b")
 (gochan-send c "c")
 (gochan-close c)

 (test "for-each multiple workers"
       3
       (string-length (apply conc (map thread-join! workers)))))

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
 (test "both closed" #f (gochan-receive* (list c1 c2)))
 )

(test-group
 "empty multiple channels"
 (define c1 (make-gochan))
 (define c2 (make-gochan))
 (define (process)
   (with-output-to-string (lambda () (gochan-for-each (list c1 c2) (lambda (x) (display x) (thread-sleep! 0.1))))))
 (define workers (map thread-start! (make-list 4 process)))

 ;; a couple of challenges
 (thread-yield!) (for-each (cut gochan-send c1 <>) (map (cut conc " c1" <>) (iota 5)))
 (thread-yield!) (for-each (cut gochan-send c2 <>) (map (cut conc " c2" <>) (iota 5)))
 (thread-yield!)

 (gochan-send c2 " last")
 (gochan-close c1)
 (gochan-close c2)

 (test "multiple empty channels with multiple workers"
       '("c10" "c11" "c12" "c13" "c14"
         "c20" "c21" "c22" "c23" "c24"
         "last")
       (sort (string-split (apply conc (map thread-join! workers)) " ") string<=))
 )

(test-group
 "gochan-fold"
  (define c (make-gochan))
  (for-each (cut gochan-send c <>) (iota 101))
  (gochan-close c)
  (test "gochan-fold sum" 5050 (gochan-fold c (lambda (msg state) (+ msg state)) 0)))
