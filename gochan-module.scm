
(module gochan (gochan
                go

                gochan-recv
                gochan-send
                gochan-close

                gochan-select*

                gochan-after
                gochan-tick
                )
(import chicken scheme)
(include "gochan.scm"))
