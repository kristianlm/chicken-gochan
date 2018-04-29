;; test gochan in combination with posix signal handlers
(import gochan test
	(only srfi-18 thread-start! thread-sleep!)
	(only (chicken process) process-signal process-fork)
	(only (chicken process signal)
	      signal-handler signal/int signal/usr1 signal/usr2)
	(only (chicken process-context posix) current-process-id))

(define c (gochan 0))

(set! (signal-handler signal/int)  (lambda (sig) (void)))
(set! (signal-handler signal/usr1) (lambda (sig) (thread-start! (lambda () (gochan-send c sig)))))
(set! (signal-handler signal/usr2) (lambda (sig) (thread-start! (lambda () (gochan-send c sig)))))
;; OBS: crazy things start to happen if you don't thread-start! here!
;; TODO: find out why (it's hard)

(thread-start!
 (lambda ()
   (let ((pid (current-process-id)))
     (process-fork
      (lambda ()
        ;; sleep to make sure we keep order
        (thread-sleep! 0.1) (process-signal pid signal/int)
        (thread-sleep! 0.1) (process-signal pid signal/usr1)
        (thread-sleep! 0.1) (process-signal pid signal/usr2))
      #t))))

;; avoid false-positive deadlock exceptions:
(thread-start! (lambda () (thread-sleep! 1)))

(test-group
 "posix signal-handlers"
 (test "gochan message via signal-handler 1" signal/usr1 (gochan-select ((c -> m) m)))
 (test "gochan message via signal-handler 2" signal/usr2 (gochan-select ((c -> m) m))))



