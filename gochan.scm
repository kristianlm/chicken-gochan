;; gochan.scm -- thread-safe channel (FIFO) library
;; Copyright (c) 2012 Alex Shinn.  All rights reserved.
;; Copyright (c) 2014 Kristian Lein-Mathisen.  All rights reserved.
;; BSD-style license: http://synthcode.com/license.txt
;;
;; Inspired by channels from goroutines.

(use srfi-18
     (only data-structures list->queue queue->list
           queue-add! queue-empty? queue-remove! queue-first queue-length))

(define (info . args) (void))
;;(define (info . args) (apply print (cons (current-thread) (cons " " args))))

(define-record-type gochan
  (%gochan mutex cap cv-send semaphores buffer closed?)
  gochan?
  (mutex gochan-mutex gochan-mutex-set!)
  (semaphores gochan-semaphores)
  (cv-send    gochan-cv-send)
  (cap        gochan-cap)
  (buffer gochan-buffer)
  (closed? gochan-closed? gochan-closed-set!))

;; everything about timers is immutable, so that's nice. each slot is
;; a procedure which returns useful stuff.
(define-record-type gochan-timer
  (%gochan-timer whenproc closed?)
  gochan-timer?
  (whenproc gochan-timer-whenproc)
  (closed? gochan-timer-closed?))

;; useful for debugging
(define (gochan-name chan) (mutex-name (gochan-mutex chan)))

(define-record-printer gochan
  (lambda (x p)
    (display "#<gochan " p)
    (display (queue-length (gochan-buffer x))  p)
    (display "/" p)
    (display (gochan-cap x)  p)
    (display " (" p)
    (display (queue-length (gochan-semaphores x))  p)
    (display ") " p)
    (display (or (gochan-name x) "") p)
    (display ">" p)))

(define-record-printer gochan-timer
  (lambda (x p)
    (display "#<gochan ⌛ " p)
    (display (- ((gochan-timer-whenproc x)) (current-milliseconds)) p)
    (display ">" p)))

(define-record gochan-semaphore mutex cv ok when timer)

(define (gochan-after duration_ms)
  (let ((when (+ (current-milliseconds) duration_ms)))
    (info "TIMER after created, will trigger at " when ", now " (current-milliseconds))
    (%gochan-timer (lambda () when)
                   (lambda () (let ((old when))
                           (set! when #f)
                           old)))))

(define (gochan-tick duration_ms)
  (let ((when (+ (current-milliseconds) duration_ms)))
    (info "TIMER tick created, next trigger at " when ", now " (current-milliseconds))
    (%gochan-timer (lambda () (info "TIMER  when " when) when)
                   (lambda ()
                     (info "TIMER tick next " when ", now " (current-milliseconds))
                     (let ((old when))
                       (set! when (+ when duration_ms))
                       old)))))

;; make a receiver semaphore. anyone can at any time signal it. but
;; once signalled, it cannot be re-signalled. each invocation of
;; gochan-receive* and friends will make such a semaphore, and block
;; on it. these provide for a guarantee of the sender-end "awaking"
;; the receiving end, that no data gets lots and that there is only
;; one receiver.
;;
;; note that a semaphore is used to both awaken a receiver and carry
;; data and metadata.
(define (make-semaphore)
  (let ((cv (make-condition-variable))
        (mx (make-mutex)))
    (condition-variable-specific-set! cv #f)
    (mutex-specific-set! mx #f)
    ;;                           ok  when timer
    (make-gochan-semaphore mx cv #f  #f   #f)))

;; returns #t on successful signal, #f if semaphore was already
;; signalled.
(define (semaphore-signal! semaphore obj sender ok)
  (info "signalling " semaphore " from " sender)
  (mutex-lock! (gochan-semaphore-mutex semaphore))
  (let ((cv (gochan-semaphore-cv semaphore)))
   (cond ((eq? #f (condition-variable-specific cv))
          (condition-variable-specific-set! cv sender)
          (mutex-specific-set! (gochan-semaphore-mutex semaphore) obj)
          (gochan-semaphore-ok-set! semaphore ok)
          (condition-variable-signal! cv) ;; triggers receiver
          (mutex-unlock! (gochan-semaphore-mutex semaphore))
          #t)
         (else
          (mutex-unlock! (gochan-semaphore-mutex semaphore))
          #f)))) ;; already signalled


;; sets the timeout for semaphore to `when`, unless an earlier timeout
;; has already been set.
(define (semaphore-register-timeout! semaphore when timer)
  (assert (number? when))
  (assert (gochan-timer? timer))

  (mutex-lock! (gochan-semaphore-mutex semaphore))
  (let ((old-when (gochan-semaphore-when semaphore)))
    (if (or (not old-when)
            (< when old-when))
        (begin
          (info "semaphore gets a closer timeout " timer)
          (gochan-semaphore-when-set! semaphore when)
          (gochan-semaphore-timer-set! semaphore timer))))
  (mutex-unlock! (gochan-semaphore-mutex semaphore))
  (void))

;; wait (if necessary) for semaphore to be signalled by someone
;; else. if the semaphore is already been signalled, returns
;; immediately. returns 3 values:
;;
;; (data sender ok)
;;
;; sender may be a gochan-timer record and not a real gochan. if ok is
;; #f, data is also #f.
(define (semaphore-wait! semaphore)

  (mutex-lock! (gochan-semaphore-mutex semaphore))

  (let ((cv (gochan-semaphore-cv semaphore)))

    (define (data)
      (values (mutex-specific (gochan-semaphore-mutex semaphore))
              (condition-variable-specific cv)
              (gochan-semaphore-ok semaphore)))

    (if (condition-variable-specific cv)
        ;; signalled already!
        (begin (mutex-unlock! (gochan-semaphore-mutex semaphore))
               (data))
        ;; not signalled yet, wait
        (let* ((when (gochan-semaphore-when semaphore)))
          (if when ;; <-- milliseconds into the future or #f
              (let ((timer (gochan-semaphore-timer semaphore))
                    (timeout (/ (- when (current-milliseconds)) 1000.0)))
                (info "waiting for " semaphore " with timer " timer " in " timeout "ms")
                (if (> timeout 0)
                    (if (mutex-unlock! (gochan-semaphore-mutex semaphore) cv timeout)
                        (data)
                        ;; mutex-unlock timed out, so sender is the special timer channel
                        (values #f timer #t))
                    (begin (info "already timed out")
                     (values #f timer #t))))
              (begin
                (info "waiting for " semaphore " without timer")
                (if (mutex-unlock! (gochan-semaphore-mutex semaphore) cv)
                    (data)
                    (error "internal error: mutex-unlock! timeout without timeout argument"))))))))

;; capacity is the buffer-capacity in number of messages. 0 means
;; locks-step.
(define (gochan capacity #!key (initial '()) (name #f))
  (assert (fixnum? capacity))
  (assert (list? initial))
  (%gochan (make-mutex name)         ;; mutex
           capacity                  ;; cap
           (make-condition-variable) ;; cv-send
           (list->queue '())         ;; semaphores
           (list->queue initial)     ;; buffer
           #f))                      ;; closed?

;; try to send a signal to a single semaphore/receiver who has
;; registered with chan. returns:
;; - #t if someone was signalled, awakened and thus delivered
;; - #f otherwise, nobody was there to receive :(
;; this must be called in a locked gochan mutex context.
(define (%gochan-signal c obj ok)
  (let ((semaphores (gochan-semaphores c)))
    (let loop ()
      (if (queue-empty? semaphores)
          #f
          (if (semaphore-signal! (queue-remove! semaphores) obj c ok)
              ;; signaled, great success!
              (begin (info "semaphore signalled (is now " (queue->list semaphores) ")") #t)
              ;; not signalled, so somebody else signalled the
              ;; semaphore. keep trying.
              (loop))))))

;; send obj on channel. if buffer if alread full (ie buffer-size >=
;; cap), block until somebody starts a receive on channel.
(define (gochan-send chan obj)
  (mutex-lock! (gochan-mutex chan))
  (when (gochan-closed? chan)
    (begin (mutex-unlock! (gochan-mutex chan))
           (error "gochan closed" chan)))

  (info "sending " obj " to " chan)
  (if (%gochan-signal chan obj #t)
      (begin (info "chan signalled!")
             (mutex-unlock! (gochan-mutex chan)))
      ;; unable to signal any receivers directly:
      (if (> (gochan-cap chan) (queue-length (gochan-buffer chan)))
          ;; chan isn't full, just queue obj and return immediately
          (begin (info "chan buffer push")
                 (queue-add! (gochan-buffer chan) obj)
                 (mutex-unlock! (gochan-mutex chan)))
          ;; chan is full :-( wait for somebody to receive and retry.
          (begin (info "chan full, waiting")
                 (mutex-unlock! (gochan-mutex chan) (gochan-cv-send chan))
                 (gochan-send chan obj)))))


;; register semaphore on channel %chan or signal the semaphore if
;; the channel had data available.
;; returns:
;; #t if semaphore was registered with channel (chan had no data)
;; #f if semaphore was not regsitered with channel (chan had data)
;; this function never blocks!
;; it's important that you unregister semaphore on channels as
;; cleanup, so we don't leak them.
(define (gochan-subscribe chan% semaphore)
  (let ((chan (if (pair? chan%) (car chan%) chan%)))
    (mutex-lock! (gochan-mutex chan))
    (info "looking for data in " chan)
    (let ((buffer (gochan-buffer chan)))
      (if (queue-empty? buffer)
          (if (gochan-closed? chan)
              ;; receiving from empty and closed gochan
              (begin (semaphore-signal! semaphore #f chan #f)
                     (mutex-unlock! (gochan-mutex chan))
                     #f) ;; TODO #t for keep going for now
              (begin
                ;; receiving from empty and open gochan, register
                ;; semaphore with channel
                (info semaphore " subscribing to " chan)
                (queue-add! (gochan-semaphores chan) semaphore)
                (mutex-unlock! (gochan-mutex chan))
                #t))
          ;; there's data already available, move it safely into the
          ;; semaphore signal.
          (let ((data (queue-first buffer)))
            (if (semaphore-signal! semaphore data chan #t)
                ;; semaphore was signalled successfully:
                (begin (info chan " popped and signalled successfully " data)
                       (queue-remove! buffer)
                       ;; unblock channel's sender, if any:
                       (condition-variable-signal! (gochan-cv-send chan))
                       (mutex-unlock! (gochan-mutex chan))
                       #f)
                ;; semaphore was already signalled by someone else,
                ;; leave data in buffer.
                (begin (mutex-unlock! (gochan-mutex chan))
                       #f)))))))

;; run through the channels' semaphores (queue) and remove any
;; instances of `semaphore`.
(define (gochan-unsubscribe achan semaphore)
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

;; accept channel or list of channels. returns 3 values like semaphore-wait!
;; (data chan closed) on success,
(define (gochan-receive* chans%)
  (let ((chans (if (pair? chans%) chans% (list chans%)))
        (semaphore (make-semaphore)))

    (let loop ((chans chans)
               (registered '())) ;; list of gochans that contain our semaphore
      (if (pair? chans)
          (let* ((chan (car chans)))
            (if (gochan? chan)
                (if (gochan-subscribe chan semaphore)
                    ;; channel registered with semaphore
                    (begin
                      (condition-variable-signal! (gochan-cv-send chan))
                      (loop (cdr chans) (cons chan registered)))
                    ;; semaphore was not registered with channel, there is
                    ;; data ready on semaphore. so no need to check the
                    ;; remaining channels for data
                    (loop '() registered))
                ;; assuming it's a gochan-timer then, mention it to the semaphore
                (begin (semaphore-register-timeout! semaphore ((gochan-timer-whenproc chan)) chan)
                       (loop (cdr chans) registered))))
          ;; we've run through all channels. our semaphore may or may
          ;; not contain data.
          (begin
            ;; we have registered our semaphore with all channels
            (info "registered with " registered " other channels")
            (receive (data sender ok) (semaphore-wait! semaphore)
              (info "data from semaphore-wait!: " data (if ok " (ok)" " (closed)"))
              ;; remove semaphore from all channels. gochan-send
              ;; removes semaphore too, but we need to avoid
              ;; leaks in case nobody sends.
              (for-each (lambda (chan) (gochan-unsubscribe chan semaphore)) registered)

              (values data sender ok)))))))

;; receive a message from chan. returns 2 values:
;; (data ok)
(define (gochan-receive chan)
  (receive (msg sender ok) (gochan-receive* chan)
    (values msg ok)))

;; close channel. note that closing a closed channel yields in error
;; (like in go)
(define (gochan-close c)
  (mutex-lock! (gochan-mutex c))
  (when (gochan-closed? c)
    (mutex-unlock! (gochan-mutex c))
    (error "gochan closed" c))

  (info "closing " c " with semaphores " (queue->list (gochan-semaphores c)))
  (gochan-closed-set! c #t)
  ;; signal *everybody* that we're closing (waking them all up,
  ;; because now there are tons of #f-messages available to them)
  (let loop () (if (%gochan-signal c #f #f) (loop)))

  (mutex-unlock! (gochan-mutex c)))

;; apply proc to each incoming msg as they appear on the channel,
;; return (void) when channel is emptied and closed. don't use this on
;; a list of channels.
(define (gochan-for-each c proc)
  (let loop ()
    (receive (msg chan ok) (gochan-receive* c)
      (when ok
        (proc msg)
        (loop)))))

(define (gochan-fold chans proc initial)
  (let loop ((state initial))
    (receive (msg chan ok) (gochan-receive* chans)
      (if ok
          (loop (proc msg state))
          state))))

(define (gochan-select* chan.proc-alist)
  (receive (msg chan ok) (gochan-receive* (map car chan.proc-alist))
    (cond ((assoc chan chan.proc-alist) => (lambda (pair) ((cdr pair) msg ok)))
          (else (error "internal error: chan not found in " chan.proc-alist)))))

;; (gochan-select
;;  (c1 msg body ...)
;;  (10 timeout-body ...)
;;  (c2 obj body ...))
;; becomes:
;; (gochan-select*
;;  (cons (cons       c1 (lambda (msg) body ...))
;;        (cons (cons c2 (lambda (obj) body ...)) '()))
;;  10 (lambda () timeout-body ...))


;; turn gochan-select form into ((chan1 . proc1) (chan2 . proc2) ...)
(define-syntax gochan-select-alist
  (syntax-rules ()
    ;; without optional status variable
    ((_ ((channel varname) body ...) rest ...)
     (cons (cons channel (lambda (varname _) body ...))
           (gochan-select-alist rest ...)))
    ;; with optional status variable
    ((_ ((channel varname ok) body ...) rest ...)
     (cons (cons channel (lambda (varname ok) body ...))
           (gochan-select-alist rest ...)))

    ((_) '())))

(define-syntax gochan-select
  (syntax-rules ()
    ((_ form ...)
     (gochan-select* (gochan-select-alist form ...)))))

(define-syntax go
  (syntax-rules ()
    ((_ body ...)
     (thread-start! (lambda () body ...)))))
