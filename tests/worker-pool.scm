;; worker-pools example, based on https://gobyexample.com/worker-pools
;; time csi -s worker-pool.scm tells us we spend 1 second doing a
;; 5-second job.
(use gochan miscmacros srfi-1 test)

(define (worker jobs results)
  (let loop ()
    (gochan-select
     ((jobs -> job ok)
      (when ok
        (print (current-thread) " processing job " job)
        (thread-sleep! 1)
        (gochan-send results (* -1 job))
        (loop)))))
  (print (current-thread) " worker exit"))

(define jobs (gochan 0))
(define res  (gochan 0))

(define workers
  (map
   (lambda (x) (thread-start! (make-thread (cut worker jobs res) x)))
   (iota 10))) ;; <-- 10 worker threads

;; 5 jobs
(repeat* 5 (gochan-send jobs it))
(gochan-close jobs) ;; this will exit workers when channel is drained
(repeat* 5 (print "result: " (gochan-recv res)))

(for-each thread-join! workers)
