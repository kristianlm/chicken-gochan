
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
(include "gochan-record-printer.scm"))
