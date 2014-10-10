;; canal.scm -- thread-safe channel (FIFO) library
;; Copyright (c) 2012 Alex Shinn.  All rights reserved.
;; BSD-style license: http://synthcode.com/license.txt

(define-record-type canal
  (%make-canal mutex condvar front rear)
  canal?
  (mutex canal-mutex canal-mutex-set!)
  (condvar canal-condvar canal-condvar-set!)
  (front canal-front canal-front-set!)
  (rear canal-rear canal-rear-set!))

(define (make-canal)
  (%make-canal (make-mutex) (make-condition-variable) '() '()))

(define (canal-empty? chan)
  (null? (canal-front chan)))

(define (canal-send! chan obj)
  (mutex-lock! (canal-mutex chan))
  (let ((new (list obj))
        (rear (canal-rear chan)))
    (canal-rear-set! chan new)
    (cond
     ((pair? rear)
      (set-cdr! rear new))
     (else  ; sending to empty canal
      (canal-front-set! chan new)
      (condition-variable-signal! (canal-condvar chan)))))
  (mutex-unlock! (canal-mutex chan)))

(define (canal-receive! chan)
  (mutex-lock! (canal-mutex chan))
  (let ((front (canal-front chan)))
    (cond
     ((null? front)  ; receiving from empty canal
      (mutex-unlock! (canal-mutex chan) (canal-condvar chan))
      (canal-receive! chan))
     (else
      (canal-front-set! chan (cdr front))
      (if (null? (cdr front))
          (canal-rear-set! chan '()))
      (mutex-unlock! (canal-mutex chan))
      (car front)))))
