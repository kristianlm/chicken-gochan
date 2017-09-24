
(define-library (gochan)
  (export gochan
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
  (import (scheme base)
          (only (chibi match) match)
          (only (chibi time) get-time-of-day timeval-seconds timeval-microseconds)
          (only (srfi 95) sort)
          (only (srfi 8)  receive)
          (only (srfi 27) random-integer)
          (only (srfi 18)
                make-condition-variable condition-variable-signal!
                make-mutex mutex-lock! mutex-unlock!
                make-thread thread-start!))
  (include "queue.scm")
  (include "chibi-compat.scm")
  (include "gochan.scm"))
