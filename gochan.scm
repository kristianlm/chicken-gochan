;; gochan.scm -- thread-safe channel (FIFO) library
;; Copyright (c) 2012 Alex Shinn.  All rights reserved.
;; Copyright (c) 2014 Kristian Lein-Mathisen.  All rights reserved.
;; BSD-style license: http://synthcode.com/license.txt
;;
;; Inspired by channels from goroutines.

(use srfi-18)

(define-record-type gochan
  (%gochan mutex semaphores front rear closed?)
  gochan?
  (mutex gochan-mutex gochan-mutex-set!)
  (semaphores gochan-semaphores gochan-semaphores-set!)
  (front gochan-front gochan-front-set!)
  (rear gochan-rear gochan-rear-set!)
  (closed? gochan-closed? gochan-closed-set!))

(define-record gochan-semaphore mutex cv)

(define (cv-close! cv) (condition-variable-specific-set! cv #t))
(define (cv-open! cv)  (condition-variable-specific-set! cv #f))
(define (cv-open? cv)  (eq? #f (condition-variable-specific cv)))

;; make a binary open/closed semaphore. default state is open.
;; actually a condition-variable which can be signalled. we need the
;; state a semaphore provides for guarantees of the sender-end
;; "awaking" the receiving end.
(define (make-semaphore name)
  (let ((cv (make-condition-variable name)))
    (cv-open! cv)
    (make-gochan-semaphore (make-mutex) cv)))

;; returns #t on successful signal, #f if semaphore was already
;; closed.
(define (semaphore-signal! semaphore)
  (mutex-lock! (gochan-semaphore-mutex semaphore))
  (let ((cv (gochan-semaphore-cv semaphore)))
   (cond ((cv-open? cv)
          (cv-close! cv)
          (condition-variable-signal! cv) ;; triggers receiver
          (mutex-unlock! (gochan-semaphore-mutex semaphore))
          #t)
         (else
          (mutex-unlock! (gochan-semaphore-mutex semaphore))
          #f)))) ;; already signalled

;; wait for semaphore to close. #f means timeout, #t otherwise.
(define (semaphore-wait! semaphore timeout)
  (mutex-lock! (gochan-semaphore-mutex semaphore))
  (let ((cv (gochan-semaphore-cv semaphore)))
   (cond ((cv-open? cv)
          (mutex-unlock! (gochan-semaphore-mutex semaphore)
                         cv timeout)) ;; <-- #f on timeout
         (else
          (mutex-unlock! (gochan-semaphore-mutex semaphore))
          #t)))) ;; already signalled

(define (gochan . items)
  (%gochan (make-mutex) ;; mutex
           '()          ;; condition variables
           items        ;; front
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

;; returns:
;; #f if channel closed
;; #t if registered with semaphore
;; (cons msg (cdr chan) if chan is pair (userdata)
;; (cons msg '()) if chain is gochan (no userdata)
;; userdata is useful for finding which channel a message came from.
(define (gochan-receive** chan% semaphore)
  (let ((chan (if (pair? chan%) (car chan%) chan%)))
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
         ;; return associated userdata if present:
        (cons (car front) (if (pair? chan%) (cdr chan%) '())))))))

;; accept channel or list of channels. returns:
;; (list msg channel) on success,
;; #f for all channels closed
;; #t for timeout
(define (gochan-receive* chans% timeout)
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
                   (loop (cdr chans) #f))
                  ;; channel was closed!
                  (else (loop (cdr chans) never-used?))))
          ;; we've run through all channels without a message.
          (cond (never-used? #f) ;; all channels were closed
                (else ;; we have registered our semaphore with all channels
                 (if (semaphore-wait! semaphore timeout)
                     (gochan-receive* chans% timeout)
                     #t))))))) ;;<-- timeout

(define (gochan-receive chan #!optional timeout)
  (let ((msg* (gochan-receive* chan timeout)))
    (cond ((eq? msg* #t) (error "timeout" chan))
          (msg* => car) ;; normal msgpair
          (else (error "channels closed" chan)))))

(define (gochan-close c)
  (mutex-lock! (gochan-mutex c))
  (gochan-closed-set! c #t)
  (for-each semaphore-signal! (gochan-semaphores c))
  (mutex-unlock! (gochan-mutex c)))

;; apply proc to each incoming msg as they appear on the channel,
;; return (void) when channel is emptied and closed.
(define (gochan-for-each c proc)
  (let loop ()
    (cond ((gochan-receive* c #f) =>
           (lambda (msg)
             (proc (car msg))
             (loop))))))

(define (gochan-fold chans proc initial)
  (let loop ((state initial))
    (cond ((gochan-receive* chans #f) =>
           (lambda (msg)
             (loop (proc (car msg) state))))
          (else state))))

(define (gochan-select* chan.proc-alist timeout timeout-proc)
  (let ((msgpair (gochan-receive* chan.proc-alist timeout)))
    (cond ((eq? #t msgpair) (timeout-proc)) ;; <-- timeout
          (msgpair
           (let ((msg (car msgpair))
                 (proc (cdr msgpair)))
             (proc msg)))
          (else (error "channels closed" chan.proc-alist)))))

;; (gochan-select
;;  (c1 msg body ...)
;;  (10 timeout-body ...)
;;  (c2 obj body ...))
;; becomes:
;; (gochan-select*
;;  (cons (cons       c1 (lambda (msg) body ...))
;;        (cons (cons c2 (lambda (obj) body ...)) '()))
;;  10 (lambda () timeout-body ...))

(define-syntax %gochan-select
  (syntax-rules ()
    ((_ (channel varname body ...) rest ...)
     (cons (cons channel (lambda (varname) body ...))
           (%gochan-select rest ...)))
    ((_) '())))

(define-syntax gochan-select
  (er-macro-transformer
   (lambda (x r t)
     (let loop ((forms (cdr x)) ;; original specs+timeout
                (timeout #f)
                (timeout-proc #f)
                (specs '())) ;; non-timeout specs
       (if (pair? forms)
           (let ((spec (car forms)))
             (if (number? (car spec))
                 (if timeout
                     (error "multiple timeouts specified" spec)
                     (loop (cdr forms)
                           (car spec)           ;; timeout in seconds
                           `(lambda () ,@(cdr spec)) ;; timeout body
                           specs))
                 (loop (cdr forms)
                       timeout timeout-proc
                       (cons spec specs))))

           `(,(r 'gochan-select*)
             (,(r '%gochan-select) ,@(reverse specs))
             ,timeout ,timeout-proc))))))


