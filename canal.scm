;; canal.scm -- thread-safe channel (FIFO) library
;; Copyright (c) 2012 Alex Shinn.  All rights reserved.
;; Copyright (c) 2014 Kristian Lein-Mathisen.  All rights reserved.
;; BSD-style license: http://synthcode.com/license.txt
;;
;; Inspired by channels from goroutines.

(use srfi-18)

(define-record-type canal
  (%make-canal mutex condvar front rear closed?)
  canal?
  (mutex canal-mutex canal-mutex-set!)
  (condvar canal-condvar canal-condvar-set!)
  (front canal-front canal-front-set!)
  (rear canal-rear canal-rear-set!)
  (closed? canal-closed? canal-closed-set!))

(define (make-canal)
  (%make-canal (make-mutex) (make-condition-variable) '() '() #f))

(define (canal-empty? chan)
  (null? (canal-front chan)))

(define (canal-send chan obj)
  (mutex-lock! (canal-mutex chan))
  (when (canal-closed? chan)
    (begin (mutex-unlock! (canal-mutex chan))
           (error "cannot send to closed canal" chan)))
  (let ((new (list obj))
        (rear (canal-rear chan)))
    (canal-rear-set! chan new)
    (cond
     ((pair? rear)
      (set-cdr! rear new))
     (else ;; sending to empty canal
      (canal-front-set! chan new)
      (condition-variable-signal! (canal-condvar chan)))))
  (mutex-unlock! (canal-mutex chan)))

(define (canal-receive chan)
  (mutex-lock! (canal-mutex chan))
  (let ((front (canal-front chan)))
    (cond
     ((null? front) ;; receiving from empty canal
      (when (canal-closed? chan) (error "cannel is closed" chan))
      (mutex-unlock! (canal-mutex chan) (canal-condvar chan))
      (canal-receive chan))
     (else
      (canal-front-set! chan (cdr front))
      (if (null? (cdr front))
          (canal-rear-set! chan '()))
      (mutex-unlock! (canal-mutex chan))
      (car front)))))

(define (canal-close c)
  (mutex-lock! (canal-mutex c))
  (canal-closed-set! c #t)
  (mutex-unlock! (canal-mutex c)))
