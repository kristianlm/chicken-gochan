

(define (current-milliseconds)
  (let ((tv (car (get-time-of-day))))
    (+ (quotient (timeval-microseconds tv) 1000)
       (* 1000 (timeval-seconds tv)))))

(define fixnum? exact?)

(define random random-integer) ;; from srfi-27

(define-syntax assert
  (syntax-rules ()
    ((assert expr)
     (if (not expr)
         (error "assertion failed" 'expr)))))
