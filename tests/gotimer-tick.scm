(use gochan)

(define c (gochan-tick 1000))

(define t1
  (go (gochan-select ((c -> msg) (print "go1 c says " msg)))
      (gochan-select ((c -> msg) (print "go1 c says " msg)))
      (gochan-select ((c -> msg) (print "go1 c says " msg)))))

(define t2
  (go (gochan-select ((c -> msg) (print "go2 c says " msg)))
      (gochan-select ((c -> msg) (print "go2 c says " msg)))
      (gochan-select ((c -> msg) (print "go2 c says " msg)))))

(define t3
  (go (gochan-select ((c -> msg) (print "go3 c says " msg)))
      (gochan-select ((c -> msg) (print "go3 c says " msg)))
      (gochan-select ((c -> msg) (print "go3 c says " msg)))))

(for-each thread-join! (list t1 t2 t3))
