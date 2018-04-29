;; https://blog.jayway.com/2014/09/16/comparing-core-async-and-rx-by-example/
;; ported to CHICKEN using gochan:
;;
;; # The Problem
;;
;; Given that we have two buttons, A and B, we want to print a message
;; if a “secret combination” (ABBABA) is clicked within 5 seconds. To
;; make things a bit harder the following must also be true:
;;
;; - The message should be printed immediately when the secret
;;   combination is clicked. We should not wait until the end of the 5
;;   second interval before the message is printed.
;;
;; - As soon as the secret combination is fulfilled (within 5 seconds)
;;   the message should be displayed regardless of what has been
;;   clicked before. For example a combination like “BBABBABA” is ok
;;   as long as “ABBABA” is clicked within 5 seconds.

(import gochan parley
	(only (chicken string) conc)
	(only srfi-13 string-prefix?))

(define c (gochan 0))

;; using parley ensures nonblocking io and lets the user enter data
;; without having to press enter.
(go
 ;; obviously, we don't have DOM events but terminal input will do!
 (add-key-binding! #\a (lambda (parley-state) (gochan-send c 'A) parley-state))
 (add-key-binding! #\b (lambda (parley-state) (gochan-send c 'B) parley-state))
 ;; spin off the parley prompt, handling our key binding callbacks.
 (let loop () (parley ">") (loop)))

(define (make-timeout) (gochan-after 5000))
(define secret "ABBABA")

;; the idea is that whenever we reach the timeout, we clear out any
;; sequence we had already because even if it was on to something,
;; it's too slow, and at the same time we reset the timeout.
(let loop ((seq "")
	   (to (make-timeout)))
  (if (equal? seq secret)
      (print "congrats!!")
      (gochan-select
       ((c -> x)
	(print "seq " seq " " x)
	(if (string-prefix? seq secret)
	    ;; we have the right sequence this far, keep going but
	    ;; respect our current timeout.
	    (loop (conc seq x) to)
	    ;; obs, our next character breaks our potential
	    ;; secret. reset our timer and start over (starting from
	    ;; x!).
	    (loop (conc x) (make-timeout))))
       ((to -> _)
	(print "timeout!")
	(loop "" (make-timeout))))))
