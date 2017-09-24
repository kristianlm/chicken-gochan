;; Simple Scheme queue implementation. We need this for Schemes
;; without this built-in.
;;
;; This one copies the CHICKEN API just because that's what I started
;; with.

(define-record-type queue (%make-queue first last length)
  queue?
  (first %queue-first %queue-first-set!)
  (last  %queue-last  %queue-last-set!)
  (length queue-length %queue-length-set!))

(define (make-queue) (%make-queue '() '() 0))
(define (queue-empty? q) (eq? '() (%queue-first q)))

(define (queue-add! q datum)
  (let ((new-pair (cons datum '())))
    (cond ((queue-empty? q) (%queue-first-set! q new-pair))
	  (else (set-cdr! (%queue-last q) new-pair)))
    (%queue-last-set! q new-pair)
    (%queue-length-set! q (+ (queue-length q) 1))
    (values)))

(define (queue-remove! q)
  (let ((first-pair (%queue-first q)))
    (if (pair? first-pair)
	(let ((first-cdr (cdr first-pair)))
	  (%queue-first-set! q first-cdr)
	  (if (eq? '() first-cdr)
	      (%queue-last-set! q '()))
	  (%queue-length-set! q (- (queue-length q) 1))
	  (car first-pair))
	(error "queue-remove!: queue empty"))))

(define (queue->list q) (map (lambda (x) x) (%queue-first q)))
(define (list->queue lst)
  (let ((q (make-queue)))
    (let loop ((lst lst))
      (if (pair? lst)
	  (begin
	    (queue-add! q (car lst))
	    (loop (cdr lst)))
	  q))))


