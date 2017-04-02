;; gochan.scm -- thread-safe channel (FIFO) library based on the go
;; programming language's channel API.
;;
;; Copyright (c) 2017 Kristian Lein-Mathisen.  All rights reserved.
;; License: BSD
(use srfi-18
     (only matchable match)
     (only data-structures list->queue queue->list
           queue-add! queue-empty? queue-remove! queue-first queue-length))

;; todo:
;;
;; - closing a channel
;; - buffers
;; - timeouts

(define (info . args) (void))
(define (info . args) (apply print (cons (current-thread) (cons " " args))))

;; multiple receives
;; multiple sends
;; multiple receive/send simultaniously
;; buffering
;; timeouts (as channels)

;; for me, it helps to think about semaphore as return-values that can
;; block. each gochan-select will create a semaphore and wait for
;; somebody to signal it (sometimes immediately (without waiting),
;; sometimes externally (having to wait)).
(define-record-type gosem
  (make-gosem mutex cv data meta ok)
  gosem?
  (mutex gosem-mutex)
  (cv    gosem-cv)
  (data  gosem-data gosem-data-set!)
  (meta  gosem-meta gosem-meta-set!)
  (ok    gosem-ok   gosem-ok-set!))

(define (make-semaphore)
  (make-gosem (make-mutex)
              (make-condition-variable)
              #f
              #f
              #t))

(define (%gosem-open? sem) (eq? #f (gosem-meta sem)))

;; returns #t on successful signal, #f if semaphore was already
;; signalled.
(define (semaphore-signal! sem data meta ok)
  (info "signalling " sem " from " meta " with data " data (if ok "" " (closed)"))
  (mutex-lock! (gosem-mutex sem))
  (cond ((%gosem-open? sem) ;; available!
         (gosem-data-set! sem data)
         (gosem-meta-set! sem meta)
         (gosem-ok-set! sem ok)
         (condition-variable-signal! (gosem-cv sem))
         (mutex-unlock! (gosem-mutex sem))
         #t)
        (else ;; already signalled
         (mutex-unlock! (gosem-mutex sem))
         #f)))

(define-record-type gochan
  (make-gochan mutex receivers senders)
  gochan?
  (mutex     gochan-mutex)
  (receivers gochan-receivers)
  (senders   gochan-senders))

(define (gochan cap)
  (make-gochan (make-mutex)
               (list->queue '())
               (list->queue '())))

(define (make-send-subscription sem data) (cons sem data))
(define send-subscription-sem  car)
(define send-subscription-data cdr)

(define (make-recv-subscription sem meta) (cons sem meta))
(define recv-subscription-sem  car)
(define recv-subscription-meta cdr)

;; we want to send, so let's notify any receivers that are ready. if
;; this succeeds, we close %sem. otherwise we return #f and we'll need
;; to use our semaphore. %sem must already be locked and open!
(define (gochan-signal-receiver chan %sem msg)
  (mutex-lock! (gochan-mutex chan))
  ;; TODO: if closed, signal receiver immediately
  (let ((q (gochan-receivers chan)))
    (let loop ()
      (if (queue-empty? q)
          (void)
          (let ((sub (queue-remove! q)))
            (if (semaphore-signal! (recv-subscription-sem sub) msg
                                   (recv-subscription-meta sub) #t)
                ;; receiver was signalled, signal self
                (begin (gosem-meta-set! %sem #t) ;; close!
                       (void))
                ;; receiver was already signalled by somebody else,
                ;; try next receiver
                (loop))))))
  (mutex-unlock! (gochan-mutex chan)))

;; we want to receive stuff, try to signal someone who's ready to
;; send. %sem must be locked and open!
(define (gochan-signal-sender chan %sem meta)
  (if (eq? #f meta) (error "metadata cannot be #f (in gochan-select* alist)"))
  (mutex-lock! (gochan-mutex chan))
  ;; TODO: if closed, signal receiver immediately
  (let ((q (gochan-senders chan)))
    (let loop ()
      (if (queue-empty? q)
          (void)
          (let ((sub (queue-remove! q)))
            ;; signalling a sender-semaphore. they don't care about
            ;; data, they just want to be unblocked.
            (if (semaphore-signal! (send-subscription-sem sub) #f #f #f)
                ;; receiver was signalled. TODO: skip subscribing
                (begin (gosem-meta-set! %sem meta) ;; close
                       (gosem-data-set! %sem (send-subscription-data sub))
                       (gosem-ok-set!   %sem #t))
                ;; sender was already signalled externally, try next
                (loop))))))
  (mutex-unlock! (gochan-mutex chan)))

;; we want to send data on chan. add %sem as a new subscription to
;; chan.
(define (gochan-subscribe-sender chan %sem msg)
  (info "sender   subscribing on " chan)
  (when (%gosem-open? %sem)
    ;; it's a waste to subscribe if we've already got data (nobody
    ;; would be able to signal us anyway).
    (mutex-lock! (gochan-mutex chan))
    (queue-add! (gochan-senders chan) (make-send-subscription %sem msg))
    (mutex-unlock! (gochan-mutex chan))))

;; we want to be notified when data is ready on chan.
(define (gochan-subscribe-receiver chan %sem meta)
  (info "receiver subscribing on " chan)
  (when (%gosem-open? %sem)
    ;; it's a waste to subscribe if we've already got data (nobody
    ;; would be able to signal us anyway).
    (mutex-lock! (gochan-mutex chan))
    (queue-add! (gochan-receivers chan) (make-recv-subscription %sem meta))
    (mutex-unlock! (gochan-mutex chan))))

(define (gochan-select* chans)
  (let ((semaphore (make-semaphore)))
    ;; keep our semaphore locked while we check channels for data
    ;; ready, so that we can't get signalled externally while we do
    ;; this.
    (mutex-lock! (gosem-mutex semaphore))
    (let loop ((chans chans))
      (if (and (%gosem-open? semaphore)
               (pair? chans))
          (let ((chan  (car chans)))
            (match chan
              (('-> (? gochan? chan) msg) ;; want to send to chan
               (gochan-signal-receiver    chan semaphore msg)
               (gochan-subscribe-sender   chan semaphore msg))
              ;; TODO: add support for gotimers here!
              (('<- (? gochan? chan) meta) ;; want to recv on chan
               (gochan-signal-sender      chan semaphore meta)
               (gochan-subscribe-receiver chan semaphore meta)))
            (loop (cdr chans)))
          (begin
            (if (%gosem-open? semaphore)
                ;; no data immediately available on any of the
                ;; channels, so we need to wait for somebody else to
                ;; signal us.
                (begin (info "need to wait for data")
                       (mutex-unlock! (gosem-mutex semaphore)
                                      (gosem-cv semaphore) #f))
                ;; yey, semaphore has data already!
                (begin (info "no need to wait, data ready")
                       (mutex-unlock! (gosem-mutex semaphore))))

            ;; TODO: cleanup dangling subscriptions
            ;; (for-each (lambda (achan) (gochan-unsubscribe (car achan) semaphore)) achans)
            (values (gosem-data semaphore)
                    (gosem-ok   semaphore)
                    (gosem-meta semaphore)))))))

(define (gochan-send chan msg)
  (assert (gochan? chan))
  (gochan-select* `((-> ,chan ,msg))))

(define (gochan-recv chan)
  (assert (gochan? chan))
  (gochan-select* `((<- ,chan #t))))

(define (gochan-close chan)       (error "TODO"))
(define (gochan-after durationms) (error "TODO"))
(define (gochan-tick durationms)  (error "TODO"))

(define-syntax go
  (syntax-rules ()
    ((_ body ...)
     (thread-start! (lambda () body ...)))))
