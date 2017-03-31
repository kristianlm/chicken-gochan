
(module gochan (gochan
                gochan-name ;; for debugging only, really
                gochan-receive
                gochan-receive*
                gochan-send
                gochan-close

                gochan-closed?

                gochan-for-each
                gochan-fold

                gochan-select
                gochan-select*

                gochan-after
                gochan-tick

                go ;; thread-start! wrapper for convenience
                )
(import chicken scheme)
(include "gochan.scm"))
