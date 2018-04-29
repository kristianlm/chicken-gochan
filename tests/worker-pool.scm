;; worker-pools example, based on https://gobyexample.com/worker-pools
;; time csi -s worker-pool.scm tells us we spend 1 second doing a
;; 5-second job.
(import gochan
	miscmacros
	(only (chicken random) pseudo-random-integer)
	srfi-18 srfi-1)

(define (info . args) (apply print (cons (current-thread) (cons " " args))))

(define (worker jobs results)
  (let loop ()
    (gochan-select
     ((jobs -> job) ;; no fail-flag here means we break (loop) when jobs is closed
      (thread-sleep! (/ (pseudo-random-integer 1000) 1000))
      (if (= 0 (pseudo-random-integer 100))
          (info "crash!")
          (gochan-send results 'my-result))
      (loop))))
  (info "worker exit"))

(define jobs (gochan 100)) ;; allow filling jobs queue
(define res  (gochan 0))   ;; block workers until we get their result

;; dispatch worker threads
(repeat 5 (go (worker jobs res)))

;; queue jobs
(repeat* 100 (gochan-send jobs it))
(info "all jobs enqueued")

;; allow workers to exit cleanly (`ok` will be #f)
(gochan-close jobs)

;; show progress every 250ms
(define progress (gochan-tick 250))
;; don't hang forever if something goes wrong
(define timeout  (gochan-after (+ 1000 (* (/ 100 5) 1000))))

(let loop ((done 0))
  (if (< done 100)
      (gochan-select
       ((res -> msg)
        (loop (add1 done)))
       ((progress -> _)
        (print* done " / " 100 "    \r")
        (loop done))
       ((timeout -> _)
        (info "should have completed all jobs by now, sombody crashed :-(")))
      (info "all jobs completed")))

