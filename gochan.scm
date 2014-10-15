;; gochan.scm -- thread-safe channel (FIFO) library
;; Copyright (c) 2012 Alex Shinn.  All rights reserved.
;; Copyright (c) 2014 Kristian Lein-Mathisen.  All rights reserved.
;; BSD-style license: http://synthcode.com/license.txt
;;
;; Inspired by channels from goroutines.

(use srfi-18)

(define-record-type gochan
  (%make-gochan mutex semaphores front rear closed?)
  gochan?
  (mutex gochan-mutex gochan-mutex-set!)
  (semaphores gochan-semaphores gochan-semaphores-set!)
  (front gochan-front gochan-front-set!)
  (rear gochan-rear gochan-rear-set!)
  (closed? gochan-closed? gochan-closed-set!))


(define (semaphore-close! cv) (condition-variable-specific-set! cv #t))
(define (semaphore-open! cv)  (condition-variable-specific-set! cv #f))
(define (semaphore-open? cv)  (eq? #f (condition-variable-specific cv)))

;; make a binary open/closed semaphore. default state is closed.
;; actually a condition-variable which can be signalled. we need the
;; state a semaphore provides for guarantees of the sender-end
;; "awaking" the receiving end.
(define (make-semaphore name)
  (let ((cv (make-condition-variable name)))
    (semaphore-close! cv)
    cv))

;; returns #t on successful signal, #f if semaphore was already
;; closed.
(define (semaphore-signal! semaphore)
  (cond ((semaphore-open? semaphore)
         (semaphore-close! semaphore)
         (condition-variable-signal! semaphore) ;; triggers receiver
         #t)
        (else #f))) ;; already signalled

;; wait for semaphore to close.
(define (semaphore-wait! semaphore)
  (cond ((semaphore-open? semaphore)
         (mutex-unlock! (make-mutex) semaphore))
        (else #f))) ;; already signalled

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
    (let loop ((semaphores (gochan-semaphores chan)))
      (cond ((pair? semaphores)
             (if (semaphore-signal! (car semaphores))
                 ;; signalled! remove from semaphore list
                 (gochan-semaphores-set! chan (cdr semaphores))
                 ;; not signalled, ignore and remove (someone else
                 ;; signalled)
                 (loop (cdr semaphores))))))) ;; next in line

  (mutex-unlock! (gochan-mutex chan)))

;; return either (cons msg chan), #f (channel closed), or #t
;; (registered with semaphore).
(define (gochan-receive** chan semaphore)
  (mutex-lock! (gochan-mutex chan))
  (let ((front (gochan-front chan)))
    (cond
     ((null? front) ;; receiving from empty gochan
      (cond ((gochan-closed? chan)
             (mutex-unlock! (gochan-mutex chan))
             #f) ;; #f for fail
            (else
             ;; register semaphore with channel
             (gochan-semaphores-set! chan (cons semaphore (gochan-semaphores chan)))
             (mutex-unlock! (gochan-mutex chan))
             #t)))
     (else
      (gochan-front-set! chan (cdr front))
      (if (null? (cdr front))
          (gochan-rear-set! chan '()))
      (mutex-unlock! (gochan-mutex chan))
      (cons (car front) chan))))) ;; (cons msg chan)

;; accept channel or list of channels. returns (list msg channel) or
;; #f for all channels closed.
(define (gochan-receive* chans%)
  (let ((chans (if (pair? chans%) chans% (list chans%)))
        (semaphore (make-semaphore (current-thread))))

    (let loop ((chans chans)
               (never-used? #t)) ;; anybody registered our semaphore?
      (if (pair? chans)
          (let* ((chan (car chans))
                 (msgchan (gochan-receive** chan semaphore)))
            (cond ((pair? msgchan) msgchan)
                  ;; channel registered with semaphore
                  ((eq? #t msgchan)
                   ;; open semaphore only once (might close async)
                   (if never-used? (semaphore-open! semaphore))
                   (loop (cdr chans) #f))
                  ;; channel was closed!
                  (else (loop (cdr chans) never-used?))))
          ;; we've run through all channels without a message.
          (cond (never-used? #f) ;; all channels were closed
                (else ;; we have registered our semaphore with all channels
                 (semaphore-wait! semaphore)
                 (gochan-receive* chans%)))))))

(define (gochan-receive chan)
  (cond ((gochan-receive* chan) => car)
        (else (error "channel is closed" chan))))

(define (gochan-close c)
  (mutex-lock! (gochan-mutex c))
  (gochan-closed-set! c #t)
  (for-each condition-variable-signal! (gochan-semaphores c))
  (mutex-unlock! (gochan-mutex c)))

;; apply proc to each incoming msg as they appear on the channel,
;; return (void) when channel is emptied and closed.
(define (gochan-for-each c proc)
  (let loop ()
    (cond ((gochan-receive* c) =>
           (lambda (msg)
             (proc (car msg))
             (loop))))))
