;; this gochan test-case check whether we leak semaphores. currently
;; there is a bug where the gochan-select registers a semaphore with
;; chan2, but these are never freed.
;;
;; if you run this for a while and memory-statistics doesn't grow,
;; we're good. to make it run out-of-memory quicker, try:
;;
;; csi -s tests/many-semaphores.scm -:h32M
(use gochan)

(define chan (gochan))
(let loop ()
  ;; registers a (new?) semaphore per loop. 0 timeout to make it loop
  ;; fast. memory consumption shouldn't grow on this one!
  (gochan-select
   (chan x (void))
   (0 (void)))
  (loop))
