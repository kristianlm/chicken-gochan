;; gochan.scm -- thread-safe channel (FIFO) library
;; Copyright (c) 2012 Alex Shinn.  All rights reserved.
;; Copyright (c) 2014 Kristian Lein-Mathisen.  All rights reserved.
;; BSD-style license: http://synthcode.com/license.txt
;;
;; Inspired by channels from goroutines.

(use srfi-18
     (only data-structures list->queue queue-add! queue-empty? queue-remove! queue-length))

(define-record-type gochan
  (%gochan mutex semaphores buffer closed?)
  gochan?
  (mutex gochan-mutex gochan-mutex-set!)
  (semaphores gochan-semaphores)
  (buffer gochan-buffer)
  (closed? gochan-closed? gochan-closed-set!))

(define-record gochan-semaphore mutex cv)
(define-record-printer gochan
  (lambda (x p)
    (display "#<gochan " p)
    (display (queue-length (gochan-buffer x))  p)
    (display "/" p)
    (display (queue-length (gochan-semaphores x))  p)
    (display ">" p)))

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
  (%gochan (make-mutex)        ;; mutex
           (list->queue '())   ;; condition variables
           (list->queue items) ;; buffer
           #f))                ;; not closed

;; try to send a signal to anyone who has registered with
;; chan. returns #t if someone was signalled (and thus awakened),
;; return #f otherwise. this must be called in a locked gochan mutex
;; context.
(define (%gochan-signal c)
  (let ((semaphores (gochan-semaphores c)))
    (let loop ()
      (if (queue-empty? semaphores)
          #f
          (if (semaphore-signal! (queue-remove! semaphores))
              ;; signaled, great success!
              #t
              ;; not signalled, so somebody else signalled the
              ;; semaphore. keep trying.
              (loop))))))

(define (gochan-send chan obj)
  (mutex-lock! (gochan-mutex chan))
  (when (gochan-closed? chan)
    (begin (mutex-unlock! (gochan-mutex chan))
           (error "gochan closed" chan)))

  (queue-add! (gochan-buffer chan) obj)

  (%gochan-signal chan)

  ;; TODO: handle no semaphores and unbuffered channel

  (mutex-unlock! (gochan-mutex chan))
  (void))

;; returns:
;; #f if channel closed
;; #t if registered with semaphore
;; (cons msg (cdr chan) if chan is pair (userdata)
;; (cons msg '()) if chain is gochan (no userdata)
;; userdata is useful for finding which channel a message came from.
(define (gochan-receive** chan% semaphore)
  (let ((chan (if (pair? chan%) (car chan%) chan%)))
    (mutex-lock! (gochan-mutex chan))
    (let ((buffer (gochan-buffer chan)))
      (cond
       ((queue-empty? buffer) ;; receiving from empty gochan
        (cond ((gochan-closed? chan)
               (mutex-unlock! (gochan-mutex chan))
               #f) ;; #f for fail
              (else
               ;; register semaphore with channel
               (queue-add! (gochan-semaphores chan) semaphore)
               (mutex-unlock! (gochan-mutex chan))
               #t)))
       (else
        (let ((datum (queue-remove! buffer)))
          (mutex-unlock! (gochan-mutex chan))
          ;; return associated userdata if present:
          (cons datum (if (pair? chan%) (cdr chan%) '()))))))))

;; run through the channels' semaphores (queue) and remove any
;; instances of semaphore.
(define (gochan-unregister! achan semaphore)
  (let ((chan (if (pair? achan) (car achan) achan)))
    (mutex-lock! (gochan-mutex chan))
    (let ((q (gochan-semaphores chan)))
      (let loop ((n (queue-length q)))
        (when (> n 0)
          (let ((x (queue-remove! q)))
            (unless (eq? semaphore x)
                (queue-add! q x)))
          (loop (sub1 n)))))
    (mutex-unlock! (gochan-mutex chan))))

;; accept channel or list of channels. returns:
;; (list msg channel) on success,
;; #f for all channels closed
;; #t for timeout
(define (gochan-receive* chans% timeout)
  (let ((chans (if (pair? chans%) chans% (list chans%)))
        (semaphore (make-semaphore (current-thread))))

    (let loop ((chans chans)
               (registered '())) ;; list of gochans that contain our semaphore
      (if (pair? chans)
          (let* ((chan (car chans))
                 (msgchan (gochan-receive** chan semaphore)))
            (cond ((pair? msgchan) msgchan)
                  ;; channel registered with semaphore
                  ((eq? #t msgchan)
                   (loop (cdr chans) (cons chan registered)))
                  ;; channel was closed!
                  (else (loop (cdr chans) registered))))
          ;; we've run through all channels without a message.
          (cond ((null? registered) #f) ;; all channels were closed
                (else ;; we have registered our semaphore with all channels
                 (let ((wait-result (semaphore-wait! semaphore timeout)))
                   ;; remove semaphore from all channels. gochan-send
                   ;; removes semaphore too, but we need to avoid
                   ;; leaks in case nobody sends.
                   (for-each (lambda (chan) (gochan-unregister! chan semaphore)) registered)

                   (if wait-result
                       (gochan-receive* chans% timeout) ;; wait successful
                       #t)))))))) ;;<-- timeout

(define (gochan-receive chan #!optional timeout)
  (let ((msg* (gochan-receive* chan timeout)))
    (cond ((eq? msg* #t) (error "timeout" chan))
          (msg* => car) ;; normal msgpair
          (else (error "channels closed" chan)))))

;; closing a closed channel yields in error (like in go)
(define (gochan-close c)
  (mutex-lock! (gochan-mutex c))
  (when (gochan-closed? c)
    (mutex-unlock! (gochan-mutex c))
    (error "gochan closed" c))

  (gochan-closed-set! c #t)
  (let loop () (if (%gochan-signal c) (loop)))
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


