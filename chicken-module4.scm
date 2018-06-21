
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
(import scheme chicken)

(use srfi-18
     (only data-structures
           list->queue queue->list queue-add!
           queue-empty? queue-remove! queue-length

           sort)
     (only extras random)
     (only matchable match))

(define pseudo-random-integer random)

(include "gochan.scm")
(include "gochan-record-printer.scm"))
