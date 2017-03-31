(use gochan)


(define c (gochan-tick 1000))
(define d (gochan 0))

(go (print "go1" (gochan-receive c)) (gochan-send d #t))
(go (print "go2" (gochan-receive c)) (gochan-send d #t))
(go (print "go3" (gochan-receive c)) (gochan-send d #t))

(print "done: " (gochan-receive d))
(print "done: " (gochan-receive d))
(print "done: " (gochan-receive d))
