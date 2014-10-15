;; gochan.scm -- thread-safe channel (FIFO) library
;; Copyright (c) 2012 Alex Shinn.  All rights reserved.
;; Copyright (c) 2014 Kristian Lein-Mathisen.  All rights reserved.
;; BSD-style license: http://synthcode.com/license.txt
;;
;; Inspired by channels from goroutines.

(use srfi-18)

(define-record-type gochan
  (%make-gochan mutex condvar front rear closed?)
  gochan?
  (mutex gochan-mutex gochan-mutex-set!)
  (condvar gochan-condvars gochan-condvars-set!)
  (front gochan-front gochan-front-set!)
  (rear gochan-rear gochan-rear-set!)
  (closed? gochan-closed? gochan-closed-set!))


(define (semaphore-close! cv) (condition-variable-specific-set! cv #t))
(define (semaphore-open! cv)  (condition-variable-specific-set! cv #f))
(define (semaphore-open? cv)  (eq? #f (condition-variable-specific cv)))

;; make a binary open/closed semaphore. default state is closed. unsed
;; interchangible with condvar.
(define (make-semaphore name)
  (let ((cv (make-condition-variable name)))
    (semaphore-close! cv)
    cv))

;; returns #t on successful signal, #f if semaphore was already
;; closed.
(define (semaphore-signal! condvar)
  (cond ((semaphore-open? condvar)
         (semaphore-close! condvar)
         (condition-variable-signal! condvar) ;; triggers receiver
         #t)
        (else #f))) ;; already signalled

(define (semaphore-wait! mutex condvar)
  (cond ((condition-variable-specific condvar) #f)
        (else (mutex-unlock! mutex condvar))))

(define (make-gochan)
  (%make-gochan (make-mutex) ;; mutex
                '()          ;; condition variables
                '()          ;; front
                '()          ;; rear
                #f))         ;; not closed

(define (gochan-empty? chan)
  (null? (gochan-front chan)))

(define (gochan-send chan obj)
  (mutex-lock! (gochan-mutex chan))
  (when (gochan-closed? chan)
    (begin (mutex-unlock! (gochan-mutex chan))
           (error "gochan closed" chan)))
  (let ((new (list obj))
        (rear (gochan-rear chan)))
    (gochan-rear-set! chan new)
    (cond
     ((pair? rear)
      (set-cdr! rear new))
     (else ;; sending to empty gochan
      (gochan-front-set! chan new)))

    ;; signal anyone who has registered
    (let loop ((condvars (gochan-condvars chan)))
      (cond ((pair? condvars)
             (if (semaphore-signal! (car condvars))
                 ;; signalled! remove from signal list
                 (gochan-condvars-set! chan (cdr condvars))
                 ;; not signalled, ignore and remove (someone else
                 ;; signalled)
                 (loop (cdr condvars))))))) ;; next in line

  (mutex-unlock! (gochan-mutex chan)))

;; wrap msg in a list. return #f if channel is closed.
(define (gochan-receive* chan)
  (mutex-lock! (gochan-mutex chan))
  (let ((front (gochan-front chan)))
    (cond
     ((null? front) ;; receiving from empty gochan
      (cond ((gochan-closed? chan)
             (mutex-unlock! (gochan-mutex chan))
             #f) ;; #f for fail
            (else
             (let ((condvar (make-semaphore (current-thread))))
               ;; register condvar
               (gochan-condvars-set! chan (cons condvar (gochan-condvars chan)))
               (semaphore-wait! (gochan-mutex chan) condvar)

               (gochan-receive* chan)))))
     (else
      (gochan-front-set! chan (cdr front))
      (if (null? (cdr front))
          (gochan-rear-set! chan '()))
      (mutex-unlock! (gochan-mutex chan))
      (list (car front)))))) ;; (list <msg>)

(define (gochan-receive chan)
  (cond ((gochan-receive* chan) => car)
        (else (error "channel is closed" chan))))

(define (gochan-close c)
  (mutex-lock! (gochan-mutex c))
  (gochan-closed-set! c #t)
  (for-each condition-variable-signal! (gochan-condvars c))
  (mutex-unlock! (gochan-mutex c)))

;; apply proc to each incoming msg as they appear on the channel,
;; return (void) when channel is emptied and closed.
(define (gochan-for-each c proc)
  (let loop ()
    (cond ((gochan-receive* c) =>
           (lambda (msg)
             (proc (car msg))
             (loop))))))
