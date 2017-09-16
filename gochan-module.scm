
(module gochan (gochan
                go

                gochan-recv
                gochan-send
                gochan-close

                gochan-select*
                gochan-select
                
                gochan-empty?

                gochan-after
                gochan-tick
                gotimer ;; undocumented, but maybe useful, see comments
                )
(import chicken scheme)
(include "gochan.scm"))
