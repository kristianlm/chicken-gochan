
(module gochan (gochan
                go

                gochan-recv
                gochan-send
                gochan-close

                gochan-select*
                gochan-select

                gochan-after
                gochan-tick
                gotimer ;; undocumented, but maybe useful, see comments
                )

(import (scheme)
	(chicken base)
	srfi-18
	(only (queues) list->queue queue->list queue-add! queue-empty? queue-remove! queue-length)
	(only (matchable) match)
	(only (chicken time) current-milliseconds)
	(only (chicken random) pseudo-random-integer)
	(only (chicken sort) sort))

(include "gochan.scm")

(define-record-printer <gochan>
  (lambda (x p)
    (display "#<gochan " p)
    (if (gochan-closed x) (display "closed "))
    (display (- (queue-length (gochan-senders x))
                (queue-length (gochan-receivers x)))  p)
    (display " (" p)
    (display (queue-length (gochan-buffer x)) p)
    (display "/" p)
    (display (gochan-cap x) p)
    (display ")>" p)))

(define-record-printer <gotimer>
  (lambda (x p)
    (display "#<gochan ⌛ " p)
    (display (if (gotimer-when x)
                 (inexact->exact (round (- (gotimer-when x) (current-milliseconds))))
                 "∞") p)
    (display "ms (" p)
    (display (queue-length (gotimer-receivers x)) p)
    (display ")" p)
    (display ">" p))))
