
(include "canal.scm")

(use test)
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
