;;; simple gochan stress-test
(use gochan)

(define chan (gochan 1024))

(go
 (let loop ()
   (gochan-select
    ((chan -> msg)
     (gochan-send (car msg) (cdr msg)) ;; simple echo
     (loop)))))

(define start (current-milliseconds))

(let loop ((n 100000))
  (if (> n 0)
      (let ((reply (gochan 1024)))
        (gochan-send chan (cons reply n))
        (assert (eq? n (gochan-recv reply)))
        (loop (sub1 n)))))

(define elapsed (/ (- (current-milliseconds) start) 1000))
(print "done at " (floor (/ 100000 elapsed)) " msg/s")
