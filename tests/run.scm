
(include "canal.scm")

(use test)
(test-group
 "simple canal"
 (define c (make-canal))
 (canal-send c 'one)
 (test "synchronous recv" 'one (canal-receive c))
 (canal-send c 'two)
 (canal-close c)
 (test "closed?" #t (canal-closed? c))
 (test-error "send to closed canal fails" (canal-send c 'three))

 (test "buffered closed canal" 'two (canal-receive c) )
 (test-error "errors on recving from closed and empty canal" (canal-receive c) )
 (test-error "still error (no deadlock)" (canal-receive c) )

 (test "on-closed called" 'nevermind (canal-receive c (lambda (c) 'nevermind)))
 (test "on-closed unlocks mutex" 'nevermind (canal-receive c (lambda (c) 'nevermind)))

 )
