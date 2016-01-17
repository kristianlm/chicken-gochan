;;; stress-test gochan. This is causing deadlocks after about 25000
;;; messages (consistantly). We need to figure out what's going wrong here!
(use gochan)

(define chan (gochan))

(thread-start!
 (lambda () ;; simple echo
   (gochan-for-each
    chan (lambda (msg)
           (gochan-send (car msg)
                        (cdr msg))))))

(let loop ((n 1000000))
  (if (> n 0)
      (let ((reply (gochan)))
        (gochan-send chan (cons reply n))
        (assert (eq? n (gochan-receive reply)))
        (loop (sub1 n)))))


