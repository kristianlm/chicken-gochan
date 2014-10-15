(use gochan test)

(test-group
 "simple gochan"
 (define c (make-gochan))
 (gochan-send c 'one)
 (test "synchronous recv" 'one (gochan-receive c))
 (gochan-send c 'two)
 (gochan-close c)
 (test "closed?" #t (gochan-closed? c))
 (test-error "send to closed gochan fails" (gochan-send c 'three))

 (test "buffered closed gochan" 'two (gochan-receive c) )
 (test-error "errors on recving from closed and empty gochan" (gochan-receive c) )
 (test-error "still error (no deadlock)" (gochan-receive c) )

 (test "on-closed called" 'nevermind (gochan-receive c (lambda (c) 'nevermind)))
 (test "on-closed unlocks mutex" 'nevermind (gochan-receive c (lambda (c) 'nevermind)))

 )


(test-group
 "multiple receivers - no blocking"

 (define channel (make-gochan))
 (define result (make-gochan))
 (define (process) (gochan-send result (gochan-receive channel)))
 (define t1 (thread-start! (make-thread (lambda () (process)))))
 (define t2 (thread-start! (make-thread (lambda () (process)))))

 (thread-yield!) ;; make both t1 and t2 wait on condvar

 (begin
   (gochan-send channel "1")
   (gochan-send channel "2"))

 (test "1" (gochan-receive result))
 (test "2" (gochan-receive result)))


(test-group
 "gochan-for-each"

 (define ch (make-gochan))
 (define t (thread-start! (lambda () (with-output-to-string (lambda () (gochan-for-each ch display))))))
 (gochan-send ch "a")
 (gochan-send ch "b")
 (gochan-close ch)
 (test "ab" (thread-join! t)))
