;;; thread-leak-test
;;;
;;; this demonstrates that a thread that's blocking on a gochan which
;;; gets thrown away is garbage-collected. this may be
;;; useful/essential when spawning many (go ...) waiting for a gochan
;;; that no other thread has a reference to.
(use gochan)

(define (go-map c proc error)
  (define c (gochan)))

;; monitor heap size. these numbers should drop on gc (unless we're
;; leaking threads)!
(go
 (let loop ()
   (print (memory-statistics))
   (thread-sleep! 1)
   (loop)))

;; surprisingly, this following code snippet does not leak threads.
;; the threads aren't referenced anywhere so they get garbage
;; collected (they are waiting for a condition-variable that also gets
;; gc'd).
(let loop ()
  (define c (gochan 0))
  (go (print (gochan-recv c)))
  ;; c goes out of scope ...
  (loop))

