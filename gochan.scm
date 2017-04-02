;; gochan.scm -- thread-safe channel (FIFO) library based on the go
;; programming language's channel API.
;;
;; Copyright (c) 2017 Kristian Lein-Mathisen.  All rights reserved.
;; License: BSD
(use srfi-18
     (only matchable match)
     (only data-structures list->queue queue->list sort
           queue-add! queue-empty? queue-remove! queue-first queue-length))

;; todo:
;;
;; - closing a channel
;; - buffers

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

(define-record-type gotimer
  (make-gotimer mutex receivers when data ok next)
  gotimer?
  (mutex     gotimer-mutex)
  (receivers gotimer-receivers gotimer-receivers-set!)
  (when      gotimer-when gotimer-when-set!) ;; when may be #f if never to trigger again
  (data      gotimer-data gotimer-data-set!)
  (ok        gotimer-ok   gotimer-ok-set!)
  (next      gotimer-next))

;; next is a thunk which returns (values when-next data ok)
(define (gotimer next)
  (receive (when-next data ok) (next)
    (make-gotimer (make-mutex)
                  (list->queue '())
                  when-next
                  data
                  ok
                  next)))

;; it's important that when-next is set in lockstep as gotimer-next is
;; called so that gotimer-next get's called only once per "when" it
;; returns. gotimer-next should never be called if gotimer-when is #f.
(define (gotimer-tick! timer)
  (receive (when-next data ok) ((gotimer-next timer))
    (gotimer-when-set! timer when-next) ;; may be #f if never to timout again
    (gotimer-data-set! timer data)
    (gotimer-ok-set!   timer ok)))


(define (gochan-after duration:ms)
  (let ((when (+ (current-milliseconds) duration:ms)))
    (gotimer (lambda () (let ((tmp when))
                     (set! when #f) ;; never trigger again
                     ;;      when-next  data ok
                     (values tmp        tmp  #t))))))

(define (gochan-tick duration:ms)
  (let ((when (current-milliseconds)))
    (gotimer (lambda ()
               (set! when (+ when duration:ms))
               (values when when #t)))))

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

(define (make-send-subscription sem data meta) (cons sem (cons data meta)))
(define send-subscription-sem  car)
(define send-subscription-data cadr)
(define send-subscription-meta cddr)

(define (make-recv-subscription sem meta) (cons sem meta))
(define recv-subscription-sem  car)
(define recv-subscription-meta cdr)

;; we want to send, so let's notify any receivers that are ready. if
;; this succeeds, we close %sem. otherwise we return #f and we'll need
;; to use our semaphore. %sem must already be locked and open!
(define (gochan-signal-receiver/subscribe chan %sem msg meta)
  ;; because meta is also used to tell if a semaphore has already been
  ;; signalled (#f) or not (≠ #f).
  (if (eq? #f meta) (error "metadata cannot be #f (in gochan-select* alist)"))
  (mutex-lock! (gochan-mutex chan))
  ;; TODO: if closed, signal receiver immediately
  (let ((q (gochan-receivers chan)))
    (let %loop ()
      (if (queue-empty? q)
          (begin
            ;; nobody was aroud to receive our data :( we'll need to
            ;; enable receivers to notify us when they need data by
            ;; adding our semaphore to the senders-list:
            (assert (%gosem-open? %sem))
            (queue-add! (gochan-senders chan)
                        (make-send-subscription %sem msg meta))
            (mutex-unlock! (gochan-mutex chan))
            #t)
          (let ((sub (queue-remove! q)))
            (if (semaphore-signal! (recv-subscription-sem sub) msg
                                   (recv-subscription-meta sub) #t)
                ;; receiver was signalled, signal self
                (begin (gosem-meta-set! %sem meta) ;; close!
                       (mutex-unlock! (gochan-mutex chan))
                       #f)
                ;; receiver was already signalled by somebody else,
                ;; try next receiver
                (%loop)))))))

;; we want to receive stuff, try to signal someone who's ready to
;; send. %sem must be locked and open!
(define (gochan-signal-sender/subscribe chan %sem meta)
  (if (eq? #f meta) (error "metadata cannot be #f (in gochan-select* alist)"))
  (mutex-lock! (gochan-mutex chan))
  ;; TODO: if closed, signal receiver immediately
  (let ((q (gochan-senders chan)))
    (let %loop ()
      (if (queue-empty? q)
          (begin
            ;; nobody had data for us :-( awww. but we can add
            ;; ourselves here so when they do, they can signal us.
            (assert (%gosem-open? %sem))
            (queue-add! (gochan-receivers chan)
                        (make-recv-subscription %sem meta))
            (mutex-unlock! (gochan-mutex chan))
            #t)
          (let ((sub (queue-remove! q)))
            ;; signalling a sender-semaphore. they don't care about
            ;; data, they just want to be unblocked.
            (if (semaphore-signal! (send-subscription-sem sub) #f (send-subscription-meta sub) #f)
                ;; receiver was signalled. TODO: skip subscribing
                (begin (gosem-meta-set! %sem meta) ;; close
                       (gosem-data-set! %sem (send-subscription-data sub))
                       (gosem-ok-set!   %sem #t)
                       (mutex-unlock! (gochan-mutex chan))
                       #f)
                ;; sender was already signalled externally, try next
                (%loop)))))))

;; we want to add a timeout to our semaphore. if the chan (aka gotimer)
;; has already timed out, we immediately alert %sem and tick the
;; timer. otherwise, we register %sem as a chan/gotimer subscriber.
;;
;; returns #t is %sem was registered on timer as receiver subscriber.
(define (gochan-signal-timer/subscribe chan %sem meta)
  ;; note that chan here is really a gotimer
  (if (eq? #f meta) (error "metadata cannot be #f (in gochan-select* alist)"))
  (mutex-lock! (gotimer-mutex chan))
  (if (gotimer-when chan)
      (begin
        (if (<= (gotimer-when chan) (current-milliseconds))
            ;; timer already expired!
            (begin
              (gosem-meta-set! %sem meta) ;; <-- also closes %sem
              (gosem-data-set! %sem (gotimer-data chan))
              (gosem-ok-set!   %sem (gotimer-ok   chan))
              (gotimer-tick! chan)
              (mutex-unlock! (gotimer-mutex chan))
              #f)
            (begin
              ;; timer in the future, register us
              (queue-add! (gotimer-receivers chan)
                          (make-recv-subscription %sem meta))
              (mutex-unlock! (gotimer-mutex chan))
              #t)))
      (begin (mutex-unlock! (gotimer-mutex chan))
             #f)))

(define (gotimer-signal timer)
  (mutex-lock! (gotimer-mutex timer))
  (info "signalling timer " timer)
  (if (gotimer-when timer)
      (let ((q (gotimer-receivers timer)))
        (let loop ()
          (if (queue-empty? q)
              (void)
              (let ((sub (queue-remove! q)))
                (if (semaphore-signal! (recv-subscription-sem sub)
                                       (gotimer-data timer)
                                       (recv-subscription-meta sub)
                                       (gotimer-ok timer))
                    ;; receiver was signalled
                    ;; ok, tick timer.
                    (gotimer-tick! timer)
                    ;; semaphore was
                    ;; already signalled,
                    ;; can't deliver
                    ;; value. try next
                    ;; subscriber!
                    (loop))))))
      ;; somebody else grabbed our timer
      ;; trigger from us.
      (info timer " is no longer with us"))
  (mutex-unlock! (gotimer-mutex timer)))


;; the heart of it all! takes input that looks like this:
;;
;; (gochan-select `((,chan1 meta1)
;;                  (,chan2 meta2 message)
;;                  (,chan3 meta3) ...))
;;
;; gochan-select* returns:
;;
;; (msg ok meta)
;;
;; where msg is the message that was send over the channel, ok is #f
;; is channel was closed and #t otherwise, meta is the datum supplied
;; in the arguments.
;;
;; if a message arrived on chan3 above, for example, meta would be
;; 'meta3 in that case. this allows you to see which channel a message
;; came from (ie if you supply meta data that's is the channel itself)
;;
(define (gochan-select* chans)
  (let ((semaphore (make-semaphore)))
    ;; keep our semaphore locked while we check channels for data
    ;; ready, so that we can't get signalled externally while we do
    ;; this.
    (mutex-lock! (gosem-mutex semaphore))
    (let loop ((chans chans)
               (sendsub '()) ;; list of gochans we're subscribed on send
               (recvsub '()) ;; list of gochans we're subscribed on recv
               (timesub '())) ;; list of gotimer we're subscribed on recv/trigger
      (if (and (%gosem-open? semaphore)
               (pair? chans))
          (let ((chan  (car chans)))
            (match chan

              (((? gochan? chan) meta msg) ;; want to send to chan
               (loop (cdr chans)
                     (if (gochan-signal-receiver/subscribe chan semaphore msg meta)
                         (cons chan sendsub)
                         sendsub)
                     recvsub
                     timesub))

              (((? gochan? chan) meta) ;; want to recv on chan
               (loop (cdr chans)
                     sendsub
                     (if (gochan-signal-sender/subscribe   chan semaphore meta)
                         (cons chan recvsub)
                         recvsub)
                     timesub))

              (((? gotimer? chan) meta) ;; want to "recv" on timeout
               (loop (cdr chans)
                     sendsub
                     recvsub
                     (if (gochan-signal-timer/subscribe    chan semaphore meta)
                         (cons chan timesub)
                         timesub)))))
          (let %retry () ;; lock semaphore mutex before retrying!
            (if (%gosem-open? semaphore)
                ;; no data immediately available on any of the
                ;; channels, so we need to wait for somebody else to
                ;; signal us.
                (if (pair? timesub)
                    (let* ((timer (car (sort timesub
                                             (lambda (a b) ;; sort #f last
                                               (let ((a (gotimer-when a))
                                                     (b (gotimer-when b)))
                                                 (if a
                                                     (if b (< a b) #t)
                                                     #f))))))
                           (timeout (max 0 (/ (- (gotimer-when timer)
                                                 (current-milliseconds))
                                              1000))))
                      (info "wait for data with timer " timer " and timeout " timeout)
                      (if (mutex-unlock! (gosem-mutex semaphore)
                                         (gosem-cv semaphore)
                                         timeout)
                          ;; no timeout, semaphore must have been
                          ;; signalled, data should be in semaphore
                          (void)
                          ;; timeout! this part is tricky. now we need
                          ;; to do some work that would normally be
                          ;; done on the sender-end since the timer
                          ;; has no "sender" side code. if we reach
                          ;; the timer's mutex first here, we are
                          ;; doing work on behalf of all the timer's
                          ;; subscribers.
                          (begin
                            (gotimer-signal timer)
                            ;; at this point, we know there was a
                            ;; timeout on timer but we don't know who
                            ;; received its signal.
                            (mutex-lock! (gosem-mutex semaphore))
                            (%retry))))
                    ;; we don't have any timers, wait on cv forever
                    (begin (info "wait for data without timer")
                           (mutex-unlock! (gosem-mutex semaphore)
                                          (gosem-cv semaphore))))
                ;; yey, semaphore has data already!
                (begin (info "no need to wait, data already there")
                       (mutex-unlock! (gosem-mutex semaphore))))

            ;; TODO: cleanup dangling subscriptions
            ;; (for-each (lambda (achan) (gochan-unsubscribe (car achan) semaphore)) achans)
            (assert (gosem-meta semaphore)) ;; just to make sure
            (values (gosem-data semaphore)
                    (gosem-ok   semaphore)
                    (gosem-meta semaphore)))))))

(define (gochan-send chan msg)
  (assert (gochan? chan))
  (gochan-select* `((,chan #t ,msg))))

(define (gochan-recv chan)
  (assert (gochan? chan))
  (gochan-select* `((,chan #t))))

(define (gochan-close chan)       (error "TODO"))

(define-syntax go
  (syntax-rules ()
    ((_ body ...)
     (thread-start! (lambda () body ...)))))
