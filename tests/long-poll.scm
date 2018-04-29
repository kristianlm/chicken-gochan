;;; === HTTP long-polling example using spiffy and gochan ===
;;;
;;; using gochan's close-flag semantics to minic a broadcasting
;;; channel.
;;;
;;; gochans are 1-to-1, but closing a gochan will notify
;;; everyone. this means we can use closed gochans as
;;; "broadcasts". it's a neat little trick.
;;;
(import spiffy gochan parley
	(only (chicken string) conc)
	nrepl)

(go (print "nrepl listening on port 1234")
    (nrepl 1234))

(define chan-subscribe (gochan 0))
(define chan-message   (gochan 0))

;; dispatcher thread. newcomers subscribe by receiving from
;; chan-subscribe, where they get the currently active wait-channel.
;;
;; broadcasting to all subscribers is done by closing the
;; wait-channel, setting its close-flag to the actual message. closing
;; wait-channel will notify and unblock _all_ subscribers.
;;
;; note that nothing is ever sent across this wait-channel.
(go
 (let loop ((chan-wait (gochan 0)))
   (gochan-select
    ((chan-subscribe <- chan-wait)
     (print "\rsomebody subscribed!\n")
     (loop chan-wait))
    ((chan-message -> msg)
     (print "broadcasing: " msg)
     (gochan-close chan-wait (or msg #t)) ;; using msg as fail-flag (which cannot be #f)
     (loop (gochan 0))))))

;; handle each incoming request
(define (app)
  (define chan-wait (gochan-recv chan-subscribe))
  (define to (gochan-after 10000))
  (gochan-select
   ((chan-wait -> _ msg) (send-response body: (conc "got msg:" msg " \n")))
   ((to -> _)            (send-response body: (conc "too late (10s)" "\n")))))

(go
 (print "spiffy listening on http://localhost:8080/")
 (vhost-map `((".*" . ,(lambda (c) (app)))))
 (start-server))

;; feed stdin into chan-message
(let loop ()
  (define line (parley "broadcast> "))
  (gochan-select
   ((chan-message <- line)
    (unless (eof-object? line)
      (loop)))))

